-- Capacity-based counter appointment slots.
--
-- The counter booking flow is moving to Date -> Pax -> Services -> Time with NO
-- therapist/room selection (those are assigned on the spot at check-in). So the
-- time picker can no longer be therapist-specific (get_available_slots needs a
-- therapist). This returns a clean 30-minute grid where, for the whole group,
-- at least p_pax therapists AND at least p_pax suitable room slots are free for
-- the complete service window.
--
-- Conflict semantics mirror check_booking_availability exactly (same working-
-- hours shift gate, leave, appointment overlap via csp_* helpers through each
-- booking's cleanup buffer, and pending-hold overlap) so a time offered here
-- will actually be bookable when the group is created. The window used for all
-- checks is [start, start + duration + buffer], matching how get_available_slots
-- validates (it passes the buffer-inclusive reserved end).
create or replace function public.get_counter_capacity_slots(
  p_outlet_id uuid,
  p_date date,
  p_duration integer,
  p_pax integer,
  p_room_type text default null,
  p_buffer_after_minutes integer default 0,
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
  v_buffer integer := greatest(coalesce(p_buffer_after_minutes, 0), 0);
  v_open_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_dow integer := extract(dow from p_date - 1)::integer;
  v_s timestamp;
  v_treat_end timestamp;
  v_e timestamp;
  v_tfree integer;
  v_rfree integer;
begin
  if p_duration is null or p_duration <= 0 or coalesce(p_pax, 0) < 1 then
    return;
  end if;

  select coalesce(bs.open_time, '09:00'::time), coalesce(bs.close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings bs
  where bs.outlet_id = p_outlet_id
  limit 1;
  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);

  v_open_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  for v_s in
    select g
    from generate_series(
      v_open_at,
      v_close_at - make_interval(mins => p_duration + v_buffer),
      interval '30 minutes'
    ) g
  loop
    if v_s <= v_now_local then continue; end if;

    v_treat_end := v_s + make_interval(mins => p_duration);
    v_e := v_treat_end + make_interval(mins => v_buffer);

    -- Free therapists: active, role therapist, whose shift covers [v_s, v_e],
    -- not on leave, with no overlapping appointment or pending hold.
    select count(*) into v_tfree
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
              and p_date + wh.start_time <= v_s
              and p_date + wh.end_time
                + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
                >= v_e
            )
            or (
              wh.end_time <= wh.start_time
              and wh.day_of_week = v_prev_dow
              and (p_date - 1) + wh.start_time <= v_s
              and (p_date - 1) + wh.end_time + interval '1 day' >= v_e
            )
          )
      )
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = t.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_e
          and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_s
      )
      and not exists (
        select 1 from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_e
          and public.csp_appointment_block_end_at(a) > v_s
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
          ) at time zone 'Asia/Kuala_Lumpur') > v_s
      );

    if coalesce(v_tfree, 0) < p_pax then continue; end if;

    -- Free room slots summed across suitable rooms (capacity > 1 allowed).
    select coalesce(sum(greatest(rr.total_slots - rr.booked, 0)), 0) into v_rfree
    from (
      select
        greatest(coalesce(r.total_slots, 1), 1) as total_slots,
        (
          select count(*)
          from public.appointments a
          where a.appointment_date::date between p_date - 1 and p_date + 1
            and a.room_id = r.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_e
            and public.csp_appointment_block_end_at(a) > v_s
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
            ) at time zone 'Asia/Kuala_Lumpur') > v_s
        ) as booked
      from public.rooms r
      where r.outlet_id = p_outlet_id
        and (
          p_room_type is null
          or p_room_type = ''
          or lower(coalesce(r.room_type, '')) = lower(p_room_type)
        )
    ) rr;

    if coalesce(v_rfree, 0) < p_pax then continue; end if;

    start_time := v_s::time;
    end_time := v_treat_end::time;
    therapist_free := v_tfree;
    room_free := v_rfree;
    return next;
  end loop;
end;
$$;

revoke all on function public.get_counter_capacity_slots(
  uuid, date, integer, integer, text, integer, uuid
) from public, anon;
grant execute on function public.get_counter_capacity_slots(
  uuid, date, integer, integer, text, integer, uuid
) to authenticated;
