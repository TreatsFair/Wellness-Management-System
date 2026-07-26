-- 122_preview_and_atomic_start.sql
-- Phase 6B / Project B. Two-stage check-in.
--   * preview_check_in            : READ-ONLY. Writes nothing, locks nothing,
--                                   consumes no queue turn, changes no status.
--   * confirm_and_start_appointment / _group : the ONLY mutating start action.
--
-- The start RPCs reuse Migration 116's reconcile_appointment_resources(id, true),
-- which already: selects concrete therapist+room for anonymous/pending rows
-- (auto-substitution from the live queue/capacity), PRESERVES confirmed
-- (specific_customer_request / manual_override) resources, and RAISES a conflict
-- when a preserved resource is unavailable. Queue-turn consumption happens exactly
-- once via the existing consume_queue_on_appointment_start trigger when
-- actual_started_at goes NULL->set. Payment reuses the existing, tested
-- checkout_appointment_with_payment / _group RPCs for the unpaid case; an
-- already-paid (Billplz) appointment is never charged again.
--
-- Idempotency: actual_started_at is the authoritative duplicate-start guard. The
-- appointment/group rows are taken FOR UPDATE, so two devices serialise; the
-- second observes actual_started_at set and returns the existing result — no
-- duplicate payment, start, or queue-turn consumption.

begin;

