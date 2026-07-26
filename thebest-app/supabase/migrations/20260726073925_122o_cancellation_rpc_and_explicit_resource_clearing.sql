-- Phase 6B.1 Batch 1.2 + 1.4 — dedicated cancellation RPCs and explicit
-- nullable-resource clearing.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726073925.
--
-- Cancellation was previously a generic PostgREST UPDATE through
-- SupabaseTableService, which could silently no-op under RLS or an outlet-scope
-- mismatch and recorded no cancellation metadata.
--
-- VERIFIED transactionally before applying:
--   C1 cancel -> status cancelled, reason + cancelled_by stored,
--      csp_blocks_schedule false, transactions retained, and the therapist's
--      walk-in availability flipped busy -> free_now (capacity really released)
--   C2 repeat -> idempotent success
--   C3 completed -> rejected ALREADY_COMPLETED
--
-- ROLLBACK:
--   drop function if exists public.clear_appointment_resources(uuid,boolean,boolean,boolean,boolean,boolean);
--   drop function if exists public.cancel_appointment_group(uuid,text);
--   drop function if exists public.cancel_appointment(uuid,text);
--   alter table public.appointments
--     drop column if exists cancellation_reason,
--     drop column if exists cancelled_by,
--     drop column if exists cancelled_at;
--   Dropping the columns discards recorded cancellation metadata.

alter table public.appointments
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid,
  add column if not exists cancellation_reason text;

do $fk$
begin
  if not exists (select 1 from pg_constraint
    where conrelid='public.appointments'::regclass and conname='appointments_cancelled_by_fkey') then
    alter table public.appointments add constraint appointments_cancelled_by_fkey
      foreign key (cancelled_by) references public.profiles(id) on delete set null;
  end if;
end;
$fk$;

comment on column public.appointments.cancelled_at is
  'When the appointment was cancelled through cancel_appointment(). NULL for rows cancelled before the dedicated RPC existed.';

create or replace function public.cancel_appointment(
  p_appointment_id uuid, p_reason text default '')
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare v_a public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, 'NOT_FOUND','Appointment was not found.'; return;
  end if;
  if v_a.status::text = 'completed' then
    return query select false, p_appointment_id, 'ALREADY_COMPLETED',
      'A completed service cannot be cancelled.'; return;
  end if;
  -- Idempotent.
  if v_a.status::text in ('cancelled','canceled') then
    return query select true, p_appointment_id, null::text, null::text; return;
  end if;
  if v_a.actual_started_at is not null or v_a.status::text = 'in_progress' then
    return query select false, p_appointment_id, 'ALREADY_STARTED',
      'A started service cannot be cancelled; complete it or mark it no-show.'; return;
  end if;

  -- Capacity is released by the status change alone: csp_blocks_schedule
  -- ('cancelled') is false, so every availability query, the overlap trigger and
  -- capacity_feasible stop counting this row (verified: therapist flipped
  -- busy -> free_now). therapist_id / room_id / room_unit_id are deliberately
  -- RETAINED as the record of what was held; clearing them would destroy audit
  -- history and, because normalize_appointment_assignment_states forces both
  -- states to 'confirmed' for terminal rows, would trip CHECK
  -- appointments_confirmed_room_concrete.
  --
  -- Payment history is untouched. The therapist queue is untouched: consumption
  -- is bound to the actual_started_at transition, which cancellation never makes.
  update public.appointments a
  set status = 'cancelled',
      cancelled_at = now(), cancelled_by = auth.uid(),
      cancellation_reason = nullif(p_reason,''),
      updated_at = now()
  where a.id = p_appointment_id;

  return query select true, p_appointment_id, null::text, null::text;
end;
$function$;

create or replace function public.cancel_appointment_group(
  p_group_id uuid, p_reason text default '')
