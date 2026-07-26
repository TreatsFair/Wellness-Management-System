-- Phase 6B.1 follow-up (pre-123): preference-aware counter capacity preview
-- and provisional allocation. LOCAL ONLY; not applied.

create or replace function public.get_counter_preference_capacity_slots(
  p_outlet_id uuid,
  p_date date,
  p_requirements jsonb,
  p_exclude_appointment_group_id uuid default null,
  p_exclude_appointment_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  therapist_free integer,
  room_free integer,
  is_available boolean,
  unavailable_dimension text,
  unavailable_at timestamp,
  conflict_therapist_id uuid,
  conflict_start time,
  conflict_end time
)
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_open time := '09:00';
  v_close time := '21:00';
  v_closed boolean := false;
  v_start timestamp;
  v_close_at timestamp;
  v_max_duration integer;
  v_max_reserved integer;
  v_demands jsonb;
  v_verdict jsonb;
  v_specific uuid;
  v_allocated integer;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception 'Every pax needs a capacity requirement.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_requirements) r
    where coalesce((r ->> 'duration_minutes')::integer, 0) <= 0
      or nullif(r ->> 'room_type', '') is null
      or coalesce(r ->> 'assignment_source', 'queue') not in (
        'queue', 'gender_preference', 'specific_customer_request'
      )
      or (
        r ->> 'assignment_source' = 'gender_preference'
        and nullif(r ->> 'requested_gender', '') is null
      )
      or (
        r ->> 'assignment_source' = 'specific_customer_request'
        and nullif(r ->> 'requested_therapist_id', '') is null
      )
  ) then
    raise exception 'One or more therapist preferences is incomplete.';
  end if;
  if (
    select count(distinct r ->> 'requested_therapist_id')
    from jsonb_array_elements(p_requirements) r
    where r ->> 'assignment_source' = 'specific_customer_request'
  ) <> (
    select count(*)
    from jsonb_array_elements(p_requirements) r
    where r ->> 'assignment_source' = 'specific_customer_request'
  ) then
    raise exception 'The same therapist cannot be requested for simultaneous pax.';
  end if;

  select h.open_time, h.close_time, h.is_closed
  into v_open, v_close, v_closed
  from public.business_hours h
  where h.outlet_id = p_outlet_id
    and h.day_of_week = extract(dow from p_date)::integer
  limit 1;
  if coalesce(v_closed, false) then return; end if;
  v_open := coalesce(v_open, '09:00');
  v_close := coalesce(v_close, '21:00');
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select max((r ->> 'duration_minutes')::integer),
    max((r ->> 'duration_minutes')::integer
      + greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0))
  into v_max_duration, v_max_reserved
  from jsonb_array_elements(p_requirements) r;

  for v_start in
    select candidate from generate_series(
      p_date + v_open,
      v_close_at - make_interval(mins => v_max_reserved),
      interval '30 minutes'
    ) candidate
  loop
    if v_start <= now() at time zone 'Asia/Kuala_Lumpur' then continue; end if;
    select jsonb_agg(
      jsonb_build_object(
        'start', v_start,
        'duration_minutes', (r ->> 'duration_minutes')::integer,
        'buffer_after_minutes',
          greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0),
        'service_id', r -> 'service_ids' ->> 0,
        'room_type', r ->> 'room_type',
        'requested_gender', case
          when r ->> 'assignment_source' = 'gender_preference'
            then r ->> 'requested_gender'
          else null
        end,
        'requested_therapist_id', case
          when r ->> 'assignment_source' = 'specific_customer_request'
            then r ->> 'requested_therapist_id'
          else null
        end,
        'manual_lock_id', null,
        'pax_index', r ->> 'pax_index'
      )
    )
    into v_demands
    from jsonb_array_elements(p_requirements) r;

    v_verdict := public.capacity_feasible(
      p_outlet_id, v_demands, 'soft', p_exclude_appointment_id,
      p_exclude_appointment_group_id
    );
    if coalesce((v_verdict ->> 'feasible')::boolean, false)
       and jsonb_array_length(p_requirements) > 1 then
      select count(*)
      into v_allocated
      from public.allocate_preference_provisional_slots(
        p_outlet_id, p_date, v_start::time, p_requirements,
        p_exclude_appointment_group_id
      );
      if v_allocated <> jsonb_array_length(p_requirements) then
        v_verdict := jsonb_build_object(
          'feasible', false,
          'dimension', 'therapist',
          'at', v_start
        );
      end if;
    end if;
    start_time := v_start::time;
    end_time := (
      v_start + make_interval(mins => v_max_duration)
    )::time;
    is_available := coalesce((v_verdict ->> 'feasible')::boolean, false);
    therapist_free := case when is_available
      then jsonb_array_length(p_requirements) else 0 end;
    room_free := therapist_free;
    unavailable_dimension := v_verdict ->> 'dimension';
    unavailable_at := nullif(v_verdict ->> 'at', '')::timestamp;
    conflict_start := null;
    conflict_end := null;
    conflict_therapist_id := null;

    if not is_available and unavailable_dimension = 'therapist' then
      select nullif(r ->> 'requested_therapist_id', '')::uuid
      into v_specific
      from jsonb_array_elements(p_requirements) r
      where r ->> 'assignment_source' = 'specific_customer_request'
      limit 1;
      if v_specific is not null then
        conflict_therapist_id := v_specific;
        select public.csp_appointment_start_at(a)::time,
          public.csp_appointment_block_end_at(a)::time
        into conflict_start, conflict_end
        from public.appointments a
        where a.therapist_id = v_specific
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a)
              < v_start + make_interval(mins => v_max_reserved)
          and public.csp_appointment_block_end_at(a) > v_start
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from
              p_exclude_appointment_group_id
          )
          and a.id is distinct from p_exclude_appointment_id
        order by public.csp_appointment_start_at(a)
        limit 1;
      end if;
    end if;
    return next;
  end loop;
