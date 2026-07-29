-- 129: hour-aligned standard capacity candidates.
-- The plain (non Best Fit) grid was generated from the outlet's opening
-- time, so an outlet opening at 10:30 offered 11:30 / 12:30 / 13:30 ....
-- Counter staff book on the hour, so the grid is now anchored to the clock
-- hour; the opening time is kept as an extra candidate when it does not
-- fall on the hour so the first bookable minutes of the day survive.
-- Best Fit candidates (packed against real bookings/holds) are unchanged.

begin;

create or replace function public.get_counter_preference_capacity_slots_v2(
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
  conflict_end time,
  candidate_kind text
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
  v_close_at timestamp;
  v_max_duration integer;
  v_max_reserved integer;
  v_candidate record;
  v_start timestamp;
  v_demands jsonb;
  v_verdict jsonb;
  v_specific uuid;
  v_allocated integer;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception using errcode = '42501', message = 'Staff access required.';
  end if;
  perform public.validate_one_based_capacity_requirements_122s(p_requirements);
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception 'Every pax needs a capacity requirement.';
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

  select
    max((r ->> 'duration_minutes')::integer),
    max(
      (r ->> 'duration_minutes')::integer
      + greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0)
    )
  into v_max_duration, v_max_reserved
  from jsonb_array_elements(p_requirements) r;

  for v_candidate in
    with raw_candidates(candidate, kind) as (
      -- Anchored to the clock hour, not to opening time: staff say "book them
      -- for 8", never "book them for 8:30 because we opened at 10:30".
      select candidate, 'standard'
      from generate_series(
        date_trunc('hour', p_date + v_open)
          + case
              when date_trunc('hour', p_date + v_open) < p_date + v_open
                then interval '1 hour'
              else interval '0'
            end,
        v_close_at - make_interval(mins => v_max_reserved),
        interval '1 hour'
      ) candidate
      union all
      -- ... but never lose the first bookable minutes of an outlet whose
      -- opening time is off the hour.
      select p_date + v_open, 'standard'
      where date_trunc('hour', p_date + v_open) <> p_date + v_open
      union all
      select public.csp_appointment_block_end_at(a), 'best_fit'
      from public.appointments a
      where a.outlet_id = p_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and a.appointment_date between p_date - 1 and p_date + 1
        and a.id is distinct from p_exclude_appointment_id
        and (
          p_exclude_appointment_group_id is null
          or a.appointment_group_id is distinct from
            p_exclude_appointment_group_id
        )
      union all
      select
        public.csp_appointment_start_at(a)
          - make_interval(mins => v_max_reserved),
        'best_fit'
      from public.appointments a
      where a.outlet_id = p_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and a.appointment_date between p_date - 1 and p_date + 1
        and a.id is distinct from p_exclude_appointment_id
        and (
          p_exclude_appointment_group_id is null
          or a.appointment_group_id is distinct from
            p_exclude_appointment_group_id
        )
      union all
      select h.end_at at time zone 'Asia/Kuala_Lumpur'
        + make_interval(
            mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
          ),
        'best_fit'
      from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
      union all
      select
        h.start_at at time zone 'Asia/Kuala_Lumpur'
          - make_interval(mins => v_max_reserved),
        'best_fit'
      from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
    ),
    bounded as (
      select candidate, kind
      from raw_candidates
      where candidate >= p_date + v_open
        and candidate <= v_close_at - make_interval(mins => v_max_reserved)
        and candidate > now() at time zone 'Asia/Kuala_Lumpur'
    )
    select
      candidate,
      case when bool_or(kind = 'best_fit') then 'best_fit' else 'standard' end
        as kind
    from bounded
    group by candidate
    order by candidate
  loop
    v_start := v_candidate.candidate;
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
      p_outlet_id,
      v_demands,
      'soft',
      p_exclude_appointment_id,
      p_exclude_appointment_group_id
    );
    if coalesce((v_verdict ->> 'feasible')::boolean, false)
       and jsonb_array_length(p_requirements) > 1 then
      select count(*)
      into v_allocated
      from public.allocate_preference_provisional_slots(
        p_outlet_id,
        p_date,
        v_start::time,
        p_requirements,
        p_exclude_appointment_group_id
      );
      if v_allocated <> jsonb_array_length(p_requirements) then
        v_verdict := jsonb_build_object(
          'feasible', false, 'dimension', 'therapist', 'at', v_start
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
    candidate_kind := v_candidate.kind;

    if not is_available and unavailable_dimension = 'therapist' then
      select nullif(r ->> 'requested_therapist_id', '')::uuid
      into v_specific
      from jsonb_array_elements(p_requirements) r
      where r ->> 'assignment_source' = 'specific_customer_request'
      limit 1;
      if v_specific is not null then
        conflict_therapist_id := v_specific;
        select
          public.csp_appointment_start_at(a)::time,
          public.csp_appointment_block_end_at(a)::time
        into conflict_start, conflict_end
        from public.appointments a
        where a.therapist_id = v_specific
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a)
            < v_start + make_interval(mins => v_max_reserved)
          and public.csp_appointment_block_end_at(a) > v_start
          and a.id is distinct from p_exclude_appointment_id
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from
              p_exclude_appointment_group_id
          )
        order by public.csp_appointment_start_at(a)
        limit 1;
      end if;
    end if;
    return next;
  end loop;
end;
$function$;

revoke all on function public.get_counter_preference_capacity_slots_v2(
  uuid, date, jsonb, uuid, uuid
) from public, anon;
grant execute on function public.get_counter_preference_capacity_slots_v2(
  uuid, date, jsonb, uuid, uuid
) to authenticated;

commit;
