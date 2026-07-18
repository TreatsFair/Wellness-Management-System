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
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

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

  therapist_available := v_therapist_conflicts = 0;
  therapist_busy_until := v_therapist_busy_until;
  room_total_slots := v_room_total;
  room_booked_slots := v_room_conflicts;
  room_available_slots := greatest(v_room_total - v_room_conflicts, 0);
  room_full := v_room_conflicts >= v_room_total;
  room_full_until := case when room_full then v_room_busy_until else null end;
  return next;
end;
$$;

grant execute on function public.check_booking_availability(date, time, time, uuid, uuid, uuid, uuid) to authenticated;
revoke execute on function public.check_booking_availability(date, time, time, uuid, uuid, uuid, uuid) from public, anon;;
