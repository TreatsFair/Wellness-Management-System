-- Smart staff slot suggestions, part 1 (server).
--
-- Fixes in this migration:
-- 1) get_available_slots (068) had a fall-through bug: an unavailable slot did
--    `return next` without `continue`, so the SAME time was emitted a second
--    time as standard/recommended. Busy times therefore showed as bookable in
--    the booking screen. The loop now short-circuits correctly.
-- 2) check_booking_availability now also treats a therapist as unavailable
--    outside their working hours (Dashboard -> Staff schedule, including
--    split shifts/breaks) and during therapist_unavailability (leave). Online
--    booking already enforced both; staff-side suggestions and the create/
--    update RPC pre-checks now agree with it.
-- 3) get_available_slots returns per-slot room_available_slots so the app can
--    subtract not-yet-saved multi-pax picks from room capacity client-side,
--    and reports precise reasons ('outside_working_hours',
--    'therapist_on_leave', 'therapist_conflict', 'room_full').
-- 4) Gap-aware scoring: true adjacency still wins (fills_between_bookings >
--    starts_after_booking > ends_before_booking), and slots that would strand
--    a short unusable gap (< 30 min) next to an existing booking are pushed to
--    the bottom ('leaves_short_gap').

-- ── 1+2) Availability pre-check: working hours + leave ─────────────────────
-- Same signature and return shape as 035; only the body changes, so every
-- caller (create/update RPCs, walk-in checks, get_available_slots, the app's
-- validateSlot) inherits the new rules automatically.
create or replace function public.check_booking_availability(
  p_date date,
  p_start_time time,
  p_end_time time,
  p_therapist_id uuid,
  p_room_id uuid,
  p_exclude_appointment_id uuid default null,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  therapist_available boolean,
  therapist_busy_until time,
  room_total_slots integer,
  room_booked_slots integer,
  room_available_slots integer,
  room_full boolean,
  room_full_until time
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_date, p_start_time);
  v_end_at timestamp := public.csp_end_at(p_date, p_start_time, p_end_time);
  v_therapist_conflicts integer := 0;
  v_room_conflicts integer := 0;
  v_therapist_hold_conflicts integer := 0;
  v_room_hold_conflicts integer := 0;
  v_room_total integer := 1;
  v_therapist_busy_until time;
  v_room_busy_until time;
  v_within_hours boolean := true;
  v_leave_conflicts integer := 0;
  v_leave_until time;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  -- Working hours: schedules are seeded for every therapist/day (026), so a
  -- missing day means the therapist is off; split shifts mean the whole
  -- requested window must fit inside one shift (the gap between shifts is a
  -- break). A close at/before the open time means the shift runs past
  -- midnight (074 semantics).
  select exists (
    select 1
    from public.therapist_working_hours wh
    where wh.therapist_id = p_therapist_id
      and (
        (
          wh.day_of_week = extract(dow from p_date)::integer
          and p_date + wh.start_time <= v_start_at
          and p_date + wh.end_time
            + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
            >= v_end_at
        )
        or (
          -- An early-morning calendar slot can belong to the previous day's
          -- overnight shift (for example Sunday 21:00 through Monday 02:00).
          wh.end_time <= wh.start_time
          and wh.day_of_week = extract(dow from p_date - 1)::integer
          and (p_date - 1) + wh.start_time <= v_start_at
          and (p_date - 1) + wh.end_time + interval '1 day' >= v_end_at
        )
      )
  ) into v_within_hours;

  -- Leave / blocked time (stored as timestamptz; appointments use naive
  -- Asia/Kuala_Lumpur wall time, so compare on the same clock).
  select count(*), max((u.ends_at at time zone 'Asia/Kuala_Lumpur')::time)
  into v_leave_conflicts, v_leave_until
  from public.therapist_unavailability u
  where u.therapist_id = p_therapist_id
    and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  -- Existing appointments (blocked through their own cleanup buffer).
  select count(*), max(public.csp_appointment_block_end_at(a)::time)
  into v_therapist_conflicts, v_therapist_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_block_end_at(a) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (
      p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id
    );

  select count(*), max(public.csp_appointment_block_end_at(a)::time)
  into v_room_conflicts, v_room_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_block_end_at(a) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (
      p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id
    );

  -- Pending online booking holds (mirror of the enforcement trigger).
  select count(*)
  into v_therapist_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_therapist_id = p_therapist_id
    and hold.status = 'pending_payment'
    and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
    ) at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  select count(*)
  into v_room_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_room_id = p_room_id
    and hold.status = 'pending_payment'
    and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
    ) at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  v_therapist_conflicts := v_therapist_conflicts + coalesce(v_therapist_hold_conflicts, 0);
  v_room_conflicts := v_room_conflicts + coalesce(v_room_hold_conflicts, 0);

  therapist_available := v_therapist_conflicts = 0
    and v_leave_conflicts = 0
    and v_within_hours;
  therapist_busy_until := coalesce(v_therapist_busy_until, v_leave_until);
  room_total_slots := v_room_total;
  room_booked_slots := v_room_conflicts;
  room_available_slots := greatest(v_room_total - v_room_conflicts, 0);
  room_full := v_room_conflicts >= v_room_total;
  room_full_until := case when room_full then v_room_busy_until else null end;
  return next;