-- ============ preview_check_in (READ-ONLY) ============
create or replace function public.preview_check_in(
  p_appointment_id uuid default null,
  p_group_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_rows jsonb;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_appointment_id is null and p_group_id is null then
    raise exception 'preview_check_in requires an appointment id or group id';
  end if;

  select jsonb_agg(row_to_json(t)::jsonb order by (t.pax))
  into v_rows
  from (
    select
      a.id, a.appointment_group_id, a.service_id, a.service_name, a.service_items,
      a.item_count, a.total_price, a.payment_status, a.status,
      a.appointment_date, a.start_time, a.end_time,
      a.therapist_id, a.room_id, a.room_unit_id,
      a.therapist_assignment_state, a.room_assignment_state,
      a.assignment_source, a.requested_therapist_id, a.requested_gender,
      row_number() over (order by a.start_time, a.id) as pax,
      -- PROVISIONAL therapist suggestion (read-only; NOT persisted, queue NOT seeded).
      -- Concrete rows keep their id; anonymous rows get a best-effort eligible pick.
      coalesce(a.therapist_id, (
        select th.id from public.therapists th
        where th.outlet_id = a.outlet_id and coalesce(th.availability_status,true)
          and lower(coalesce(th.role,'therapist')) = 'therapist'
          and (a.requested_gender is null or lower(th.gender) = lower(a.requested_gender))
          and (th.service_commissions = '{}'::jsonb or th.service_commissions ? a.service_id::text)
          and not exists (
            select 1 from public.appointments b
            where b.therapist_id = th.id and b.id <> a.id
              and public.csp_blocks_schedule(b.status::text)
              and public.csp_appointment_start_at(b) < public.csp_appointment_block_end_at(a)
              and public.csp_appointment_block_end_at(b) > public.csp_appointment_start_at(a))
        order by th.name limit 1
      )) as provisional_therapist_id,
      coalesce(a.room_id, (
        select r.id from public.rooms r
        join public.services s on s.id = a.service_id
        where r.outlet_id = a.outlet_id and coalesce(r.is_active,true)
          and lower(coalesce(r.room_type::text,'')) = lower(coalesce(s.room_type::text,''))
        order by r.name limit 1
      )) as provisional_room_id,
      (a.therapist_id is null or a.room_id is null) as is_provisional
    from public.appointments a
    where (p_group_id is not null and a.appointment_group_id = p_group_id)
       or (p_group_id is null and a.id = p_appointment_id)
  ) t;

  if v_rows is null then
    raise exception 'Appointment or group was not found.';
  end if;

  return jsonb_build_object(
    'appointments', v_rows,
    'total_amount', (select sum((r ->> 'total_price')::numeric) from jsonb_array_elements(v_rows) r),
    'payment_status', (select min(r ->> 'payment_status') from jsonb_array_elements(v_rows) r),
    'note', 'Suggestions are PROVISIONAL. Concrete resources are selected and confirmed only by confirm_and_start.'
  );
end;
$function$;
revoke all on function public.preview_check_in(uuid, uuid) from public, anon;
grant execute on function public.preview_check_in(uuid, uuid) to authenticated, service_role;

-- ============ confirm_and_start_appointment (atomic, idempotent) ============
create or replace function public.confirm_and_start_appointment(
  p_appointment_id uuid,
  p_idempotency_key text default null,
  p_end_time time without time zone default null,
  p_end_at timestamp with time zone default null,
  p_allow_late_extension_overlap boolean default false,
  p_customer_id uuid default null,
  p_customer_name text default ''::text,
  p_customer_phone text default ''::text,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash'::text,
  p_receipt_number text default ''::text,
  p_transaction_notes text default ''::text)
returns table(success boolean, appointment_id uuid, transaction_id uuid,
              therapist_id uuid, room_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_appt public.appointments%rowtype;
  v_txn uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  -- Lock the row: serialises two-device confirmation.
  select * into v_appt from public.appointments a where a.id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, null::uuid, null::uuid, null::uuid, 'NOT_FOUND', 'Appointment was not found.'; return;
  end if;

  -- Reject terminal / invalid states.
  if v_appt.status in ('cancelled','completed','no_show') or v_appt.payment_status = 'voided' then
    return query select false, p_appointment_id, null::uuid, v_appt.therapist_id, v_appt.room_id,
      'INVALID_STATE', 'Appointment is cancelled, completed, voided or otherwise not startable.'; return;
  end if;

  -- IDEMPOTENT short-circuit: already started -> return existing result, no re-charge/re-start/re-consume.
  if v_appt.actual_started_at is not null then
    -- (122b fix) qualify: appointment_id is also an OUT-param name -> ambiguous otherwise.
    select t.id into v_txn from public.transactions t where t.appointment_id = p_appointment_id and t.source = 'appointment' order by t.created_at limit 1;
    return query select true, p_appointment_id, v_txn, v_appt.therapist_id, v_appt.room_id, null::text, null::text; return;
  end if;

  -- Confirm/select concrete resources (auto-substitute normal; preserve+conflict requested/manual).
  begin
    v_appt := public.reconcile_appointment_resources(p_appointment_id, true);
  exception when others then
    return query select false, p_appointment_id, null::uuid, v_appt.therapist_id, v_appt.room_id,
      'RESOURCE_CONFLICT', sqlerrm; return;
  end;
  if v_appt.assignment_error_code is not null then
    return query select false, p_appointment_id, null::uuid, v_appt.therapist_id, v_appt.room_id,
      v_appt.assignment_error_code, coalesce(v_appt.assignment_error_message, 'Resource assignment failed.'); return;
  end if;

  if v_appt.payment_status = 'paid' then
    -- Already paid (e.g. Billplz): start WITHOUT charging again.
    if p_allow_late_extension_overlap then perform set_config('app.allow_late_extension_overlap','on', true); end if;
    update public.appointments a
    set actual_started_at = now(), status = 'in_progress',
        end_time = coalesce(p_end_time, a.end_time), end_at = coalesce(p_end_at, a.end_at), updated_at = now()
    where a.id = p_appointment_id returning a.* into v_appt;   -- trigger consumes queue turn once
    v_txn := null;
  else
    -- Unpaid: record payment AND start together via the existing tested RPC.
    select cw.transaction_id into v_txn
    from public.checkout_appointment_with_payment(
      p_appointment_id, coalesce(p_customer_id, v_appt.customer_id), p_customer_name, p_customer_phone,
      null, null, null, null, null, p_end_time, p_end_at, p_allow_late_extension_overlap,
      p_counter_staff_id, p_counter_staff_name, p_service_price, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes) cw;
    select * into v_appt from public.appointments where id = p_appointment_id;
  end if;

  return query select true, p_appointment_id, v_txn, v_appt.therapist_id, v_appt.room_id, null::text, null::text;
end;
$function$;
revoke all on function public.confirm_and_start_appointment(uuid,text,time,timestamptz,boolean,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text) from public, anon;
grant execute on function public.confirm_and_start_appointment(uuid,text,time,timestamptz,boolean,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text) to authenticated, service_role;

-- ============ confirm_and_start_group (atomic, idempotent, all-or-none) ============
create or replace function public.confirm_and_start_group(
  p_group_id uuid,
  p_idempotency_key text default null,
  p_customer_id uuid default null,
  p_customer_name text default ''::text,
  p_customer_phone text default ''::text,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash'::text,
  p_receipt_number text default ''::text,
  p_transaction_notes text default ''::text)
returns table(success boolean, appointment_group_id uuid, appointment_ids uuid[], transaction_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_ids uuid[];
  v_member record;
  v_all_started boolean;
  v_any_invalid boolean;
  v_payment_status text;
  v_txn uuid;
  v_locked int;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  -- Lock every member of the group first (all-or-none unit; serialises two
  -- devices). (122c fix) FOR UPDATE cannot coexist with the aggregates below, so
  -- lock in a plain sub-select, then aggregate the locked rows separately.
  select count(*) into v_locked from (
    select a.id from public.appointments a
    where a.appointment_group_id = p_group_id order by a.start_time, a.id for update) locked;
  if coalesce(v_locked, 0) = 0 then
    return query select false, p_group_id, null::uuid[], null::uuid, 'NOT_FOUND', 'Group was not found.'; return;
  end if;

  select array_agg(a.id order by a.start_time, a.id), bool_and(a.actual_started_at is not null),
         bool_or(a.status in ('cancelled','completed','no_show') or a.payment_status = 'voided'),
         min(a.payment_status::text)
  into v_ids, v_all_started, v_any_invalid, v_payment_status
  from public.appointments a where a.appointment_group_id = p_group_id;
  if v_any_invalid then
    return query select false, p_group_id, v_ids, null::uuid, 'INVALID_STATE', 'A group member is cancelled/completed/voided.'; return;
  end if;

  -- IDEMPOTENT: whole group already started -> return existing.
  if v_all_started then
    select t.id into v_txn from public.transactions t where t.appointment_group_id = p_group_id order by t.created_at limit 1;
    return query select true, p_group_id, v_ids, v_txn, null::text, null::text; return;
  end if;

  -- Reconcile the whole group (Migration 116 reconciles the entire assignment unit
  -- atomically from any member) and confirm concrete resources.
  begin
    perform public.reconcile_appointment_resources(v_ids[1], true);
  exception when others then
    return query select false, p_group_id, v_ids, null::uuid, 'RESOURCE_CONFLICT', sqlerrm; return;
  end;
  for v_member in select a.id, a.assignment_error_code, a.assignment_error_message from public.appointments a where a.appointment_group_id = p_group_id loop
    if v_member.assignment_error_code is not null then
      return query select false, p_group_id, v_ids, null::uuid, v_member.assignment_error_code,
        coalesce(v_member.assignment_error_message, 'Resource assignment failed for a group member.'); return;
    end if;
  end loop;

  if v_payment_status = 'paid' then
    update public.appointments a set actual_started_at = now(), status = 'in_progress', updated_at = now()
    where a.appointment_group_id = p_group_id and a.actual_started_at is null;  -- triggers consume each turn once
    v_txn := null;
  else
    select cg.transaction_id into v_txn
    from public.checkout_appointment_group_with_payment(
      p_group_id, v_ids, p_customer_id, p_customer_name, p_customer_phone, '{}'::jsonb,
      p_counter_staff_id, p_counter_staff_name, p_service_price, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes) cg;
  end if;

  return query select true, p_group_id, v_ids, v_txn, null::text, null::text;
end;
$function$;
revoke all on function public.confirm_and_start_group(uuid,text,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text) from public, anon;
grant execute on function public.confirm_and_start_group(uuid,text,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text) to authenticated, service_role;

commit;
