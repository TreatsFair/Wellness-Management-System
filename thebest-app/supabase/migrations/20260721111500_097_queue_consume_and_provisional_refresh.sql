-- Consume/rotate the daily therapist queue only when a service actually
-- starts, detect protected turns for specific-request therapists skipped
-- while busy, and auto-refresh still-provisional future appointments to the
-- live recommended therapist right up until check-in/start.

-- 1. start_appointment_service: same signature, body extended with queue
--    rotation. This is the single place a turn is ever consumed -- never at
--    booking, check-in draft, or no-show.
create or replace function public.start_appointment_service(
  p_appointment_id uuid,
  p_started_at timestamptz default now()
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_duration interval;
  v_expected_end timestamptz;
  v_updated public.appointments%rowtype;
  v_this_position integer;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  if v_appointment.appointment_date <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service can only be started on its appointment date.';
  end if;
  if v_appointment.status not in ('pending', 'confirmed') then
    raise exception 'Only a pending or confirmed service can be started.';
  end if;
  if v_appointment.payment_status <> 'paid' then
    raise exception 'Payment must be confirmed before starting this service.';
  end if;
  if v_appointment.actual_started_at is not null then
    raise exception 'This service has already started.';
  end if;

  v_duration := coalesce(
    v_appointment.booked_end_at - v_appointment.booked_start_at,
    public.csp_end_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time),
      coalesce(v_appointment.booked_end_time, v_appointment.end_time)
    ) - public.csp_start_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time)
    ),
    v_appointment.end_at - v_appointment.start_at
  );
  if v_duration is null or v_duration <= interval '0 seconds' then
    raise exception 'Service duration must be greater than zero.';
  end if;

  v_expected_end := p_started_at + v_duration;
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  update public.appointments
  set booked_date = coalesce(booked_date, appointment_date),
      booked_start_time = coalesce(booked_start_time, start_time),
      booked_end_time = coalesce(booked_end_time, end_time),
      booked_start_at = coalesce(
        booked_start_at,
        public.csp_start_at(appointment_date, start_time) at time zone 'Asia/Kuala_Lumpur'
      ),
      booked_end_at = coalesce(
        booked_end_at,
        public.csp_end_at(appointment_date, start_time, end_time) at time zone 'Asia/Kuala_Lumpur'
      ),
      status = 'in_progress',
      actual_started_at = p_started_at,
      end_at = v_expected_end at time zone 'Asia/Kuala_Lumpur',
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  -- Queue rotation. Only bookable service types participate; therapist_id
  -- is always populated by the time a service can start.
  if v_updated.therapist_id is not null then
    perform public.seed_therapist_queue(v_updated.outlet_id, v_updated.appointment_date);

    select queue_position into v_this_position
    from public.therapist_queue
    where outlet_id = v_updated.outlet_id
      and queue_date = v_updated.appointment_date
      and therapist_id = v_updated.therapist_id;

    if v_this_position is not null then
      -- Anyone still ahead of this therapist (not yet consumed today) who is
      -- currently mid-service on a specific customer request had their
      -- normal turn skipped by this start -- flag it so get_therapist_queue
      -- resurfaces them at the front the moment they free up.
      update public.therapist_queue tq
      set protected_turn_owed = true,
          protected_turn_reason = 'busy_specific_request'
      where tq.outlet_id = v_updated.outlet_id
        and tq.queue_date = v_updated.appointment_date
        and tq.turn_consumed_at is null
        and tq.queue_position < v_this_position
        and exists (
          select 1 from public.appointments busy
          where busy.therapist_id = tq.therapist_id
            and busy.status = 'in_progress'
            and busy.assignment_source = 'specific_customer_request'
            and busy.id <> v_updated.id
        );

      update public.therapist_queue
      set turn_consumed_at = p_started_at,
          protected_turn_owed = false,
          protected_turn_reason = null
      where outlet_id = v_updated.outlet_id
        and queue_date = v_updated.appointment_date
        and therapist_id = v_updated.therapist_id;
    end if;
  end if;

  return v_updated;
end;
$$;

