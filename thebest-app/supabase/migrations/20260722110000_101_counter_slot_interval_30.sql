-- Counter appointment suggestions: 10-minute -> 30-minute grid.
--
-- get_available_slots (081) generated its regular convenience grid every 10
-- minutes, producing a cluttered staff time picker. Switch the grid to 30
-- minutes to match the desired "Suggested time [2:00] [2:30] [3:00] ..."
-- presentation. Boundary-aware candidates (starts right after a booking, at a
-- shift start, before the next booking, etc.) are still emitted exactly as
-- before, so the "recommended" best-fit times are unchanged -- only the base
-- filler grid is coarser. Verbatim copy of the live 081 body with the two
-- v_interval assignments changed from 10 to 30 and the comment updated.

create or replace function public.get_available_slots(
  p_date date,
  p_therapist_id uuid,
  p_room_id uuid,
  p_duration integer,
  p_exclude_id uuid,
  p_buffer_after_minutes integer
)
returns table (
  start_time time without time zone,
  end_time time without time zone,
  classification text,
  score integer,
  reason text,
  room_available_slots integer,
  previous_block_end time without time zone,
  next_block_start time without time zone,
  gap_before_minutes integer,
  gap_after_minutes integer
)
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_interval integer := 30;
  v_buffer integer := greatest(coalesce(p_buffer_after_minutes, 0), 0);
  v_outlet_id uuid;
  v_open_at timestamp;
  v_close_at timestamp;
  v_start_at timestamp;
  v_end_at timestamp;
  v_reserved_end_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
  v_work_starts timestamp[] := array[]::timestamp[];
  v_work_ends timestamp[] := array[]::timestamp[];
  v_leave_starts timestamp[] := array[]::timestamp[];
  v_leave_ends timestamp[] := array[]::timestamp[];
  v_block_starts timestamp[] := array[]::timestamp[];
  v_block_ends timestamp[] := array[]::timestamp[];
  v_candidates timestamp[] := array[]::timestamp[];
  v_within_hours boolean;
  v_on_leave boolean;
  v_previous_end timestamp;
  v_next_start timestamp;
  v_gap_before integer;
  v_gap_after integer;