returns table(success boolean, appointment_group_id uuid, cancelled_count integer,
              error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare
  v_g public.appointment_groups%rowtype; v_a public.appointments%rowtype;
  v_id uuid; v_n int := 0; v_ids uuid[] := array[]::uuid[];
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_g from public.appointment_groups where id = p_group_id for update;
  if not found then
    return query select false, p_group_id, 0, 'NOT_FOUND','Group was not found.'; return;
  end if;

  -- Validate every pax before cancelling any, so the group never ends up half
  -- cancelled.
  for v_id in select a.id from public.appointments a
              where a.appointment_group_id = p_group_id order by a.id
  loop
    select * into v_a from public.appointments where id = v_id for update;
    v_ids := array_append(v_ids, v_id);
    if v_a.status::text in ('cancelled','canceled') then continue; end if;
    if v_a.status::text = 'completed' then
      return query select false, p_group_id, 0, 'ALREADY_COMPLETED',
        format('Pax %s is completed.', v_id); return;
    end if;
    if v_a.actual_started_at is not null or v_a.status::text = 'in_progress' then
      return query select false, p_group_id, 0, 'ALREADY_STARTED',
        format('Pax %s has already started.', v_id); return;
    end if;
  end loop;

  if array_length(v_ids,1) is null then
    return query select false, p_group_id, 0, 'EMPTY_GROUP','The group has no pax.'; return;
  end if;

  foreach v_id in array v_ids loop
    select * into v_a from public.appointments where id = v_id;
    if v_a.status::text not in ('cancelled','canceled') then
      update public.appointments
      set status='cancelled', cancelled_at=now(), cancelled_by=auth.uid(),
          cancellation_reason=nullif(p_reason,''), updated_at=now()
      where id = v_id;
      v_n := v_n + 1;
    end if;
  end loop;

  update public.appointment_groups set status='cancelled'
  where id = p_group_id and coalesce(status,'') is distinct from 'cancelled';

  return query select true, p_group_id, v_n, null::text, null::text;
end;
$function$;

-- Explicit, supported path for clearing nullable resource fields. The generic
-- table serializer drops every NULL, so a resource can never be released
-- through it; this RPC exists so callers do not need that behaviour changed
-- globally.
create or replace function public.clear_appointment_resources(
  p_appointment_id uuid,
  p_clear_therapist boolean default false,
  p_clear_room boolean default false,
  p_clear_room_unit boolean default false,
  p_clear_requested_therapist boolean default false,
  p_clear_requested_gender boolean default false)
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare v_a public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, 'NOT_FOUND','Appointment was not found.'; return;
  end if;

  -- A started, completed or resource-confirmed row must keep concrete
  -- resources (CHECK appointments_started_requires_concrete).
  if v_a.actual_started_at is not null
     or v_a.resources_confirmed_at is not null
     or v_a.status::text in ('in_progress','completed') then
    return query select false, p_appointment_id, 'NOT_CLEARABLE',
      'Started or resource-confirmed appointments keep their resources.'; return;
  end if;

  update public.appointments a
  set therapist_id = case when p_clear_therapist then null else a.therapist_id end,
      therapist_assignment_state = case when p_clear_therapist then 'pending'
        else a.therapist_assignment_state end,
      therapist_auto_assigned_at = case when p_clear_therapist then null
        else a.therapist_auto_assigned_at end,
      room_id = case when p_clear_room then null else a.room_id end,
      room_assignment_state = case when p_clear_room then 'pending'
        else a.room_assignment_state end,
      room_unit_id = case when p_clear_room or p_clear_room_unit then null else a.room_unit_id end,
      room_unit_name = case when p_clear_room or p_clear_room_unit then '' else a.room_unit_name end,
      requested_therapist_id = case when p_clear_requested_therapist then null
        else a.requested_therapist_id end,
      requested_gender = case when p_clear_requested_gender then null else a.requested_gender end,
      updated_at = now()
  where a.id = p_appointment_id;

  return query select true, p_appointment_id, null::text, null::text;
end;
$function$;

revoke all on function public.cancel_appointment(uuid, text) from public, anon;
grant execute on function public.cancel_appointment(uuid, text) to authenticated;
revoke all on function public.cancel_appointment_group(uuid, text) from public, anon;
grant execute on function public.cancel_appointment_group(uuid, text) to authenticated;
revoke all on function public.clear_appointment_resources(uuid, boolean, boolean, boolean, boolean, boolean)
  from public, anon;
grant execute on function public.clear_appointment_resources(uuid, boolean, boolean, boolean, boolean, boolean)
  to authenticated;