revoke all on function public.start_appointment_service(uuid, timestamptz) from public;
grant execute on function public.start_appointment_service(uuid, timestamptz) to authenticated;

-- 2. Auto-replace still-provisional future appointments with whoever the
--    live queue currently recommends. Only touches rows nobody has locked
--    yet (is_provisional = true) -- a specific request or a manual override
--    already cleared that flag via switch_appointment_therapist, so this
--    never overwrites a staff decision. Mirrors the client-side maintenance
--    pattern used by complete_due_appointments / mark_past_appointments_no_show
--    (called periodically from the app, not a DB-side cron job).
create or replace function public.refresh_provisional_therapist_assignments(
  p_outlet_id uuid default null,
  p_date date default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Kuala_Lumpur')::date);
  v_row public.appointments%rowtype;
  v_duration_minutes integer;
  v_recommended uuid;
  v_check record;
  v_switch record;
  v_updated integer := 0;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  for v_row in
    select a.*
    from public.appointments a
    where a.is_provisional = true
      and a.status in ('pending', 'confirmed')
      and a.appointment_date = v_date
      and a.therapist_id is not null
      and (p_outlet_id is null or a.outlet_id = p_outlet_id)
    order by a.start_time
    for update of a skip locked
  loop
    v_duration_minutes := greatest(
      (extract(epoch from (
        public.csp_end_at(v_row.appointment_date, v_row.start_time, v_row.end_time)
        - public.csp_start_at(v_row.appointment_date, v_row.start_time)
      )) / 60)::integer,
      1
    );

    select q.therapist_id into v_recommended
    from public.get_therapist_queue(
      v_row.outlet_id, v_date, v_row.start_time, v_duration_minutes
    ) q
    where q.status = 'free_now'
      and (v_row.requested_gender is null or q.gender = v_row.requested_gender)
    order by q.rotation_rank
    limit 1;

    if v_recommended is null or v_recommended = v_row.therapist_id then
      continue;
    end if;

    select * into v_check
    from public.check_booking_availability(
      v_row.appointment_date, v_row.start_time, v_row.end_time,
      v_recommended, v_row.room_id, v_row.id
    );
    if not coalesce(v_check.therapist_available, false) then
      continue;
    end if;

    select * into v_switch
    from public.switch_appointment_therapist(
      p_appointment_id => v_row.id,
      p_new_therapist_id => v_recommended,
      p_split_method => 'service_time',
      p_reason => 'Automatic queue refresh before appointment',
      p_assignment_source => case
        when v_row.requested_gender is not null then 'gender_preference'
        else 'queue'
      end,
      p_requested_gender => v_row.requested_gender,
      p_keep_provisional => true
    );
    if coalesce(v_switch.success, false) then
      v_updated := v_updated + 1;
    end if;
  end loop;

  return v_updated;
end;
$$;

revoke all on function public.refresh_provisional_therapist_assignments(uuid, date)
  from public, anon;
grant execute on function public.refresh_provisional_therapist_assignments(uuid, date)
  to authenticated;

-- 3. create_appointment_with_csp: add assignment provenance columns. Old
--    15-arg signature is dropped first so PostgREST resolves to exactly one
--    overload (see 095's note on switch_appointment_therapist).
drop function if exists public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, uuid, text, jsonb, integer, text, uuid
);

create or replace function public.create_appointment_with_csp(
  p_customer_id uuid,
  p_therapist_id uuid,
  p_room_id uuid,
  p_service_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_total_price numeric,
  p_type text default 'appointment',
  p_created_by uuid default auth.uid(),
  p_service_name text default '',
  p_service_items jsonb default '[]'::jsonb,
  p_item_count integer default 1,
  p_notes text default '',
  p_appointment_group_id uuid default null,
  p_assignment_source text default 'queue',
  p_requested_therapist_id uuid default null,
  p_requested_gender text default null,
  p_is_provisional boolean default false
)
returns table (
  success boolean,
  appointment_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check record;
  v_start_at timestamp;
  v_end_at timestamp;
begin
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false;
    appointment_id := null;
    error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.';
    return next;
    return;
  end if;

  v_start_at := public.csp_start_at(p_date, p_start_time);
  v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);

  select *
  into v_check
  from public.check_booking_availability(
    p_date,
    p_start_time,
    p_end_time,
    p_therapist_id,
    p_room_id
  );

  if not coalesce(v_check.therapist_available, false) then
    success := false;
    appointment_id := null;
    error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.';
    return next;
    return;
  end if;

  if coalesce(v_check.room_full, false) then
    success := false;
    appointment_id := null;
    error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.';
    return next;
    return;
  end if;

  insert into public.appointments (
    appointment_group_id,
    customer_id,
    therapist_id,
    room_id,
    service_id,
    appointment_date,
    start_time,
    end_time,
    start_at,
    end_at,
    status,
    total_price,
    type,
    service_name,
    service_items,
    item_count,
    notes,
    created_at,
    created_by,
    assignment_source,
    requested_therapist_id,
    requested_gender,
    is_provisional
  )
  values (
    p_appointment_group_id,
    p_customer_id,
    p_therapist_id,
    p_room_id,
    p_service_id,
    p_date,
    p_start_time,
    p_end_time,
    v_start_at,
    v_end_at,
    'confirmed',
    p_total_price,
    coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
    coalesce(p_service_name, ''),
    coalesce(p_service_items, '[]'::jsonb),
    greatest(coalesce(p_item_count, 1), 1),
    coalesce(p_notes, ''),
    now(),
    p_created_by,
    coalesce(nullif(p_assignment_source, ''), 'queue'),
    p_requested_therapist_id,
    p_requested_gender,
    coalesce(p_is_provisional, false)
  )
  returning id into appointment_id;

  success := true;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

revoke all on function public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, uuid, text, jsonb, integer, text, uuid,
  text, uuid, text, boolean
) from public, anon;
grant execute on function public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, uuid, text, jsonb, integer, text, uuid,
  text, uuid, text, boolean
) to authenticated;