begin
  if p_duration is null or p_duration <= 0 then return; end if;

  select t.outlet_id
  into v_outlet_id
  from public.therapists t
  join public.rooms r on r.id = p_room_id and r.outlet_id = t.outlet_id
  where t.id = p_therapist_id;

  if v_outlet_id is null then return; end if;

  -- Staff suggestions use a 30-minute convenience grid. The public booking
  -- interval is a customer-facing presentation choice and must not make the
  -- internal staff scheduler discard useful times.
  select
    coalesce(bs.open_time, '09:00'::time),
    coalesce(bs.close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings bs
  where bs.outlet_id = v_outlet_id
  limit 1;

  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);
  v_interval := 30;
  v_open_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  -- Include both the selected calendar day's shifts and an overnight shift
  -- that began on the previous day.
  select
    coalesce(array_agg(window_start order by window_start), array[]::timestamp[]),
    coalesce(array_agg(window_end order by window_start), array[]::timestamp[])
  into v_work_starts, v_work_ends
  from (
    select
      p_date + wh.start_time as window_start,
      p_date + wh.end_time
        + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
        as window_end
    from public.therapist_working_hours wh
    where wh.therapist_id = p_therapist_id
      and wh.day_of_week = extract(dow from p_date)::integer

    union all

    select
      (p_date - 1) + wh.start_time as window_start,
      (p_date - 1) + wh.end_time + interval '1 day' as window_end
    from public.therapist_working_hours wh
    where wh.therapist_id = p_therapist_id
      and wh.end_time <= wh.start_time
      and wh.day_of_week = extract(dow from p_date - 1)::integer
  ) shifts;

  select
    coalesce(
      array_agg(u.starts_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at),
      array[]::timestamp[]
    ),
    coalesce(
      array_agg(u.ends_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at),
      array[]::timestamp[]
    )
  into v_leave_starts, v_leave_ends
  from public.therapist_unavailability u
  where u.therapist_id = p_therapist_id
    and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_close_at
    and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_open_at;

  -- Therapist appointments and active payment holds are the true schedule
  -- blocks used for adjacency scoring.
  select
    coalesce(array_agg(block_start order by block_start), array[]::timestamp[]),
    coalesce(array_agg(block_end order by block_start), array[]::timestamp[])
  into v_block_starts, v_block_ends
  from (
    select
      public.csp_appointment_start_at(a) as block_start,
      public.csp_appointment_block_end_at(a) as block_end
    from public.appointments a
    where a.appointment_date::date between p_date - 1 and p_date + 1
      and a.outlet_id = v_outlet_id
      and a.therapist_id = p_therapist_id
      and public.csp_blocks_schedule(a.status::text)
      and (p_exclude_id is null or a.id <> p_exclude_id)

    union all

    select
      hold.start_at at time zone 'Asia/Kuala_Lumpur' as block_start,
      (
        hold.end_at
        + make_interval(
            mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
          )
      ) at time zone 'Asia/Kuala_Lumpur' as block_end
    from public.booking_holds hold
    where hold.outlet_id = v_outlet_id
      and hold.assigned_therapist_id = p_therapist_id
      and hold.status = 'pending_payment'
      and hold.expires_at > now()
  ) therapist_blocks
  where block_start < v_close_at and block_end > v_open_at;

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date = p_date
    and a.outlet_id = v_outlet_id
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and a.outlet_id = v_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  -- Candidate sources:
  --   * regular clean interval grid;
  --   * selected therapist block edges;
  --   * working-shift and leave edges;
  --   * selected-room appointment/hold edges (availability validation still
  --     decides whether room capacity is actually exhausted).
  select coalesce(array_agg(candidate order by candidate), array[]::timestamp[])
  into v_candidates
  from (
    select distinct raw_candidate as candidate
    from (
      select generate_series(
        v_open_at,
        v_close_at - make_interval(mins => p_duration + v_buffer),
        make_interval(mins => v_interval)
      ) as raw_candidate

      union all
      select unnest(v_block_ends)

      union all
      select unnest(v_block_starts)
        - make_interval(mins => p_duration + v_buffer)

      union all
      select unnest(v_work_starts)

      union all
      select unnest(v_work_ends)
        - make_interval(mins => p_duration + v_buffer)

      union all
      select unnest(v_leave_ends)

      union all
      select public.csp_appointment_block_end_at(a)
      from public.appointments a
      where a.appointment_date::date between p_date - 1 and p_date + 1
        and a.outlet_id = v_outlet_id
        and a.room_id = p_room_id
        and public.csp_blocks_schedule(a.status::text)
        and (p_exclude_id is null or a.id <> p_exclude_id)

      union all
      select public.csp_appointment_start_at(a)
        - make_interval(mins => p_duration + v_buffer)
      from public.appointments a
      where a.appointment_date::date between p_date - 1 and p_date + 1
        and a.outlet_id = v_outlet_id
        and a.room_id = p_room_id
        and public.csp_blocks_schedule(a.status::text)
        and (p_exclude_id is null or a.id <> p_exclude_id)

      union all
      select (
        hold.end_at
        + make_interval(
            mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
          )
      ) at time zone 'Asia/Kuala_Lumpur'
      from public.booking_holds hold
      where hold.outlet_id = v_outlet_id
        and hold.assigned_room_id = p_room_id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()

      union all
      select (hold.start_at at time zone 'Asia/Kuala_Lumpur')
        - make_interval(mins => p_duration + v_buffer)
      from public.booking_holds hold
      where hold.outlet_id = v_outlet_id
        and hold.assigned_room_id = p_room_id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
    ) sources
    where raw_candidate >= v_open_at
      and raw_candidate + make_interval(mins => p_duration + v_buffer)
        <= v_close_at
  ) candidates;

  foreach v_start_at in array v_candidates loop
    if v_start_at <= v_now_local then continue; end if;

    v_end_at := v_start_at + make_interval(mins => p_duration);
    v_reserved_end_at := v_end_at + make_interval(mins => v_buffer);
    start_time := v_start_at::time;
    end_time := v_end_at::time;
    room_available_slots := 0;
    previous_block_end := null;
    next_block_start := null;
    gap_before_minutes := null;
    gap_after_minutes := null;

    v_within_hours := false;
    for i in 1 .. coalesce(array_length(v_work_starts, 1), 0) loop
      if v_work_starts[i] <= v_start_at
         and v_work_ends[i] >= v_reserved_end_at then
        v_within_hours := true;
        exit;
      end if;
    end loop;
    if not v_within_hours then
      classification := 'unavailable';
      score := 0;
      reason := 'outside_working_hours';
      return next;
      continue;
    end if;

    v_on_leave := false;
    for i in 1 .. coalesce(array_length(v_leave_starts, 1), 0) loop
      if v_leave_starts[i] < v_reserved_end_at
         and v_leave_ends[i] > v_start_at then
        v_on_leave := true;
        exit;
      end if;
    end loop;
    if v_on_leave then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_on_leave';
      return next;
      continue;
    end if;

    -- Validate through the end of the proposed cleanup buffer. The returned
    -- end_time remains the customer-facing treatment end.
    select * into v_check
    from public.check_booking_availability(
      v_start_at::date,
      v_start_at::time,
      v_reserved_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    if not coalesce(v_check.therapist_available, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
      continue;
    elsif coalesce(v_check.room_full, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
      continue;
    end if;

    room_available_slots := greatest(
      coalesce(v_check.room_available_slots, 0),
      0
    );

    v_previous_end := null;
    v_next_start := null;
    for i in 1 .. coalesce(array_length(v_block_starts, 1), 0) loop
      if v_block_ends[i] <= v_start_at
         and (v_previous_end is null or v_block_ends[i] > v_previous_end) then
        v_previous_end := v_block_ends[i];
      end if;
      if v_block_starts[i] >= v_reserved_end_at
         and (v_next_start is null or v_block_starts[i] < v_next_start) then
        v_next_start := v_block_starts[i];
      end if;
    end loop;

    v_gap_before := case
      when v_previous_end is null then null
      else (extract(epoch from v_start_at - v_previous_end) / 60)::integer
    end;
    v_gap_after := case
      when v_next_start is null then null
      else (extract(epoch from v_next_start - v_reserved_end_at) / 60)::integer
    end;

    previous_block_end := v_previous_end::time;
    next_block_start := v_next_start::time;
    gap_before_minutes := v_gap_before;
    gap_after_minutes := v_gap_after;

    if v_gap_before = 0 and v_gap_after = 0 then
      v_score := 300;
      v_reason := 'fills_between_bookings';
    elsif v_gap_before = 0
       and v_gap_after is not null
       and v_gap_after > 0
       and v_gap_after < 30 then
      -- The short remainder is unavoidable for a treatment of this length.
      -- Prefer packing forward from the previous booking, but explain it.
      v_score := 205;
      v_reason := 'starts_after_booking_short_gap';
    elsif v_gap_after = 0
       and v_gap_before is not null
       and v_gap_before > 0
       and v_gap_before < 30 then
      v_score := 200;
      v_reason := 'ends_before_booking_short_gap';
    elsif v_gap_before = 0 then
      v_score := 240;
      v_reason := 'starts_after_booking';
    elsif v_gap_after = 0 then
      v_score := 220;
      v_reason := 'ends_before_booking';
    elsif exists (
      select 1
      from unnest(v_leave_ends) leave_end
      where leave_end = v_start_at
    ) then
      v_score := 190;
      v_reason := 'starts_after_unavailability';
    elsif exists (
      select 1
      from unnest(v_work_starts) work_start
      where work_start = v_start_at
    ) then
      v_score := 160;
      v_reason := 'starts_at_shift';
    elsif (v_gap_before is not null and v_gap_before < 30)
       or (v_gap_after is not null and v_gap_after < 30) then
      v_score := -50;
      v_reason := 'leaves_short_gap';
    elsif v_average_count > 0 and v_therapist_count < v_average_count then
      v_score := 10;
      v_reason := 'balances_workload';
    else
      v_score := 0;
      v_reason := 'standard_slot';
    end if;

    classification := case
      when v_score >= 150 then 'recommended'
      else 'standard'
    end;
    score := v_score;
    reason := v_reason;
    return next;
  end loop;
end;
$function$;

revoke all on function public.get_available_slots(
  date, uuid, uuid, integer, uuid, integer
) from public, anon;
grant execute on function public.get_available_slots(
  date, uuid, uuid, integer, uuid, integer
) to authenticated;
