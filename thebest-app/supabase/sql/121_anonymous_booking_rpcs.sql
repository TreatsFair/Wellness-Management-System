-- 121_anonymous_booking_rpcs.sql
-- Phase 6B / Project B. Adds the capacity-first ANONYMOUS branch to the create /
-- update booking RPCs, gated by a per-outlet feature flag that defaults OFF.
--
-- When the flag is OFF (default), every RPC below behaves IDENTICALLY to
-- Migration 116 (the new branch is skipped). When ON, a NORMAL future appointment
-- (assignment_source in 'queue' | 'gender_preference') is stored as anonymous
-- demand: therapist_id/room_id/room_unit_id NULL, assignment states 'pending';
-- capacity is validated with capacity_feasible under a bounded outlet/date
-- advisory lock. Concrete resources are preserved for specific_customer_request
-- and manual_override. Multi-pax groups commit all rows or none.
--
-- Does NOT: convert existing rows, touch online holds, or enable the flag.

begin;

-- ---------- per-outlet feature flag (default OFF) ----------
alter table public.business_settings
  add column if not exists capacity_first_enabled boolean not null default false;

create or replace function public.capacity_first_enabled(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select bs.capacity_first_enabled from public.business_settings bs
      where bs.outlet_id = p_outlet_id limit 1),
    false);
$function$;
revoke all on function public.capacity_first_enabled(uuid) from public, anon;
grant execute on function public.capacity_first_enabled(uuid) to authenticated, service_role;

-- ---------- create_appointment_with_csp ----------
create or replace function public.create_appointment_with_csp(
  p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid,
  p_date date, p_start_time time without time zone, p_end_time time without time zone,
  p_total_price numeric, p_type text default 'appointment'::text,
  p_created_by uuid default auth.uid(), p_service_name text default ''::text,
  p_service_items jsonb default '[]'::jsonb, p_item_count integer default 1,
  p_notes text default ''::text, p_appointment_group_id uuid default null::uuid,
  p_assignment_source text default 'queue'::text, p_requested_therapist_id uuid default null::uuid,
  p_requested_gender text default null::text, p_is_provisional boolean default false)
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_check record;
  v_start_at timestamp;
  v_end_at timestamp;
  v_outlet uuid;
  v_buffer integer;
  v_room_type text;
  v_source text := coalesce(nullif(p_assignment_source, ''), 'queue');
  v_feasible jsonb;
begin
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false; appointment_id := null; error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.'; return next; return;
  end if;

  v_start_at := public.csp_start_at(p_date, p_start_time);
  v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);

  -- ===== Project B capacity-first ANONYMOUS branch (flag ON + normal source) =====
  select s.outlet_id, coalesce(s.buffer_after_minutes, 0), lower(coalesce(s.room_type::text, ''))
    into v_outlet, v_buffer, v_room_type
  from public.services s where s.id = p_service_id;

  if v_outlet is not null
     and public.capacity_first_enabled(v_outlet)
     and v_source in ('queue', 'gender_preference') then
    perform set_config('lock_timeout', '2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_date::text, 0));

    v_feasible := public.capacity_feasible(
      v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', p_service_id::text,
        'room_type', v_room_type, 'requested_gender', p_requested_gender, 'pax_index', 0)),
      'hard');

    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough anonymous ' || coalesce(v_feasible ->> 'dimension', 'therapist')
                       || ' capacity for the requested time.';
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
  -- ===== END anonymous branch. Below is the UNCHANGED Migration 116 concrete path. =====

  select * into v_check
  from public.check_booking_availability(p_date, p_start_time, p_end_time, p_therapist_id, p_room_id);

  if not coalesce(v_check.therapist_available, false) then
    success := false; appointment_id := null; error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.';
    return next; return;
  end if;
  if coalesce(v_check.room_full, false) then
    success := false; appointment_id := null; error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.';
    return next; return;
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

-- ---------- create_appointment_group_with_csp ----------
-- Flag ON: validate the WHOLE group atomically with capacity_feasible (all pax,
-- durations, buffers, eligibility, rooms, existing holds), then insert every pax
-- anonymous (normal source) or concrete (specific/manual). Flag OFF: unchanged.
create or replace function public.create_appointment_group_with_csp(
  p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date,
  p_allocations jsonb, p_type text default 'appointment'::text, p_status text default 'confirmed'::text,
  p_notes text default ''::text, p_created_by uuid default auth.uid())