-- 4. update_appointment_with_csp: same treatment. Null on the new params
--    means "leave the existing assignment metadata untouched" -- this RPC is
--    also used for pure date/time/room edits that shouldn't silently reset
--    who requested what.
drop function if exists public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time, time
);

create or replace function public.update_appointment_with_csp(
  p_appointment_id uuid,
  p_therapist_id uuid,
  p_room_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_assignment_source text default null,
  p_requested_therapist_id uuid default null,
  p_requested_gender text default null,
  p_is_provisional boolean default null
)
returns table (
  success boolean,
  appointment_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check record;
begin
  if not exists (select 1 from public.appointments a where a.id = p_appointment_id) then
    success := false;
    appointment_id := null;
    error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.';
    return next;
    return;
  end if;

  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false;
    appointment_id := null;
    error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.';
    return next;
    return;
  end if;

  select *
  into v_check
  from public.check_booking_availability(
    p_date,
    p_start_time,
    p_end_time,
    p_therapist_id,
    p_room_id,
    p_appointment_id
  );

  if not coalesce(v_check.therapist_available, false) then
    success := false;
    appointment_id := null;
    error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.';
    return next;
    return;
  end if;

  if coalesce(v_check.room_full, false) then
    success := false;
    appointment_id := null;
    error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.';
    return next;
    return;
  end if;

  update public.appointments
  set therapist_id = p_therapist_id,
      room_id = p_room_id,
      appointment_date = p_date,
      start_time = p_start_time,
      end_time = p_end_time,
      start_at = public.csp_start_at(p_date, p_start_time),
      end_at = public.csp_end_at(p_date, p_start_time, p_end_time),
      assignment_source = coalesce(p_assignment_source, assignment_source),
      requested_therapist_id = case
        when p_assignment_source is not null then p_requested_therapist_id
        else requested_therapist_id
      end,
      requested_gender = case
        when p_assignment_source is not null then p_requested_gender
        else requested_gender
      end,
      is_provisional = coalesce(p_is_provisional, is_provisional),
      updated_at = now()
  where id = p_appointment_id
  returning id into appointment_id;

  success := true;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

revoke all on function public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time, time, text, uuid, text, boolean
) from public, anon;
grant execute on function public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time, time, text, uuid, text, boolean
) to authenticated;

