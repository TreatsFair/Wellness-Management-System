-- Phase 6B.1 Batch 1.1 — atomic Start Service, separate from Check In.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726073712.
--
-- Since 122m, check-in no longer moves the operational window and the legacy
-- wrappers ignore p_end_time/p_end_at. Any add-on duration bought at check-in
-- would therefore be LOST unless Start applies it. This migration makes Start
-- responsible for the final duration.
--
-- VERIFIED transactionally before applying:
--   single: addon_minutes=20, base 50min -> block 70min; booked 17:35-18:25
--           preserved; operational 15:35-16:45 on a 2h-early start;
--           retry returns the same actual_started_at, status unchanged.
--   group:  2 pax started, both in_progress; retry started_count=0.
--
-- QUEUE EXACTLY ONCE: consume_queue_on_appointment_start fires only on the
-- actual_started_at NULL -> NOT NULL transition and skips NULL therapists and
-- cancelled/voided rows. Because Start is now idempotent and never rewrites
-- actual_started_at, a retry cannot consume a second turn.
--
-- ROLLBACK: restore the pre-122n start_appointment_service (which raised
-- 'This service has already started.' instead of returning the row, and did not
-- add add-on minutes) and
--   drop function if exists public.start_appointment_group_service(uuid, timestamptz, boolean);
--   drop function if exists public.appointment_addon_minutes(uuid);
-- Reverting re-loses check-in add-on duration.

-- Total paid add-on minutes attached to an appointment at check-in.
create or replace function public.appointment_addon_minutes(p_appointment_id uuid)
returns integer
language sql stable
set search_path = public
as $function$
  select coalesce(sum(greatest(coalesce(s.duration, 0), 0)), 0)::integer
  from public.transactions t
  cross join lateral jsonb_array_elements(coalesce(t.service_items, '[]'::jsonb)) it
  join public.services s
    on s.id = nullif(coalesce(it.value ->> 'id', it.value ->> 'serviceId'), '')::uuid
  where t.appointment_id = p_appointment_id
    and t.source = 'appointment_addon'
    and t.payment_status = 'paid';
$function$;

create or replace function public.start_appointment_service(
  p_appointment_id uuid,
  p_started_at timestamptz default now(),
  p_expected_end_at timestamptz default null,
  p_allow_late_extension_overlap boolean default false)
returns public.appointments
language plpgsql security definer set search_path = public
as $function$
declare
  v_a public.appointments%rowtype; v_dur interval; v_addon int;
  v_expected timestamptz; v_upd public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'Appointment was not found.'; end if;

  -- Idempotent: a retry returns the started row unchanged. Because
  -- actual_started_at is not rewritten, consume_queue_on_appointment_start
  -- (which fires only on the NULL -> NOT NULL transition) cannot run twice.
  if v_a.actual_started_at is not null then return v_a; end if;

  if v_a.appointment_date <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service can only be started on its appointment date.';
  end if;
  if v_a.status::text not in ('pending','confirmed') then
    raise exception 'Only a pending or confirmed service can be started.';
  end if;
  if v_a.payment_status::text <> 'paid' then
    raise exception 'Payment must be confirmed before starting this service.';
  end if;

  -- Assigns therapist / room / room_unit and confirms them.
  v_a := public.reconcile_appointment_resources(p_appointment_id, true);

  v_dur := coalesce(
    v_a.booked_end_at - v_a.booked_start_at,
    public.csp_end_at(coalesce(v_a.booked_date, v_a.appointment_date),
                      coalesce(v_a.booked_start_time, v_a.start_time),
                      coalesce(v_a.booked_end_time, v_a.end_time))
    - public.csp_start_at(coalesce(v_a.booked_date, v_a.appointment_date),
                          coalesce(v_a.booked_start_time, v_a.start_time)),
    v_a.end_at - v_a.start_at);
  if v_dur is null or v_dur <= interval '0 seconds' then
    raise exception 'Service duration must be greater than zero.';
  end if;

  -- Add-ons paid at check-in lengthen the service; check-in deliberately did
  -- not move the window, so their duration is applied here.
  v_addon := public.appointment_addon_minutes(p_appointment_id);
  v_expected := coalesce(
    p_expected_end_at,
    p_started_at + v_dur + make_interval(mins => coalesce(v_addon, 0)));
  if v_expected <= p_started_at then
    raise exception 'Expected end time must be after the actual start time.';
  end if;

  perform set_config('app.allow_late_extension_overlap',
    case when p_allow_late_extension_overlap then 'on' else 'off' end, true);

  update public.appointments
  set booked_date = coalesce(booked_date, appointment_date),
      booked_start_time = coalesce(booked_start_time, start_time),
      booked_end_time = coalesce(booked_end_time, end_time),
      booked_start_at = coalesce(booked_start_at,
        public.csp_start_at(appointment_date, start_time) at time zone 'Asia/Kuala_Lumpur'),
      booked_end_at = coalesce(booked_end_at,
        public.csp_end_at(appointment_date, start_time, end_time) at time zone 'Asia/Kuala_Lumpur'),
      therapist_assignment_state = 'confirmed',
      room_assignment_state = 'confirmed',
      resources_confirmed_at = now(),
      resources_confirmed_by = auth.uid(),
      -- A walk-in that starts immediately gets both stamps at the same instant.
      checked_in_at = coalesce(checked_in_at, p_started_at),
      checked_in_by = coalesce(checked_in_by, auth.uid()),
      status = 'in_progress',
      actual_started_at = p_started_at,
      end_at = (v_expected at time zone 'Asia/Kuala_Lumpur'),
      updated_at = now()
  where id = p_appointment_id
  returning * into v_upd;

  return v_upd;
