-- Phase 6B.1 — Priority 3: separate Check In from Start Service.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726072526.
--
-- Lifecycle (product owner decision, 2026-07-26):
--   checked_in_at      customer arrives; status stays 'confirmed'
--   actual_started_at  therapist begins; status becomes 'in_progress'
--   booked_*           immutable scheduled truth
--   start_at / end_at  operational blocking window, moved only by START
--
-- BEFORE: check_in_paid_appointment_with_addon set actual_started_at,
-- status='in_progress' and end_time/end_at in one statement, so "check in" and
-- "start service" were indistinguishable and an early check-in corrupted the
-- operational window (the RC-2 chain fixed by 122i/122l).
--
-- AFTER: check-in stamps only checked_in_at/checked_in_by and records payment.
-- Starting remains start_appointment_service, unchanged in this migration.
--
-- VERIFIED transactionally before applying:
--   single  T1 check-in -> status confirmed, actual NULL, checked_in_by set,
--                          operational 17:23-18:13 UNCHANGED, booked preserved,
--                          transactions +1
--           T2 repeat   -> transaction delta 0 (no double charge)
--           T3 start    -> in_progress, checked_in_at preserved, operational
--                          15:23-16:13, block +0.833h, booked preserved
--   group   G1 -> 2/2 checked in, 0 started, transactions +1
--           G2 repeat -> transaction delta 0
--           G3 partial group -> rejected, INVALID_APPOINTMENTS
--
-- Neither function touches therapist_queue: queue consumption stays bound to
-- actual_started_at via the existing appointment_actual_start_consumes_queue
-- trigger, which check-in never fires.
--
-- BEHAVIOUR CHANGE: the legacy wrappers keep p_end_time / p_end_at /
-- p_allow_late_extension_overlap / p_per_appointment_updates in their
-- signatures for caller compatibility but now IGNORE them, because check-in
-- must not move the operational window. Add-on duration must be supplied to
-- start_appointment_service(p_expected_end_at) at START. Wiring that properly
-- belongs to the start-redesign priority and is out of scope here.
--
-- ROLLBACK: re-apply the pre-122m bodies of the two check_in_paid_* functions
-- (they set actual_started_at/status/end_time/end_at inline) and
--   drop function if exists public.check_in_appointment_group(uuid,uuid[],jsonb,uuid,text,numeric,numeric,numeric,text,text);
--   drop function if exists public.check_in_appointment(uuid,jsonb,uuid,text,numeric,numeric,numeric,text,text);
-- Doing so re-fuses check-in with start.