-- 5. Group create/update: unchanged positional signature (no drop needed) --
--    per-pax assignment fields ride along inside each allocation's jsonb
--    object, same as therapist_id/room_id/service_id already do.
create or replace function public.create_appointment_group_with_csp(
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_type text default 'appointment',
  p_status text default 'confirmed',
  p_notes text default '',
  p_created_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allocation jsonb;
  v_new_appointment_id uuid;
  v_check record;
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_start time;
  v_end time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_group_conflicts integer;
  v_group_room_slots integer;
begin
  appointment_ids := array[]::uuid[];

  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) = 0 then
    success := false;
    appointment_group_id := null;
    error_code := 'INVALID_ALLOCATIONS';
    error_message := 'Group booking requires at least one pax allocation.';
    return next;
    return;
  end if;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_start is null or v_end is null or v_end = v_start then
      success := false;
      appointment_group_id := null;
      error_code := 'INVALID_DURATION';
      error_message := 'One pax allocation has an invalid time range.';
      return next;
      return;
    end if;

    v_start_at := public.csp_start_at(p_appointment_date, v_start);
    v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);

    select *
    into v_check
    from public.check_booking_availability(
      p_appointment_date,
      v_start,
      v_end,
      v_therapist_id,
      v_room_id
    );

    if not coalesce(v_check.therapist_available, false) then
      success := false;
      appointment_group_id := null;
      error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'One pax allocation has a staff conflict.';
      return next;
      return;
    end if;

    select count(*)
    into v_group_conflicts
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'therapist_id')::uuid = v_therapist_id
      and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if v_group_conflicts > 1 then
      success := false;
      appointment_group_id := null;
      error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'The same staff cannot serve overlapping pax in one group.';
      return next;
      return;
    end if;

    select count(*)
    into v_group_room_slots
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'room_id')::uuid = v_room_id
      and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots > coalesce(v_check.room_total_slots, 1) then
      success := false;
      appointment_group_id := null;
      error_code := 'ROOM_FULL';
      error_message := 'A room or zone does not have enough slots for this group.';
      return next;
      return;
    end if;
  end loop;

  insert into public.appointment_groups (
    customer_id,
    group_name,
    pax_count,
    appointment_date,
    status,
    notes,
    created_at,
    created_by
  )
  values (
    p_customer_id,
    coalesce(p_group_name, ''),
    greatest(coalesce(p_pax_count, jsonb_array_length(p_allocations)), 1),
    p_appointment_date,
    coalesce(nullif(p_status, ''), 'confirmed'),
    coalesce(p_notes, ''),
    now(),
    p_created_by
  )
  returning id into appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    insert into public.appointments (
      appointment_group_id,
      customer_id,
      therapist_id,
      room_id,
      service_id,
      appointment_date,
      start_time,
      end_time,
      start_at,
      end_at,
      status,
      total_price,
      type,
      service_name,
      service_items,
      item_count,
      notes,
      created_at,
      created_by,
      assignment_source,
      requested_therapist_id,
      requested_gender,
      is_provisional
    )
    values (
      appointment_group_id,
      p_customer_id,
      v_therapist_id,
      v_room_id,
      v_service_id,
      p_appointment_date,
      v_start,
      v_end,
      public.csp_start_at(p_appointment_date, v_start),
      public.csp_end_at(p_appointment_date, v_start, v_end),
      'confirmed',
      coalesce((v_allocation ->> 'total_price')::numeric, 0),
      coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
      coalesce(v_allocation ->> 'service_name', ''),
      coalesce((v_allocation -> 'service_items'), '[]'::jsonb),
      greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
      coalesce(v_allocation ->> 'notes', ''),
      now(),
      p_created_by,
      coalesce(nullif(v_allocation ->> 'assignment_source', ''), 'queue'),
      nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
      nullif(v_allocation ->> 'requested_gender', ''),
      coalesce((v_allocation ->> 'is_provisional')::boolean, false)
    )
    returning id into v_new_appointment_id;

    appointment_ids := array_append(appointment_ids, v_new_appointment_id);
  end loop;

  success := true;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