end;
$function$;

create or replace function public.start_appointment_group_service(
  p_group_id uuid,
  p_started_at timestamptz default now(),
  p_allow_late_extension_overlap boolean default false)
returns table(success boolean, appointment_group_id uuid, appointment_ids uuid[],
              started_count integer, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare
  v_g public.appointment_groups%rowtype; v_a public.appointments%rowtype;
  v_ids uuid[] := array[]::uuid[]; v_id uuid; v_n int := 0;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_g from public.appointment_groups where id = p_group_id for update;
  if not found then
    return query select false, p_group_id, v_ids, 0, 'NOT_FOUND','Group was not found.'; return;
  end if;

  -- Lock and validate EVERY pax before starting any of them, so a rejection
  -- leaves the whole group unstarted.
  for v_id in select a.id from public.appointments a
              where a.appointment_group_id = p_group_id order by a.id
  loop
    select * into v_a from public.appointments where id = v_id for update;
    v_ids := array_append(v_ids, v_id);
    if v_a.actual_started_at is not null then continue; end if;
    if v_a.status::text not in ('pending','confirmed') then
      return query select false, p_group_id, v_ids, 0, 'NOT_STARTABLE',
        format('Pax %s is not startable.', v_id); return;
    end if;
    if v_a.payment_status::text <> 'paid' then
      return query select false, p_group_id, v_ids, 0, 'NOT_PAID',
        format('Pax %s is not paid.', v_id); return;
    end if;
    if v_a.appointment_date <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
      return query select false, p_group_id, v_ids, 0, 'WRONG_DATE',
        format('Pax %s is not scheduled for today.', v_id); return;
    end if;
  end loop;

  if array_length(v_ids,1) is null then
    return query select false, p_group_id, v_ids, 0, 'EMPTY_GROUP','The group has no pax.'; return;
  end if;

  -- All validated: start each. Already-started pax are skipped, so a retry
  -- neither restamps nor re-consumes a queue turn.
  foreach v_id in array v_ids loop
    select * into v_a from public.appointments where id = v_id;
    if v_a.actual_started_at is null then
      perform public.start_appointment_service(
        v_id, p_started_at, null, p_allow_late_extension_overlap);
      v_n := v_n + 1;
    end if;
  end loop;

  update public.appointment_groups set status = 'in_progress'
  where id = p_group_id and coalesce(status,'') is distinct from 'in_progress';

  return query select true, p_group_id, v_ids, v_n, null::text, null::text;
end;
$function$;

revoke all on function public.appointment_addon_minutes(uuid) from public, anon;
grant execute on function public.appointment_addon_minutes(uuid) to authenticated;

revoke all on function public.start_appointment_group_service(uuid, timestamptz, boolean)
  from public, anon;
grant execute on function public.start_appointment_group_service(uuid, timestamptz, boolean)
  to authenticated;
