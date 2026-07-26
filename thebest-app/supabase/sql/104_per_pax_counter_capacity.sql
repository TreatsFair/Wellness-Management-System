-- Per-pax capacity and provisional allocation for mixed-service counter bookings.
--
-- Migrations 102/103 accepted one duration and one room type for the entire
-- group. That is incorrect when, for example, Pax 1 books a body massage and
-- Pax 2 books a foot massage. These overloads accept one requirement object
-- per pax:
--
--   [{
--     "pax_index": 1,
--     "service_ids": ["..."],
--     "duration_minutes": 60,
--     "buffer_after_minutes": 0,
--     "room_type": "body_room"
--   }]
--
-- All pax share p_start_time, while their treatment/reserved end and room type
-- remain independent. The legacy signatures remain temporarily available for
-- already-deployed clients; the Flutter capacity flow uses these JSONB
-- overloads exclusively.

create or replace function public.allocate_provisional_slots(
  p_outlet_id uuid,
  p_date date,
  p_start_time time,
  p_requirements jsonb,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  pax_index integer,
  therapist_id uuid,
  room_id uuid,
  end_time time
)
language plpgsql
stable
set search_path to 'public'
as $$
declare
  v_requirement jsonb;
  v_requirement_count integer;
  v_pax_index integer;
  v_duration integer;
  v_buffer integer;
  v_room_type text;
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_treatment_end timestamp;
  v_reserved_end timestamp;
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_dow integer := extract(dow from p_date - 1)::integer;
  v_therapist_id uuid;
  v_room_id uuid;
  v_used_therapists uuid[] := array[]::uuid[];
  v_results jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception using
      errcode = '22023',
      message = 'p_requirements must be a non-empty JSON array.';
  end if;

  v_requirement_count := jsonb_array_length(p_requirements);

  if exists (
    select 1
    from jsonb_array_elements(p_requirements) requirement
    where jsonb_typeof(requirement) is distinct from 'object'
      or coalesce((requirement ->> 'pax_index')::integer, 0) < 1
      or coalesce((requirement ->> 'duration_minutes')::integer, 0) < 1
      or coalesce(nullif(trim(requirement ->> 'room_type'), ''), '') = ''
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every pax requirement needs a positive pax_index, duration_minutes, and room_type.';
  end if;

  if (
    select count(distinct (requirement ->> 'pax_index')::integer)
    from jsonb_array_elements(p_requirements) requirement
  ) <> v_requirement_count then
    raise exception using
      errcode = '22023',
      message = 'Every pax requirement must have a unique pax_index.';
  end if;

  -- Longest reserved windows are allocated first. For a shared start time the
  -- eligible-therapist sets are nested by end time, so this greedy order does
  -- not let a short treatment consume the only therapist who can cover a long
  -- one. Rooms use the same ordering within their independent room types.
  for v_requirement in
    select requirement
    from jsonb_array_elements(p_requirements) requirement
    order by
      coalesce((requirement ->> 'duration_minutes')::integer, 0)
        + greatest(coalesce((requirement ->> 'buffer_after_minutes')::integer, 0), 0) desc,
      (requirement ->> 'pax_index')::integer
  loop
    v_pax_index := (v_requirement ->> 'pax_index')::integer;
    v_duration := (v_requirement ->> 'duration_minutes')::integer;
    v_buffer := greatest(
      coalesce((v_requirement ->> 'buffer_after_minutes')::integer, 0),
      0
    );
    v_room_type := lower(trim(v_requirement ->> 'room_type'));
    v_treatment_end := v_start + make_interval(mins => v_duration);
    v_reserved_end := v_treatment_end + make_interval(mins => v_buffer);

    v_therapist_id := null;
    select therapist.id
    into v_therapist_id
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true) = true
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and not (therapist.id = any(v_used_therapists))
      and exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = therapist.id
          and (
            (
              hours.day_of_week = v_dow
              and p_date + hours.start_time <= v_start
              and p_date + hours.end_time
                + case
                    when hours.end_time <= hours.start_time then interval '1 day'
                    else interval '0'
                  end >= v_reserved_end
            )
            or (
              hours.end_time <= hours.start_time
              and hours.day_of_week = v_prev_dow
              and (p_date - 1) + hours.start_time <= v_start
              and (p_date - 1) + hours.end_time + interval '1 day' >= v_reserved_end
            )
          )
      )
      and not exists (
        select 1
        from public.therapist_unavailability unavailable
        where unavailable.therapist_id = therapist.id
          and (unavailable.starts_at at time zone 'Asia/Kuala_Lumpur') < v_reserved_end
          and (unavailable.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start
      )
      and not exists (
        select 1
        from public.appointments appointment
        where appointment.appointment_date::date between p_date - 1 and p_date + 1
          and appointment.therapist_id = therapist.id
          and public.csp_blocks_schedule(appointment.status::text)
          and public.csp_appointment_start_at(appointment) < v_reserved_end
          and public.csp_appointment_block_end_at(appointment) > v_start
          and (
            p_exclude_appointment_group_id is null
            or appointment.appointment_group_id is distinct from p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1
        from public.booking_holds hold
        where hold.assigned_therapist_id = therapist.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_reserved_end
          and (
            hold.end_at
              + make_interval(
                  mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start
      )
    order by therapist.display_order nulls last, therapist.name, therapist.id
    limit 1;

    if v_therapist_id is null then
      return;
    end if;

    v_room_id := null;
    select room.id
    into v_room_id
    from public.rooms room
    where room.outlet_id = p_outlet_id
      and lower(coalesce(room.room_type::text, '')) = v_room_type
      and (
        (
          select count(*)
          from public.appointments appointment
          where appointment.appointment_date::date between p_date - 1 and p_date + 1
            and appointment.room_id = room.id
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment) < v_reserved_end
            and public.csp_appointment_block_end_at(appointment) > v_start
            and (
              p_exclude_appointment_group_id is null
              or appointment.appointment_group_id is distinct from p_exclude_appointment_group_id
            )
        )
        + (
          select count(*)
          from public.booking_holds hold
          where hold.assigned_room_id = room.id
            and hold.status = 'pending_payment'
            and hold.expires_at > now()
            and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_reserved_end
            and (
              hold.end_at
                + make_interval(
                    mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                  )
            ) at time zone 'Asia/Kuala_Lumpur' > v_start
        )
        + (
          select count(*)
          from jsonb_array_elements(v_results) assigned
          where (assigned ->> 'room_id')::uuid = room.id
        )
      ) < greatest(coalesce(room.total_slots, 1), 1)
    order by room.name, room.id
    limit 1;

    if v_room_id is null then
      return;
    end if;

    v_used_therapists := array_append(v_used_therapists, v_therapist_id);
    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'pax_index', v_pax_index,
        'therapist_id', v_therapist_id,
        'room_id', v_room_id,
        'end_time', v_treatment_end::time
      )
    );
  end loop;

  return query
  select
    (assigned ->> 'pax_index')::integer,
    (assigned ->> 'therapist_id')::uuid,
    (assigned ->> 'room_id')::uuid,
    (assigned ->> 'end_time')::time
  from jsonb_array_elements(v_results) assigned
  order by (assigned ->> 'pax_index')::integer;
end;
$$;

revoke all on function public.allocate_provisional_slots(
  uuid, date, time, jsonb, uuid
) from public, anon;
grant execute on function public.allocate_provisional_slots(
  uuid, date, time, jsonb, uuid
) to authenticated;

create or replace function public.get_counter_capacity_slots(
  p_outlet_id uuid,
  p_date date,
  p_requirements jsonb,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  therapist_free integer,
  room_free integer
)
language plpgsql
stable
set search_path to 'public'
as $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_is_closed boolean := false;
  v_hours_found boolean := false;
  v_open_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_start timestamp;
  v_requirement_count integer;
  v_max_duration integer;
  v_max_reserved_minutes integer;
  v_allocated integer;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception using
      errcode = '22023',
      message = 'p_requirements must be a non-empty JSON array.';
  end if;

  v_requirement_count := jsonb_array_length(p_requirements);

  if exists (
    select 1
    from jsonb_array_elements(p_requirements) requirement
    where jsonb_typeof(requirement) is distinct from 'object'
      or coalesce((requirement ->> 'pax_index')::integer, 0) < 1
      or coalesce((requirement ->> 'duration_minutes')::integer, 0) < 1
      or coalesce(nullif(trim(requirement ->> 'room_type'), ''), '') = ''
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every pax requirement needs a positive pax_index, duration_minutes, and room_type.';
  end if;

  select
    max((requirement ->> 'duration_minutes')::integer),
    max(
      (requirement ->> 'duration_minutes')::integer
        + greatest(
            coalesce((requirement ->> 'buffer_after_minutes')::integer, 0),
            0
          )
    )
  into v_max_duration, v_max_reserved_minutes
  from jsonb_array_elements(p_requirements) requirement;

  select hours.open_time, hours.close_time, hours.is_closed, true
  into v_open, v_close, v_is_closed, v_hours_found
  from public.business_hours hours
  where hours.outlet_id = p_outlet_id
    and hours.day_of_week = extract(dow from p_date)::integer
  limit 1;

  if not coalesce(v_hours_found, false) then
    select
      coalesce(settings.open_time, '09:00'::time),
      coalesce(settings.close_time, '21:00'::time)
    into v_open, v_close
    from public.business_settings settings
    where settings.outlet_id = p_outlet_id
    limit 1;
  end if;

  if coalesce(v_is_closed, false) then
    return;
  end if;

  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);
  v_open_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  for v_start in
    select candidate
    from generate_series(
      v_open_at,
      v_close_at - make_interval(mins => v_max_reserved_minutes),
      interval '30 minutes'
    ) candidate
  loop
    if v_start <= v_now_local then
      continue;
    end if;

    select count(*)
    into v_allocated
    from public.allocate_provisional_slots(
      p_outlet_id,
      p_date,
      v_start::time,
      p_requirements,
      p_exclude_appointment_group_id
    );

    if v_allocated <> v_requirement_count then
      continue;
    end if;

    start_time := v_start::time;
    end_time := (v_start + make_interval(mins => v_max_duration))::time;
    -- These columns remain for the existing result model. With heterogeneous
    -- windows/types, the meaningful guarantee is that every requirement was
    -- matched, so report the matched pax count rather than one shared pool.
    therapist_free := v_allocated;
    room_free := v_allocated;
    return next;
  end loop;
end;
$$;

revoke all on function public.get_counter_capacity_slots(
  uuid, date, jsonb, uuid
) from public, anon;
grant execute on function public.get_counter_capacity_slots(
  uuid, date, jsonb, uuid
) to authenticated;
