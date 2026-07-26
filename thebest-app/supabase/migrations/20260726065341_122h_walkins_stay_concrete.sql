-- Phase 6B.1 integration repair — RC-1: walk-ins must never become anonymous.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726065341.
-- This file is the verbatim SQL that was applied.
--
-- REPRODUCED on staging with capacity_first_enabled ON for Taman Wahyu:
--   create_appointment_with_csp(therapist=>29bb45ac…, room=>8df942f1…,
--     service=>ada67148…, 14:00-15:00, type=>'walkin', source=>'queue')
--   => SQLSTATE 22023
--      "Outlet, start, positive duration, and therapist are required."
--
-- CHAIN:
--   1. 122e's wrapper correctly excludes type='walkin' from its own flag-ON
--      branch and delegates to create_appointment_with_csp_121_legacy.
--   2. That legacy body has its OWN flag-ON branch guarded only on
--      v_source in ('queue','gender_preference') -- no type check. It sets
--      therapist_id and room_id to NULL and inserts anonymous.
--   3. BEFORE INSERT trigger appointments_walkin_future_capacity_guard calls
--      check_walkin_protects_future(outlet, start, duration, NULL therapist),
--      which raises 22023.
--
-- So the wrapper's walk-in guard was ineffective: delegation landed in a body
-- that anonymised walk-ins anyway. Affects single-pax AND multi-pax walk-ins
-- (create_appointment_group_with_csp calls the same function), i.e. both
-- create_walkin_appointment_with_payment and create_staff_walkin_with_payment,
-- which pass p_type => 'walkin'.
--
-- FIX: add the walk-in exclusion to both legacy flag-ON branches. Walk-ins then
-- always take the concrete path: concrete therapist, concrete room, room unit
-- assigned by the existing appointments_assign_room_unit trigger, and both
-- assignment states 'confirmed' via normalize_appointment_assignment_states.
--
-- Bodies are otherwise reproduced verbatim from the deployed
-- pg_get_functiondef / prosrc. Only the two flag-ON guards change.
--
-- VERIFIED transactionally before applying: with the guard in place the same
-- walk-in succeeds under flag ON with therapist=29bb45ac…, room=8df942f1…,
-- room_unit_name='Room 7', therapist_assignment_state=confirmed,
-- room_assignment_state=confirmed, type=walkin.
--
-- ROLLBACK: remove the two added guard lines
--   `and coalesce(nullif(p_type, ''), 'appointment') <> 'walkin'`  (create)
--   `and v_appt.type::text <> 'walkin'`                            (update)
-- and re-apply. Doing so reintroduces the 22023 walk-in failure whenever
-- capacity_first_enabled is ON.

create or replace function public.create_appointment_with_csp_121_legacy(
  p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid,
  p_date date, p_start_time time without time zone, p_end_time time without time zone,
  p_total_price numeric, p_type text default 'appointment'::text,
  p_created_by uuid default auth.uid(), p_service_name text default ''::text,
  p_service_items jsonb default '[]'::jsonb, p_item_count integer default 1,
  p_notes text default ''::text, p_appointment_group_id uuid default null::uuid,
  p_assignment_source text default 'queue'::text, p_requested_therapist_id uuid default null::uuid,
  p_requested_gender text default null::text, p_is_provisional boolean default false)
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare
  v_check record; v_start_at timestamp; v_end_at timestamp;
  v_outlet uuid; v_buffer integer; v_room_type text;
  v_source text := coalesce(nullif(p_assignment_source, ''), 'queue'); v_feasible jsonb;
begin
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false; appointment_id := null; error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.'; return next; return;
  end if;
  v_start_at := public.csp_start_at(p_date, p_start_time);
  v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);

  select s.outlet_id, coalesce(s.buffer_after_minutes, 0), lower(coalesce(s.room_type::text, ''))
    into v_outlet, v_buffer, v_room_type from public.services s where s.id = p_service_id;

  -- RC-1: a walk-in is an in-progress, physically present customer. It can never
  -- be anonymous future capacity demand, and the walk-in capacity guard rejects
  -- a NULL therapist outright.
  if v_outlet is not null and public.capacity_first_enabled(v_outlet)
     and coalesce(nullif(p_type, ''), 'appointment') <> 'walkin'
     and v_source in ('queue', 'gender_preference') then
    perform set_config('lock_timeout', '2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_date::text, 0));
    v_feasible := public.capacity_feasible(v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', p_service_id::text,
        'room_type', v_room_type, 'requested_gender', p_requested_gender, 'pax_index', 0)), 'hard');
    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough anonymous ' || coalesce(v_feasible ->> 'dimension', 'therapist') || ' capacity for the requested time.';
      return next; return;
    end if;
    insert into public.appointments (
      appointment_group_id, customer_id, therapist_id, room_id, service_id,
      appointment_date, start_time, end_time, start_at, end_at, status, total_price, type,
      service_name, service_items, item_count, notes, created_at, created_by,
      assignment_source, requested_therapist_id, requested_gender,
      therapist_assignment_state, room_assignment_state)
    values (
      p_appointment_group_id, p_customer_id, null, null, p_service_id,
      p_date, p_start_time, p_end_time, v_start_at, v_end_at, 'confirmed', p_total_price,
      coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
      coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb),
      greatest(coalesce(p_item_count, 1), 1), coalesce(p_notes, ''), now(), p_created_by,
      v_source, p_requested_therapist_id, p_requested_gender, 'pending', 'pending')
    returning id into appointment_id;
    success := true; error_code := null; error_message := null; return next; return;
  end if;

  select * into v_check from public.check_booking_availability(p_date, p_start_time, p_end_time, p_therapist_id, p_room_id);
  if not coalesce(v_check.therapist_available, false) then
    success := false; appointment_id := null; error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.'; return next; return;
  end if;
  if coalesce(v_check.room_full, false) then
    success := false; appointment_id := null; error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.'; return next; return;
  end if;
  insert into public.appointments (
    appointment_group_id, customer_id, therapist_id, room_id, service_id,
    appointment_date, start_time, end_time, start_at, end_at, status, total_price, type,
    service_name, service_items, item_count, notes, created_at, created_by,
    assignment_source, requested_therapist_id, requested_gender)
  values (
    p_appointment_group_id, p_customer_id, p_therapist_id, p_room_id, p_service_id,
    p_date, p_start_time, p_end_time, v_start_at, v_end_at, 'confirmed', p_total_price,
    coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
    coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb),
    greatest(coalesce(p_item_count, 1), 1), coalesce(p_notes, ''), now(), p_created_by,
    coalesce(nullif(p_assignment_source, ''), 'queue'), p_requested_therapist_id, p_requested_gender)
  returning id into appointment_id;
  success := true; error_code := null; error_message := null; return next;