end;
$$;

grant execute on function public.check_booking_availability(date, time, time, uuid, uuid, uuid, uuid) to authenticated;
revoke execute on function public.check_booking_availability(date, time, time, uuid, uuid, uuid, uuid) from public, anon;

-- ── 3+4) Slot generator: no duplicate rows, precise reasons, gap scoring ───
-- The return table gains room_available_slots, which requires drop+create.
drop function if exists public.get_available_slots(date, uuid, uuid, integer, uuid);

create function public.get_available_slots(
  p_date date,
  p_therapist_id uuid,
  p_room_id uuid,
  p_duration integer,
  p_exclude_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  classification text,
  score integer,
  reason text,
  room_available_slots integer
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_interval integer := 10;
  v_outlet_id uuid;
  v_start_at timestamp;
  v_end_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
  v_work_starts timestamp[] := '{}';
  v_work_ends timestamp[] := '{}';
  v_leave_starts timestamp[] := '{}';
  v_leave_ends timestamp[] := '{}';
  v_block_starts timestamp[] := '{}';
  v_block_ends timestamp[] := '{}';
  v_within_hours boolean;
  v_on_leave boolean;
  v_gap_before integer;
  v_gap_after integer;
  v_gap integer;
  i integer;
begin
  if p_duration is null or p_duration <= 0 then return; end if;

  select t.outlet_id
  into v_outlet_id
  from public.therapists t
  join public.rooms r on r.id = p_room_id and r.outlet_id = t.outlet_id
  where t.id = p_therapist_id;

  if v_outlet_id is null then return; end if;

  select
    coalesce(bs.open_time, '09:00'::time),
    coalesce(bs.close_time, '21:00'::time),
    greatest(coalesce(obs.slot_interval_minutes, 10), 5)
  into v_open, v_close, v_interval
  from public.business_settings bs
  left join public.online_booking_outlet_settings obs
    on obs.outlet_id = bs.outlet_id
  where bs.outlet_id = v_outlet_id
  limit 1;

  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);
  v_interval := greatest(coalesce(v_interval, 10), 5);
  v_start_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  -- Day-level facts, loaded once: working shifts, leave windows, and the
  -- therapist's busy block edges used for gap scoring.
  select
    coalesce(array_agg(p_date + wh.start_time order by wh.start_time), '{}'),
    coalesce(array_agg(
      p_date + wh.end_time
        + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
      order by wh.start_time
    ), '{}')
  into v_work_starts, v_work_ends
  from public.therapist_working_hours wh
  where wh.therapist_id = p_therapist_id
    and wh.day_of_week = extract(dow from p_date)::integer;

  select
    coalesce(array_agg(u.starts_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at), '{}'),
    coalesce(array_agg(u.ends_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at), '{}')
  into v_leave_starts, v_leave_ends
  from public.therapist_unavailability u
  where u.therapist_id = p_therapist_id
    and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < p_date + interval '2 days'
    and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > p_date::timestamp;

  select
    coalesce(array_agg(public.csp_appointment_start_at(a)), '{}'),
    coalesce(array_agg(public.csp_appointment_block_end_at(a)), '{}')
  into v_block_starts, v_block_ends
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.outlet_id = v_outlet_id
    and public.csp_blocks_schedule(a.status::text)
    -- Shared rooms may still have capacity while another therapist is using
    -- them. Such rows must not manufacture a fake adjacency recommendation.
    and a.therapist_id = p_therapist_id
    and (p_exclude_id is null or a.id <> p_exclude_id);

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
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

  while v_start_at + make_interval(mins => p_duration) <= v_close_at loop
    v_end_at := v_start_at + make_interval(mins => p_duration);

    if v_start_at <= v_now_local then
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    start_time := v_start_at::time;
    end_time := v_end_at::time;
    room_available_slots := 0;

    -- Off / outside shift (a missing shift row means the therapist is off).
    v_within_hours := false;
    if v_work_starts is not null then
      for i in 1 .. coalesce(array_length(v_work_starts, 1), 0) loop
        if v_work_starts[i] <= v_start_at and v_work_ends[i] >= v_end_at then
          v_within_hours := true;
          exit;
        end if;
      end loop;
    end if;
    if not v_within_hours then
      classification := 'unavailable';
      score := 0;
      reason := 'outside_working_hours';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    -- Leave / blocked time.
    v_on_leave := false;
    for i in 1 .. coalesce(array_length(v_leave_starts, 1), 0) loop
      if v_leave_starts[i] < v_end_at and v_leave_ends[i] > v_start_at then
        v_on_leave := true;
        exit;
      end if;
    end loop;
    if v_on_leave then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_on_leave';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    -- Real conflicts: appointments, buffers, pending online holds, room
    -- capacity - all decided by check_booking_availability.
    select * into v_check
    from public.check_booking_availability(
      v_start_at::date,
      v_start_at::time,
      v_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    if not coalesce(v_check.therapist_available, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    elsif coalesce(v_check.room_full, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    room_available_slots := greatest(coalesce(v_check.room_available_slots, 0), 0);

    -- Gap scoring against existing busy blocks (therapist or room):
    -- v_gap_before = minutes of idle time this slot leaves after the previous
    -- booking, v_gap_after = idle minutes before the next booking.
    v_gap_before := null;
    v_gap_after := null;
    for i in 1 .. coalesce(array_length(v_block_starts, 1), 0) loop
      if v_block_ends[i] <= v_start_at then
        v_gap := (extract(epoch from v_start_at - v_block_ends[i]) / 60)::integer;
        if v_gap_before is null or v_gap < v_gap_before then
          v_gap_before := v_gap;
        end if;
      end if;
      if v_block_starts[i] >= v_end_at then
        v_gap := (extract(epoch from v_block_starts[i] - v_end_at) / 60)::integer;
        if v_gap_after is null or v_gap < v_gap_after then
          v_gap_after := v_gap;
        end if;
      end if;
    end loop;

    if v_gap_before = 0 and v_gap_after = 0 then
      v_score := 300;
      v_reason := 'fills_between_bookings';
    elsif v_gap_before = 0 then
      v_score := 200;
      v_reason := 'starts_after_booking';
    elsif v_gap_after = 0 then
      v_score := 150;
      v_reason := 'ends_before_booking';
    elsif (v_gap_before is not null and v_gap_before < 30)
       or (v_gap_after is not null and v_gap_after < 30) then
      -- Bookable, but it strands a sliver of idle time too short to sell.
      v_score := -20;
      v_reason := 'leaves_short_gap';
    elsif v_average_count > 0 and v_therapist_count < v_average_count then
      v_score := 10;
      v_reason := 'balances_workload';
    else
      v_score := 0;
      v_reason := 'standard_slot';
    end if;

    classification := case when v_score >= 150 then 'recommended' else 'standard' end;
    score := v_score;
    reason := v_reason;
    return next;

    v_start_at := v_start_at + make_interval(mins => v_interval);
  end loop;
end;
$$;

revoke all on function public.get_available_slots(date, uuid, uuid, integer, uuid) from public, anon;
grant execute on function public.get_available_slots(date, uuid, uuid, integer, uuid) to authenticated;