returns table(success boolean, appointment_group_id uuid, appointment_ids uuid[], error_code text, error_message text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_allocation jsonb;
  v_new_appointment_id uuid;
  v_check record;
  v_therapist_id uuid; v_room_id uuid; v_service_id uuid;
  v_start time; v_end time; v_start_at timestamp; v_end_at timestamp;
  v_group_conflicts integer; v_group_room_slots integer;
  v_outlet uuid; v_buffer integer; v_room_type text;
  v_source text; v_pax integer := 0;
  v_demands jsonb := '[]'::jsonb; v_feasible jsonb; v_use_anon boolean := false;
begin
  appointment_ids := array[]::uuid[];
  if jsonb_typeof(p_allocations) is distinct from 'array' or jsonb_array_length(p_allocations) = 0 then
    success := false; appointment_group_id := null; error_code := 'INVALID_ALLOCATIONS';
    error_message := 'Group booking requires at least one pax allocation.'; return next; return;
  end if;

  -- outlet from the first allocation's service
  select (a ->> 'service_id')::uuid into v_service_id from jsonb_array_elements(p_allocations) a limit 1;
  select s.outlet_id into v_outlet from public.services s where s.id = v_service_id;
  v_use_anon := v_outlet is not null and public.capacity_first_enabled(v_outlet);

  if v_use_anon then
    -- Build the full demand set (all pax) for one atomic feasibility decision.
    for v_allocation in select value from jsonb_array_elements(p_allocations) loop
      v_service_id := (v_allocation ->> 'service_id')::uuid;
      v_start := (v_allocation ->> 'start_time')::time;
      v_end := (v_allocation ->> 'end_time')::time;
      if v_start is null or v_end is null or v_end = v_start then
        success := false; appointment_group_id := null; error_code := 'INVALID_DURATION';
        error_message := 'One pax allocation has an invalid time range.'; return next; return;
      end if;
      v_start_at := public.csp_start_at(p_appointment_date, v_start);
      v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);
      select coalesce(s.buffer_after_minutes,0), lower(coalesce(s.room_type::text,''))
        into v_buffer, v_room_type from public.services s where s.id = v_service_id;
      v_source := coalesce(nullif(v_allocation ->> 'assignment_source',''),'queue');
      v_demands := v_demands || jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at,'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at))/60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', v_service_id::text, 'room_type', v_room_type,
        'requested_gender', nullif(v_allocation ->> 'requested_gender',''),
        'requested_therapist_id', case when v_source in ('specific_customer_request','manual_override')
              then nullif(v_allocation ->> 'requested_therapist_id','') else null end,
        'pax_index', v_pax));
      v_pax := v_pax + 1;
    end loop;

    perform set_config('lock_timeout', '2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_appointment_date::text, 0));
    v_feasible := public.capacity_feasible(v_outlet, v_demands, 'hard');
    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_group_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Group needs more anonymous ' || coalesce(v_feasible ->> 'dimension','therapist') || ' capacity.';
      return next; return;
    end if;
  else
    -- UNCHANGED Migration 116 per-pax concrete validation
    for v_allocation in select value from jsonb_array_elements(p_allocations) loop
      v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
      v_room_id := (v_allocation ->> 'room_id')::uuid;
      v_start := (v_allocation ->> 'start_time')::time;
      v_end := (v_allocation ->> 'end_time')::time;
      if v_start is null or v_end is null or v_end = v_start then
        success := false; appointment_group_id := null; error_code := 'INVALID_DURATION';
        error_message := 'One pax allocation has an invalid time range.'; return next; return;
      end if;
      v_start_at := public.csp_start_at(p_appointment_date, v_start);
      v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);
      select * into v_check from public.check_booking_availability(p_appointment_date, v_start, v_end, v_therapist_id, v_room_id);
      if not coalesce(v_check.therapist_available, false) then
        success := false; appointment_group_id := null; error_code := 'THERAPIST_UNAVAILABLE';
        error_message := 'One pax allocation has a staff conflict.'; return next; return;
      end if;
      select count(*) into v_group_conflicts from jsonb_array_elements(p_allocations) other
        where (other.value ->> 'therapist_id')::uuid = v_therapist_id
          and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
          and public.csp_end_at(p_appointment_date, (other.value ->> 'start_time')::time, (other.value ->> 'end_time')::time) > v_start_at;
      if v_group_conflicts > 1 then
        success := false; appointment_group_id := null; error_code := 'THERAPIST_UNAVAILABLE';
        error_message := 'The same staff cannot serve overlapping pax in one group.'; return next; return;
      end if;
      select count(*) into v_group_room_slots from jsonb_array_elements(p_allocations) other
        where (other.value ->> 'room_id')::uuid = v_room_id
          and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
          and public.csp_end_at(p_appointment_date, (other.value ->> 'start_time')::time, (other.value ->> 'end_time')::time) > v_start_at;
      if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots > coalesce(v_check.room_total_slots, 1) then
        success := false; appointment_group_id := null; error_code := 'ROOM_FULL';
        error_message := 'A room or zone does not have enough slots for this group.'; return next; return;
      end if;
    end loop;
  end if;

  insert into public.appointment_groups (customer_id, group_name, pax_count, appointment_date, status, notes, created_at, created_by)
  values (p_customer_id, coalesce(p_group_name, ''), greatest(coalesce(p_pax_count, jsonb_array_length(p_allocations)), 1),
          p_appointment_date, coalesce(nullif(p_status, ''), 'confirmed'), coalesce(p_notes, ''), now(), p_created_by)
  returning id into appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;
    v_source := coalesce(nullif(v_allocation ->> 'assignment_source',''),'queue');

    -- Anonymise normal pax under the flag; keep concrete for specific/manual.
    if v_use_anon and v_source in ('queue','gender_preference') then
      v_therapist_id := null; v_room_id := null;
    end if;

    insert into public.appointments (
      appointment_group_id, customer_id, therapist_id, room_id, service_id,
      appointment_date, start_time, end_time, start_at, end_at, status, total_price, type,
      service_name, service_items, item_count, notes, created_at, created_by,
      assignment_source, requested_therapist_id, requested_gender,
      therapist_assignment_state, room_assignment_state)
    values (
      appointment_group_id, p_customer_id, v_therapist_id, v_room_id, v_service_id,
      p_appointment_date, v_start, v_end,
      public.csp_start_at(p_appointment_date, v_start), public.csp_end_at(p_appointment_date, v_start, v_end),
      'confirmed', coalesce((v_allocation ->> 'total_price')::numeric, 0),
      coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
      coalesce(v_allocation ->> 'service_name', ''), coalesce((v_allocation -> 'service_items'), '[]'::jsonb),
      greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1), coalesce(v_allocation ->> 'notes', ''),
      now(), p_created_by, v_source,
      nullif(v_allocation ->> 'requested_therapist_id', '')::uuid, nullif(v_allocation ->> 'requested_gender', ''),
      case when v_use_anon and v_source in ('queue','gender_preference') then 'pending' else 'pending' end,
      case when v_use_anon and v_source in ('queue','gender_preference') then 'pending' else 'pending' end)
    returning id into v_new_appointment_id;
    appointment_ids := array_append(appointment_ids, v_new_appointment_id);
  end loop;

  success := true; error_code := null; error_message := null; return next;