end;
$function$;

revoke all on function public.get_counter_preference_capacity_slots(
  uuid, date, jsonb, uuid, uuid
) from public, anon;
grant execute on function public.get_counter_preference_capacity_slots(
  uuid, date, jsonb, uuid, uuid
) to authenticated;

create or replace function public.allocate_preference_provisional_slots(
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
security definer
set search_path = public
as $function$
declare
  v_base jsonb := '{}'::jsonb;
  v_row record;
  v_requirement jsonb;
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_reserved_end timestamp;
  v_used uuid[] := array[]::uuid[];
  v_selected uuid;
begin
  -- Reuse the established allocator for typed room capacity. Its complete
  -- result also proves that a distinct-room allocation exists.
  for v_row in
    select * from public.allocate_provisional_slots(
      p_outlet_id, p_date, p_start_time, p_requirements,
      p_exclude_appointment_group_id
    )
  loop
    v_base := v_base || jsonb_build_object(
      v_row.pax_index::text,
      jsonb_build_object(
        'room_id', v_row.room_id,
        'end_time', v_row.end_time
      )
    );
  end loop;
  if (select count(*) from jsonb_object_keys(v_base))
       <> jsonb_array_length(p_requirements) then
    return;
  end if;

  for v_requirement in
    select r from jsonb_array_elements(p_requirements) r
    order by
      case r ->> 'assignment_source'
        when 'specific_customer_request' then 0
        when 'gender_preference' then 1
        else 2
      end,
      (r ->> 'duration_minutes')::integer
        + greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0)
        desc,
      (r ->> 'pax_index')::integer
  loop
    pax_index := (v_requirement ->> 'pax_index')::integer;
    v_reserved_end := v_start + make_interval(
      mins => (v_requirement ->> 'duration_minutes')::integer
        + greatest(
          coalesce((v_requirement ->> 'buffer_after_minutes')::integer,
          0), 0
        )
    );
    select t.id
    into v_selected
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
      and not (t.id = any(v_used))
      and (
        coalesce(v_requirement ->> 'assignment_source', 'queue')
          <> 'specific_customer_request'
        or t.id = (v_requirement ->> 'requested_therapist_id')::uuid
      )
      and (
        coalesce(v_requirement ->> 'assignment_source', 'queue')
          <> 'gender_preference'
        or lower(t.gender) = lower(v_requirement ->> 'requested_gender')
      )
      and not exists (
        select 1
        from jsonb_array_elements_text(
          coalesce(v_requirement -> 'service_ids', '[]'::jsonb)
        ) service_id(value)
        where coalesce(t.service_commissions, '{}'::jsonb) <> '{}'::jsonb
          and not (t.service_commissions ? service_id.value)
      )
      and exists (
        select 1 from public.therapist_working_hours h
        where h.therapist_id = t.id
          and (
            (
              h.day_of_week = extract(dow from p_date)::integer
              and p_date + h.start_time <= v_start
              and p_date + h.end_time
                + case when h.end_time <= h.start_time
                    then interval '1 day' else interval '0' end
                >= v_reserved_end
            )
            or (
              h.end_time <= h.start_time
              and h.day_of_week =
                extract(dow from p_date - 1)::integer
              and (p_date - 1) + h.start_time <= v_start
              and (p_date - 1) + h.end_time + interval '1 day'
                >= v_reserved_end
            )
          )
      )
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = t.id
          and u.starts_at at time zone 'Asia/Kuala_Lumpur' < v_reserved_end
          and u.ends_at at time zone 'Asia/Kuala_Lumpur' > v_start
      )
      and not exists (
        select 1 from public.appointments a
        where a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_reserved_end
          and public.csp_appointment_block_end_at(a) > v_start
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from
              p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1 from public.booking_holds h
        where h.assigned_therapist_id = t.id
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
          and h.start_at at time zone 'Asia/Kuala_Lumpur' < v_reserved_end
          and (
            h.end_at + make_interval(
              mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
            )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start
      )
    order by t.display_order nulls last, t.name, t.id
    limit 1;
    if v_selected is null then return; end if;
    v_used := array_append(v_used, v_selected);
    therapist_id := v_selected;
    room_id := nullif(v_base -> pax_index::text ->> 'room_id', '')::uuid;
    end_time := nullif(v_base -> pax_index::text ->> 'end_time', '')::time;
    return next;
  end loop;
end;
$function$;

revoke all on function public.allocate_preference_provisional_slots(
  uuid, date, time, jsonb, uuid
) from public, anon;
grant execute on function public.allocate_preference_provisional_slots(
  uuid, date, time, jsonb, uuid
) to authenticated;
