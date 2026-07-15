-- Keep staff bookings, walk-in queueing, and therapist switching aligned with
-- planned leave. Queue wait minutes must round up so a 18:00 release never
-- becomes a rejected 17:59 reservation.

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
  v_ignore_cleanup boolean := coalesce(current_setting('app.ignore_cleanup_buffer', true), '') = 'on';
  v_therapist_conflicts integer := 0;
  v_leave_conflicts integer := 0;
  v_room_conflicts integer := 0;
  v_therapist_hold_conflicts integer := 0;
  v_room_hold_conflicts integer := 0;
  v_room_total integer := 1;
  v_therapist_busy_until time;
  v_leave_busy_until time;
  v_room_busy_until time;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total from public.rooms r where r.id = p_room_id;
  v_room_total := coalesce(v_room_total, 1);

  select count(*), max((case when v_ignore_cleanup
    then public.csp_appointment_end_at(a)
    else public.csp_appointment_block_end_at(a) end)::time)
  into v_therapist_conflicts, v_therapist_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and (case when v_ignore_cleanup
      then public.csp_appointment_end_at(a)
      else public.csp_appointment_block_end_at(a) end) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id);

  select count(*), max((u.ends_at at time zone 'Asia/Kuala_Lumpur')::time)
  into v_leave_conflicts, v_leave_busy_until
  from public.therapist_unavailability u
  where u.therapist_id = p_therapist_id
    and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  select count(*), max((case when v_ignore_cleanup
    then public.csp_appointment_end_at(a)
    else public.csp_appointment_block_end_at(a) end)::time)
  into v_room_conflicts, v_room_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and (case when v_ignore_cleanup
      then public.csp_appointment_end_at(a)
      else public.csp_appointment_block_end_at(a) end) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id);

  select count(*) into v_therapist_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_therapist_id = p_therapist_id
    and hold.status = 'pending_payment' and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((case when v_ignore_cleanup then hold.end_at else
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)) end)
      at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  select count(*) into v_room_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_room_id = p_room_id
    and hold.status = 'pending_payment' and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((case when v_ignore_cleanup then hold.end_at else
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)) end)
      at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  v_therapist_conflicts := v_therapist_conflicts
    + coalesce(v_leave_conflicts, 0)
    + coalesce(v_therapist_hold_conflicts, 0);
  v_room_conflicts := v_room_conflicts + coalesce(v_room_hold_conflicts, 0);
  therapist_available := v_therapist_conflicts = 0;
  therapist_busy_until := case
    when v_leave_conflicts > 0 then v_leave_busy_until
    else v_therapist_busy_until
  end;
  room_total_slots := v_room_total;
  room_booked_slots := v_room_conflicts;
  room_available_slots := greatest(v_room_total - v_room_conflicts, 0);
  room_full := v_room_conflicts >= v_room_total;
  room_full_until := case when room_full then v_room_busy_until else null end;
  return next;
end;
$$;

create or replace function public.get_walkin_therapist_availability(
  p_today date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid, name text, status text, free_at time, free_in_minutes integer
)
language plpgsql stable set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
begin
  return query
  select t.id, t.name,
    case
      when leave_window.ends_at is not null then 'on_leave'
      when busy.free_at is null then 'free_now'
      else 'busy'
    end,
    coalesce(leave_window.ends_at, busy.free_at)::time,
    case
      when leave_window.ends_at is not null then 0
      when busy.free_at is null then 0
      else greatest(ceil(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer, 0)
    end
  from public.therapists t
  left join lateral (
    select max(public.csp_appointment_end_at(a)) as free_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.therapist_id = t.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_end_at(a) > v_start_at
  ) busy on true
  left join lateral (
    select max(u.ends_at at time zone 'Asia/Kuala_Lumpur') as ends_at
    from public.therapist_unavailability u
    where u.therapist_id = t.id
      and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
      and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
  ) leave_window on true
  where coalesce(t.availability_status, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
  order by
    case
      when leave_window.ends_at is not null then 2
      when busy.free_at is null then 0
      else 1
    end,
    busy.free_at nulls first,
    t.name;
end;
$$;

revoke all on function public.check_booking_availability(date, time, time, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.check_booking_availability(date, time, time, uuid, uuid, uuid, uuid) to authenticated;
revoke all on function public.get_walkin_therapist_availability(date, time, integer) from public, anon;
grant execute on function public.get_walkin_therapist_availability(date, time, integer) to authenticated;