end;
$function$;

-- ---------- update_appointment_with_csp ----------
-- Flag ON + normal source: revalidate with capacity_feasible (excluding self) and
-- store anonymous. Flag OFF or concrete source: UNCHANGED Migration 116 path.
create or replace function public.update_appointment_with_csp(
  p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date,
  p_start_time time without time zone, p_end_time time without time zone,
  p_assignment_source text default null::text, p_requested_therapist_id uuid default null::uuid,
  p_requested_gender text default null::text, p_is_provisional boolean default null::boolean)
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path to 'public'
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

  if v_outlet is not null and public.capacity_first_enabled(v_outlet)
     and v_source in ('queue','gender_preference')
     and v_appt.actual_started_at is null then
    v_start_at := public.csp_start_at(p_date, p_start_time);
    v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);
    perform set_config('lock_timeout','2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_date::text, 0));
    v_feasible := public.capacity_feasible(v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at,'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at))/60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', v_appt.service_id::text, 'room_type', v_room_type,
        'requested_gender', p_requested_gender, 'pax_index', 0)),
      'hard', p_appointment_id);
    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough anonymous capacity for the new time.'; return next; return;
    end if;
    update public.appointments
    set therapist_id = null, room_id = null, room_unit_id = null,
        therapist_assignment_state = 'pending', room_assignment_state = 'pending',
        appointment_date = p_date, start_time = p_start_time, end_time = p_end_time,
        start_at = v_start_at, end_at = v_end_at,
        assignment_source = v_source,
        requested_therapist_id = p_requested_therapist_id, requested_gender = p_requested_gender,
        updated_at = now()
    where id = p_appointment_id returning id into appointment_id;
    success := true; error_code := null; error_message := null; return next; return;
  end if;

  -- UNCHANGED Migration 116 concrete path
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

commit;

-- NOTE: update_appointment_group_with_csp is intentionally left on its Migration
-- 116 concrete definition in this file (group edits are lower-frequency and the
-- group re-anonymisation path adds risk with little rollout value; group create
-- + single-appointment edit cover the tested Phase-6B flows). Add a group-update
-- anonymous branch in a follow-up only if group edits need it under the flag.
