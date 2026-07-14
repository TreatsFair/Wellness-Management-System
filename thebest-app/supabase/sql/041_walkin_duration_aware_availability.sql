-- Walk-in POS bug: the therapist/zone lists on the walk-in screen only checked
-- whether a resource was busy *at the exact current instant* (see
-- order_screen.dart _loadTherapistsLive/_loadZonesLive), never whether the
-- selected service's full duration would run into a later booking. A
-- therapist free right now but booked again in 15 minutes showed as
-- "Available immediately" for a 1-hour service, and the conflict only
-- surfaced as a raw error at final payment (check_booking_availability),
-- far too late to be useful.
--
-- check_walkin_availability (012/014/036) already does the correct
-- duration-aware conflict check, but bundles the therapist list together with
-- a single room's zone-availability in one call -- and the walk-in screen
-- shows the therapist list *before* a room/zone is chosen. Splitting the
-- therapist half out into its own room-independent function lets the Dart
-- side call it as soon as services (and therefore duration) are selected,
-- and a matching per-room function replaces the zone list's identical bug.

create or replace function public.get_walkin_therapist_availability(
  p_today date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid,
  name text,
  status text,
  free_at time,
  free_in_minutes integer
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
begin
  return query
  select
    t.id,
    t.name,
    case when busy.free_at is null then 'free_now' else 'busy' end,
    busy.free_at::time,
    case
      when busy.free_at is null then 0
      else greatest(floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer, 0)
    end
  from public.therapists t
  left join lateral (
    select max(public.csp_appointment_block_end_at(a)) as free_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.therapist_id = t.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_block_end_at(a) > v_start_at
  ) busy on true
  where coalesce(t.availability_status, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
  order by case when busy.free_at is null then 0 else 1 end, busy.free_at nulls first, t.name;
end;
$$;

grant execute on function public.get_walkin_therapist_availability(date, time, integer) to authenticated;
revoke execute on function public.get_walkin_therapist_availability(date, time, integer) from public, anon;

create or replace function public.get_walkin_room_availability(
  p_today date,
  p_now_time time,
  p_duration integer,
  p_room_id uuid
)
returns table (
  available_now boolean,
  free_slots integer,
  total_slots integer,
  free_at time
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
  v_room_total integer := 1;
  v_room_booked integer := 0;
  v_free_at timestamp;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  select count(*)
  into v_room_booked
  from public.appointments a
  where a.appointment_date::date between p_today - 1 and p_today + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_block_end_at(a) > v_start_at;

  select max(public.csp_appointment_block_end_at(a))
  into v_free_at
  from public.appointments a
  where a.appointment_date::date between p_today - 1 and p_today + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_block_end_at(a) > v_start_at;

  free_slots := greatest(v_room_total - v_room_booked, 0);
  total_slots := v_room_total;
  available_now := free_slots > 0;
  free_at := v_free_at::time;
  return next;
end;
$$;

grant execute on function public.get_walkin_room_availability(date, time, integer, uuid) to authenticated;
revoke execute on function public.get_walkin_room_availability(date, time, integer, uuid) from public, anon;