create or replace function public.check_in_appointment(
  p_appointment_id uuid,
  p_addon_service_items jsonb default '[]'::jsonb,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default ''
)
returns table(success boolean, appointment_id uuid, transaction_id uuid,
              checked_in_at timestamptz, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare
  v_a public.appointments%rowtype; v_c public.customers%rowtype;
  v_first jsonb; v_sid uuid; v_snm text; v_tnm text := ''; v_rnm text := '';
  v_txn uuid; v_pay boolean;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, null::uuid, null::timestamptz,
      'NOT_FOUND','Appointment was not found.'; return;
  end if;
  if v_a.actual_started_at is not null then
    return query select false, p_appointment_id, null::uuid, v_a.checked_in_at,
      'ALREADY_STARTED','The service has already started.'; return;
  end if;
  if v_a.status::text not in ('pending','confirmed') then
    return query select false, p_appointment_id, null::uuid, v_a.checked_in_at,
      'NOT_CHECKABLE','Only a pending or confirmed appointment can be checked in.'; return;
  end if;
  if v_a.appointment_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    return query select false, p_appointment_id, null::uuid, v_a.checked_in_at,
      'WRONG_DATE','Check-in is only allowed on the appointment date.'; return;
  end if;

  v_pay := jsonb_array_length(coalesce(p_addon_service_items,'[]'::jsonb)) > 0
           and coalesce(p_total_amount,0) > 0;

  -- Idempotent: a repeated check-in never re-stamps and never re-charges.
  if v_a.checked_in_at is not null then
    select t.id into v_txn from public.transactions t
    where t.appointment_id = p_appointment_id and t.source = 'appointment_addon'
    order by t.created_at desc limit 1;
    return query select true, p_appointment_id, v_txn, v_a.checked_in_at,
      null::text, null::text; return;
  end if;

  -- The SET list deliberately excludes actual_started_at, status, start_at,
  -- end_at, start_time and end_time, so no schedule trigger fires and the
  -- operational window cannot move.
  update public.appointments a
  set checked_in_at = now(), checked_in_by = auth.uid(), updated_at = now()
  where a.id = p_appointment_id returning * into v_a;

  if v_pay then
    select * into v_c from public.customers where id = v_a.customer_id;
    select coalesce(name,'') into v_tnm from public.therapists where id = v_a.therapist_id;
    select coalesce(name,'') into v_rnm from public.rooms where id = v_a.room_id;
    v_first := p_addon_service_items -> 0;
    v_sid := nullif(coalesce(v_first->>'id', v_first->>'serviceId'),'')::uuid;
    v_snm := coalesce(v_first->>'name','Service add-on');
    insert into public.transactions (
      outlet_id, appointment_id, customer_id, customer_name, customer_phone,
      service_id, service_name, service_items, item_count,
      therapist_id, therapist_name, counter_staff_id, counter_staff_name,
      room_id, room_name, service_price, sst_amount, total_amount,
      therapist_commission_amount, counter_commission_amount,
      source, payment_method, payment_status, receipt_number, notes)
    values (
      v_a.outlet_id, p_appointment_id, v_a.customer_id,
      coalesce(v_c.name,''), coalesce(v_c.phone,''),
      v_sid, v_snm, p_addon_service_items, jsonb_array_length(p_addon_service_items),
      v_a.therapist_id, v_tnm, p_counter_staff_id, p_counter_staff_name,
      v_a.room_id, v_rnm, p_service_price, p_sst_amount, p_total_amount,
      public.csp_commission_for_items(p_addon_service_items, v_a.therapist_id,'Therapist'),
      case when p_counter_staff_id is null then 0
        else public.csp_commission_for_items(p_addon_service_items, p_counter_staff_id,'Counter') end,
      'appointment_addon',
      coalesce(nullif(p_payment_method,''),'cash')::public.payment_method,
      'paid'::public.payment_status, p_receipt_number,
      'Services added during appointment check-in')
    returning id into v_txn;

    -- Freeze the original online receipt's commission from its own snapshot so
    -- newly appended items cannot be counted twice at completion.
    update public.transactions original
    set therapist_commission_amount = public.csp_commission_for_items(
          original.service_items, v_a.therapist_id, 'Therapist'),
        updated_at = now()
    where original.appointment_id = p_appointment_id
      and original.source = 'online_booking'
      and original.payment_status = 'paid'
      and coalesce(original.therapist_commission_amount, 0) = 0;
  end if;

  return query select true, p_appointment_id, v_txn, v_a.checked_in_at, null::text, null::text;
end;
$function$;

create or replace function public.check_in_appointment_group(
  p_appointment_group_id uuid,
  p_appointment_ids uuid[],
  p_addon_items_by_appointment jsonb default '{}'::jsonb,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default ''
)
returns table(success boolean, appointment_group_id uuid, transaction_id uuid,
              checked_in_at timestamptz, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare
  v_id uuid; v_a public.appointments%rowtype; v_first public.appointments%rowtype;
  v_c public.customers%rowtype; v_items jsonb; v_all jsonb := '[]'::jsonb;
  v_first_item jsonb; v_sid uuid; v_snm text; v_tnm text := ''; v_rnm text := '';
  v_comm numeric := 0; v_txn uuid; v_pay boolean; v_stamp timestamptz;
  v_already int := 0; v_total int;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  if p_appointment_ids is null or array_length(p_appointment_ids,1) is null then
    return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
      'INVALID_APPOINTMENTS','No appointments were supplied.'; return;
  end if;

  -- The complete group is required; partial check-in is not a valid state.
  if cardinality(p_appointment_ids) <> (select count(distinct s.id)::int from unnest(p_appointment_ids) s(id))
     or cardinality(p_appointment_ids) <> (select count(*)::int from public.appointments a
          where a.appointment_group_id = p_appointment_group_id) then
    return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
      'INVALID_APPOINTMENTS','The complete appointment group is required.'; return;
  end if;

  v_total := cardinality(p_appointment_ids);
  v_stamp := now();

  -- Lock and validate EVERY pax before writing anything, so a rejection leaves
  -- no partial group state.
  for v_id in select unnest(p_appointment_ids) order by 1 loop
    select * into v_a from public.appointments a
    where a.id = v_id and a.appointment_group_id = p_appointment_group_id for update;
    if not found then
      return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
        'INVALID_APPOINTMENTS', format('Pax %s does not belong to this group.', v_id); return;
    end if;
    if v_a.actual_started_at is not null then
      return query select false, p_appointment_group_id, null::uuid, v_a.checked_in_at,
        'ALREADY_STARTED', format('Pax %s has already started.', v_id); return;
    end if;
    if v_a.status::text not in ('pending','confirmed') then
      return query select false, p_appointment_group_id, null::uuid, v_a.checked_in_at,
        'NOT_CHECKABLE', format('Pax %s is not checkable.', v_id); return;
    end if;
    if v_a.appointment_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
      return query select false, p_appointment_group_id, null::uuid, v_a.checked_in_at,
        'WRONG_DATE', format('Pax %s is not scheduled for today.', v_id); return;
    end if;
    if v_a.checked_in_at is not null then v_already := v_already + 1; end if;
    if v_first.id is null then v_first := v_a; end if;
  end loop;

  -- Already fully checked in: idempotent no-op, no re-charge.
  if v_already = v_total then
    select t.id into v_txn from public.transactions t
    where t.appointment_group_id = p_appointment_group_id and t.source = 'appointment_addon'
    order by t.created_at desc limit 1;
    return query select true, p_appointment_group_id, v_txn, v_first.checked_in_at,
      null::text, null::text; return;
  end if;

  -- Mixed state: refuse rather than compound it.
  if v_already > 0 then
    return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
      'PARTIAL_CHECKIN','Some pax are already checked in; resolve them individually.'; return;
  end if;

  v_pay := coalesce(p_total_amount,0) > 0 and exists (
    select 1 from jsonb_each(coalesce(p_addon_items_by_appointment,'{}'::jsonb)) e
    where jsonb_typeof(e.value)='array' and jsonb_array_length(e.value) > 0);

  foreach v_id in array p_appointment_ids loop
    update public.appointments a
    set checked_in_at = v_stamp, checked_in_by = auth.uid(), updated_at = now()
    where a.id = v_id;
    v_items := coalesce(p_addon_items_by_appointment -> v_id::text, '[]'::jsonb);
    v_all := v_all || v_items;
    select * into v_a from public.appointments where id = v_id;
    v_comm := v_comm + public.csp_commission_for_items(v_items, v_a.therapist_id, 'Therapist');
  end loop;

  if v_pay then
    select * into v_c from public.customers where id = v_first.customer_id;
    select coalesce(name,'') into v_tnm from public.therapists where id = v_first.therapist_id;
    select coalesce(name,'') into v_rnm from public.rooms where id = v_first.room_id;
    v_first_item := v_all -> 0;
    v_sid := nullif(coalesce(v_first_item->>'id', v_first_item->>'serviceId'),'')::uuid;
    v_snm := coalesce(v_first_item->>'name','Service add-on');
    insert into public.transactions (
      outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
      service_id, service_name, service_items, item_count,
      therapist_id, therapist_name, counter_staff_id, counter_staff_name,
      room_id, room_name, service_price, sst_amount, total_amount,
      therapist_commission_amount, counter_commission_amount,
      source, payment_method, payment_status, receipt_number, notes)
    values (
      v_first.outlet_id, p_appointment_group_id, v_first.customer_id,
      coalesce(v_c.name,''), coalesce(v_c.phone,''),
      v_sid, v_snm, v_all, jsonb_array_length(v_all),
      v_first.therapist_id, v_tnm, p_counter_staff_id, p_counter_staff_name,
      v_first.room_id, v_rnm, p_service_price, p_sst_amount, p_total_amount,
      v_comm,
      case when p_counter_staff_id is null then 0
        else public.csp_commission_for_items(v_all, p_counter_staff_id,'Counter') end,
      'appointment_addon',
      coalesce(nullif(p_payment_method,''),'cash')::public.payment_method,
      'paid'::public.payment_status, p_receipt_number,
      'Services added during group appointment check-in')
    returning id into v_txn;
  end if;

  return query select true, p_appointment_group_id, v_txn, v_stamp, null::text, null::text;
end;
$function$;

create or replace function public.check_in_paid_appointment_with_addon(
  p_appointment_id uuid, p_addon_service_items jsonb,
  p_end_time time without time zone default null,
  p_end_at timestamptz default null,
  p_allow_late_extension_overlap boolean default false,
  p_counter_staff_id uuid default null, p_counter_staff_name text default null,
  p_service_price numeric default 0, p_sst_amount numeric default 0,
  p_total_amount numeric default 0, p_payment_method text default 'cash',
  p_receipt_number text default '')
returns table(success boolean, appointment_id uuid, transaction_id uuid,
              error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare r record;
begin
  -- p_end_time / p_end_at / p_allow_late_extension_overlap are accepted for
  -- caller compatibility and intentionally IGNORED: check-in must not move the
  -- operational window. Supply add-on duration to start_appointment_service
  -- (p_expected_end_at) at START instead.
  select * into r from public.check_in_appointment(
    p_appointment_id, p_addon_service_items, p_counter_staff_id, p_counter_staff_name,
    p_service_price, p_sst_amount, p_total_amount, p_payment_method, p_receipt_number);
  return query select r.success, r.appointment_id, r.transaction_id, r.error_code, r.error_message;
end;
$function$;

create or replace function public.check_in_paid_appointment_group_with_addon(
  p_appointment_group_id uuid, p_appointment_ids uuid[],
  p_addon_items_by_appointment jsonb,
  p_per_appointment_updates jsonb default '{}'::jsonb,
  p_counter_staff_id uuid default null, p_counter_staff_name text default null,
  p_service_price numeric default 0, p_sst_amount numeric default 0,
  p_total_amount numeric default 0, p_payment_method text default 'cash',
  p_receipt_number text default '')
returns table(success boolean, appointment_group_id uuid, transaction_id uuid,
              error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare r record;
begin
  -- p_per_appointment_updates carried end_time/end_at/late-overlap flags; it is
  -- accepted for caller compatibility and intentionally IGNORED for the same
  -- reason as the single-appointment wrapper.
  select * into r from public.check_in_appointment_group(
    p_appointment_group_id, p_appointment_ids, p_addon_items_by_appointment,
    p_counter_staff_id, p_counter_staff_name,
    p_service_price, p_sst_amount, p_total_amount, p_payment_method, p_receipt_number);
  return query select r.success, r.appointment_group_id, r.transaction_id, r.error_code, r.error_message;
end;
$function$;

revoke all on function public.check_in_appointment(
  uuid, jsonb, uuid, text, numeric, numeric, numeric, text, text) from public, anon;
grant execute on function public.check_in_appointment(
  uuid, jsonb, uuid, text, numeric, numeric, numeric, text, text) to authenticated;

revoke all on function public.check_in_appointment_group(
  uuid, uuid[], jsonb, uuid, text, numeric, numeric, numeric, text, text) from public, anon;
grant execute on function public.check_in_appointment_group(
  uuid, uuid[], jsonb, uuid, text, numeric, numeric, numeric, text, text) to authenticated;
