-- Silent provisional allocation for capacity-based counter bookings.
--
-- Once the counter picks a capacity slot (from get_counter_capacity_slots),
-- the booking still needs a concrete therapist + room per pax because
-- appointments.therapist_id/room_id are NOT NULL. This picks p_pax free
-- therapists (in rotation-number order = display_order) and pairs each with a
-- free room slot of the required type, all validated for the same window with
-- the same conflict rules as check_booking_availability. The result feeds
-- create_appointment_group_with_csp with is_provisional = true; the real
-- therapist + room are confirmed on the day at check-in, and the daily refresh
-- job re-points provisional picks at the live-queue recommendation.
--
-- p_end_time is the treatment end (start + duration); the room window adds the
-- cleanup buffer, matching the capacity RPC.
create or replace function public.allocate_provisional_slots(
  p_outlet_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_pax integer,
  p_room_type text default null,
  p_buffer_after_minutes integer default 0,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  pax_index integer,
  therapist_id uuid,
  room_id uuid
)
language plpgsql
stable
set search_path to 'public'
as $$
declare
  v_buffer integer := greatest(coalesce(p_buffer_after_minutes, 0), 0);
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_e timestamp := public.csp_end_at(p_date, p_start_time, p_end_time)
    + make_interval(mins => v_buffer);
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_dow integer := extract(dow from p_date - 1)::integer;
begin
  if p_pax is null or p_pax < 1 then return; end if;

  return query
  with free_therapists as (
    select
      t.id,
      row_number() over (order by t.display_order, t.name, t.id) as rn
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true) = true
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
      and exists (
        select 1 from public.therapist_working_hours wh
        where wh.therapist_id = t.id
          and (
            (
              wh.day_of_week = v_dow
              and p_date + wh.start_time <= v_start
              and p_date + wh.end_time
                + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
                >= v_e
            )
            or (
              wh.end_time <= wh.start_time
              and wh.day_of_week = v_prev_dow
              and (p_date - 1) + wh.start_time <= v_start
              and (p_date - 1) + wh.end_time + interval '1 day' >= v_e
            )
          )
      )
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = t.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_e
          and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start
      )
      and not exists (
        select 1 from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_e
          and public.csp_appointment_block_end_at(a) > v_start
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1 from public.booking_holds hold
        where hold.assigned_therapist_id = t.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_e
          and ((
            hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
          ) at time zone 'Asia/Kuala_Lumpur') > v_start
      )
  ),
  room_capacity as (
    select
      r.id as room_id,
      r.room_type,
      greatest(coalesce(r.total_slots, 1), 1) - (
        (
          select count(*)
          from public.appointments a
          where a.appointment_date::date between p_date - 1 and p_date + 1
            and a.room_id = r.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_e
            and public.csp_appointment_block_end_at(a) > v_start
            and (
              p_exclude_appointment_group_id is null
              or a.appointment_group_id is distinct from p_exclude_appointment_group_id
            )
        )
        + (
          select count(*)
          from public.booking_holds hold
          where hold.assigned_room_id = r.id
            and hold.status = 'pending_payment'
            and hold.expires_at > now()
            and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_e
            and ((
              hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
            ) at time zone 'Asia/Kuala_Lumpur') > v_start
        )
      ) as free_slots
    from public.rooms r
    where r.outlet_id = p_outlet_id
      and (
        p_room_type is null
        or p_room_type = ''
        or lower(coalesce(r.room_type, '')) = lower(p_room_type)
      )
  ),
  room_slots as (
    select
      rc.room_id,
      row_number() over (order by rc.room_type, rc.room_id, gs.n) as rn
    from room_capacity rc
    cross join lateral generate_series(1, greatest(rc.free_slots, 0)) gs(n)
  )
  select ft.rn::integer, ft.id, rs.room_id
  from free_therapists ft
  join room_slots rs on rs.rn = ft.rn
  where ft.rn <= p_pax
  order by ft.rn;
end;
$$;

revoke all on function public.allocate_provisional_slots(
  uuid, date, time, time, integer, text, integer, uuid
) from public, anon;
grant execute on function public.allocate_provisional_slots(
  uuid, date, time, time, integer, text, integer, uuid
) to authenticated;