end;
$function$;

create or replace function public.update_appointment_with_csp_121_legacy(
  p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date,
  p_start_time time without time zone, p_end_time time without time zone,
  p_assignment_source text default null::text, p_requested_therapist_id uuid default null::uuid,
  p_requested_gender text default null::text, p_is_provisional boolean default null::boolean)
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
declare
  v_check record; v_appt public.appointments%rowtype;
  v_outlet uuid; v_buffer integer; v_room_type text;
  v_source text; v_feasible jsonb; v_start_at timestamp; v_end_at timestamp;
begin
  select * into v_appt from public.appointments a where a.id = p_appointment_id;
  if not found then
    success := false; appointment_id := null; error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.'; return next; return;
  end if;
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false; appointment_id := null; error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.'; return next; return;
  end if;
  v_source := coalesce(nullif(p_assignment_source,''), v_appt.assignment_source, 'queue');
  select s.outlet_id, coalesce(s.buffer_after_minutes,0), lower(coalesce(s.room_type::text,''))
    into v_outlet, v_buffer, v_room_type from public.services s where s.id = v_appt.service_id;

  -- RC-1: nulling a walk-in's therapist would make
  -- normalize_appointment_assignment_states force both states to 'confirmed'
  -- (its type='walkin' branch) and then violate CHECK
  -- appointments_started_requires_concrete.
  if v_outlet is not null and public.capacity_first_enabled(v_outlet)
     and v_appt.type::text <> 'walkin'
     and v_source in ('queue','gender_preference') and v_appt.actual_started_at is null then
    v_start_at := public.csp_start_at(p_date, p_start_time);
    v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);
    perform set_config('lock_timeout','2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_date::text, 0));
    v_feasible := public.capacity_feasible(v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at,'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at))/60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', v_appt.service_id::text, 'room_type', v_room_type,
        'requested_gender', p_requested_gender, 'pax_index', 0)), 'hard', p_appointment_id);
    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough anonymous capacity for the new time.'; return next; return;
    end if;
    update public.appointments
    set therapist_id = null, room_id = null, room_unit_id = null,
        therapist_assignment_state = 'pending', room_assignment_state = 'pending',
        appointment_date = p_date, start_time = p_start_time, end_time = p_end_time,
        start_at = v_start_at, end_at = v_end_at, assignment_source = v_source,
        requested_therapist_id = p_requested_therapist_id, requested_gender = p_requested_gender, updated_at = now()
    where id = p_appointment_id returning id into appointment_id;
    success := true; error_code := null; error_message := null; return next; return;
  end if;

  select * into v_check from public.check_booking_availability(p_date, p_start_time, p_end_time, p_therapist_id, p_room_id, p_appointment_id);
  if not coalesce(v_check.therapist_available, false) then
    success := false; appointment_id := null; error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.'; return next; return;
  end if;
  if coalesce(v_check.room_full, false) then
    success := false; appointment_id := null; error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.'; return next; return;
  end if;
  update public.appointments
  set therapist_id = p_therapist_id, room_id = p_room_id, appointment_date = p_date,
      start_time = p_start_time, end_time = p_end_time,
      start_at = public.csp_start_at(p_date, p_start_time), end_at = public.csp_end_at(p_date, p_start_time, p_end_time),
      assignment_source = coalesce(p_assignment_source, assignment_source),
      requested_therapist_id = case when p_assignment_source is not null then p_requested_therapist_id else requested_therapist_id end,
      requested_gender = case when p_assignment_source is not null then p_requested_gender else requested_gender end,
      updated_at = now()
  where id = p_appointment_id returning id into appointment_id;
  success := true; error_code := null; error_message := null; return next;
end;
$function$;

-- 122e locked these to owner-only; CREATE OR REPLACE preserves ACLs, but
-- reassert so the intent is explicit and drift-proof.
revoke all on function public.create_appointment_with_csp_121_legacy(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) from public, anon, authenticated, service_role;

revoke all on function public.update_appointment_with_csp_121_legacy(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) from public, anon, authenticated, service_role;