create or replace function public.update_appointment_group_with_csp(
  p_appointment_group_id uuid,
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_type text default 'appointment',
  p_status text default 'confirmed',
  p_notes text default '',
  p_updated_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allocation jsonb;
  v_existing_id uuid;
  v_saved_id uuid;
  v_check record;
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_start time;
  v_end time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_group_conflicts integer;
  v_group_room_slots integer;
  v_existing_count integer;
  v_group_paid boolean;
begin
  appointment_ids := array[]::uuid[];
  appointment_group_id := p_appointment_group_id;

  if not exists (
    select 1 from public.appointment_groups g
    where g.id = p_appointment_group_id
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'NOT_FOUND', 'Appointment group was not found.';
    return;
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
      or jsonb_array_length(p_allocations) = 0 then
    return query select false, p_appointment_group_id, appointment_ids,
      'INVALID_ALLOCATIONS', 'Group booking requires at least one pax allocation.';
    return;
  end if;

  select count(*) into v_existing_count
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;

  select exists (
    select 1 from public.transactions t
    where t.appointment_group_id = p_appointment_group_id
      and t.payment_status = 'paid'
      and coalesce(t.source, '') <> 'appointment_addon'
  ) or exists (
    select 1 from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and a.payment_status = 'paid'
  ) into v_group_paid;

  if (
    select count(*) <> count(distinct nullif(value ->> 'appointment_id', ''))
    from jsonb_array_elements(p_allocations)
    where nullif(value ->> 'appointment_id', '') is not null
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'DUPLICATE_APPOINTMENT', 'Each pax allocation must reference a different appointment.';
    return;
  end if;

  if v_group_paid and (
    jsonb_array_length(p_allocations) <> v_existing_count
    or exists (
      select 1 from jsonb_array_elements(p_allocations) item
      where nullif(item.value ->> 'appointment_id', '') is null
    )
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'PAID_GROUP_LOCKED', 'Paid group pax cannot be added or removed.';
    return;
  end if;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_existing_id is not null and not exists (
      select 1 from public.appointments a
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id
    ) then
      return query select false, p_appointment_group_id, appointment_ids,
        'INVALID_APPOINTMENT', 'A pax allocation does not belong to this group.';
      return;
    end if;

    if v_start is null or v_end is null or v_end = v_start then
      return query select false, p_appointment_group_id, appointment_ids,
        'INVALID_DURATION', 'One pax allocation has an invalid time range.';
      return;
    end if;

    v_start_at := public.csp_start_at(p_appointment_date, v_start);
    v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);

    select * into v_check
    from public.check_booking_availability(
      p_appointment_date, v_start, v_end, v_therapist_id, v_room_id,
      v_existing_id, p_appointment_group_id
    );

    if not coalesce(v_check.therapist_available, false) then
      return query select false, p_appointment_group_id, appointment_ids,
        'THERAPIST_UNAVAILABLE', 'One pax allocation has a staff conflict.';
      return;
    end if;

    select count(*) into v_group_conflicts
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'therapist_id')::uuid = v_therapist_id
      and public.csp_start_at(
        p_appointment_date, (other.value ->> 'start_time')::time
      ) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if v_group_conflicts > 1 then
      return query select false, p_appointment_group_id, appointment_ids,
        'THERAPIST_UNAVAILABLE',
        'The same staff cannot serve overlapping pax in one group.';
      return;
    end if;

    select count(*) into v_group_room_slots
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'room_id')::uuid = v_room_id
      and public.csp_start_at(
        p_appointment_date, (other.value ->> 'start_time')::time
      ) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots
        > coalesce(v_check.room_total_slots, 1) then
      return query select false, p_appointment_group_id, appointment_ids,
        'ROOM_FULL', 'A room or zone does not have enough slots for this group.';
      return;
    end if;
  end loop;

  update public.appointment_groups
  set customer_id = p_customer_id,
      group_name = coalesce(p_group_name, ''),
      pax_count = jsonb_array_length(p_allocations),
      appointment_date = p_appointment_date,
      status = coalesce(nullif(p_status, ''), 'confirmed'),
      notes = coalesce(p_notes, '')
  where id = p_appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_existing_id is not null then
      update public.appointments a
      set customer_id = p_customer_id,
          therapist_id = v_therapist_id,
          room_id = v_room_id,
          service_id = v_service_id,
          appointment_date = p_appointment_date,
          start_time = v_start,
          end_time = v_end,
          start_at = public.csp_start_at(p_appointment_date, v_start),
          end_at = public.csp_end_at(p_appointment_date, v_start, v_end),
          booked_date = case when a.actual_started_at is null
            then p_appointment_date else a.booked_date end,
          booked_start_time = case when a.actual_started_at is null
            then v_start else a.booked_start_time end,
          booked_end_time = case when a.actual_started_at is null
            then v_end else a.booked_end_time end,
          booked_start_at = case when a.actual_started_at is null
            then public.csp_start_at(p_appointment_date, v_start)
              at time zone 'Asia/Kuala_Lumpur'
            else a.booked_start_at end,
          booked_end_at = case when a.actual_started_at is null
            then public.csp_end_at(p_appointment_date, v_start, v_end)
              at time zone 'Asia/Kuala_Lumpur'
            else a.booked_end_at end,
          total_price = coalesce((v_allocation ->> 'total_price')::numeric, 0),
          type = coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
          service_name = coalesce(v_allocation ->> 'service_name', ''),
          service_items = coalesce(v_allocation -> 'service_items', '[]'::jsonb),
          item_count = greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
          notes = coalesce(v_allocation ->> 'notes', ''),
          assignment_source = coalesce(
            nullif(v_allocation ->> 'assignment_source', ''), a.assignment_source
          ),
          requested_therapist_id = nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
          requested_gender = nullif(v_allocation ->> 'requested_gender', ''),
          is_provisional = coalesce(
            (v_allocation ->> 'is_provisional')::boolean, a.is_provisional
          ),
          updated_at = now(),
          updated_by = p_updated_by
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id
      returning a.id into v_saved_id;
    else
      insert into public.appointments (
        appointment_group_id, customer_id, therapist_id, room_id, service_id,
        appointment_date, start_time, end_time, start_at, end_at,
        booked_date, booked_start_time, booked_end_time,
        booked_start_at, booked_end_at,
        status, total_price, type, service_name, service_items, item_count,
        notes, created_at, created_by,
        assignment_source, requested_therapist_id, requested_gender, is_provisional
      ) values (
        p_appointment_group_id, p_customer_id, v_therapist_id, v_room_id,
        v_service_id, p_appointment_date, v_start, v_end,
        public.csp_start_at(p_appointment_date, v_start),
        public.csp_end_at(p_appointment_date, v_start, v_end),
        p_appointment_date, v_start, v_end,
        public.csp_start_at(p_appointment_date, v_start)
          at time zone 'Asia/Kuala_Lumpur',
        public.csp_end_at(p_appointment_date, v_start, v_end)
          at time zone 'Asia/Kuala_Lumpur',
        'confirmed', coalesce((v_allocation ->> 'total_price')::numeric, 0),
        coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
        coalesce(v_allocation ->> 'service_name', ''),
        coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
        coalesce(v_allocation ->> 'notes', ''), now(), p_updated_by,
        coalesce(nullif(v_allocation ->> 'assignment_source', ''), 'queue'),
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        nullif(v_allocation ->> 'requested_gender', ''),
        coalesce((v_allocation ->> 'is_provisional')::boolean, false)
      ) returning id into v_saved_id;
    end if;

    appointment_ids := array_append(appointment_ids, v_saved_id);
  end loop;

  if not v_group_paid then
    delete from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and not (a.id = any(appointment_ids));
  end if;

  return query select true, p_appointment_group_id, appointment_ids,
    null::text, null::text;
end;
$$;
