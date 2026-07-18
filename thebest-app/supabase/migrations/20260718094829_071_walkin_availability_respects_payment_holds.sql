-- Keep the walk-in resource preview aligned with the final CSP check.
-- Active online-payment and staff-draft holds reserve therapists and room slots
-- until they are paid, cancelled, or expire.

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
security invoker
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at
    + make_interval(mins => greatest(p_duration, 1));
begin
  return query
  select
    t.id,
    t.name,
    case
      when leave_window.ends_at is not null then 'on_leave'
      when busy.free_at is null then 'free_now'
      else 'busy'
    end,
    coalesce(leave_window.ends_at, busy.bookable_free_at)::time,
    case
      when leave_window.ends_at is not null then 0
      when busy.bookable_free_at is null then 0
      else greatest(
        ceil(
          extract(epoch from (busy.bookable_free_at - v_start_at)) / 60
        )::integer,
        0
      )
    end
  from public.therapists t
  left join lateral (
    select
      raw.free_at,
      case
        when raw.free_at is null then null
        when raw.free_at = date_trunc('minute', raw.free_at)
          then raw.free_at
        else date_trunc('minute', raw.free_at) + interval '1 minute'
      end as bookable_free_at
    from (
      select max(conflicts.ends_at) as free_at
      from (
        select public.csp_appointment_end_at(a) as ends_at
        from public.appointments a
        where a.appointment_date::date between p_today - 1 and p_today + 1
          and a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_end_at
          and public.csp_appointment_end_at(a) > v_start_at

        union all

        select h.end_at at time zone 'Asia/Kuala_Lumpur'
        from public.booking_holds h
        where h.assigned_therapist_id = t.id
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
          and (h.end_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
      ) conflicts
    ) raw
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
    busy.bookable_free_at nulls first,
    t.name;
end;
$$;

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
security invoker
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at
    + make_interval(mins => greatest(p_duration, 1));
  v_room_total integer := 1;
  v_room_booked integer := 0;
  v_free_at timestamp;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  select count(*), max(conflicts.ends_at)
  into v_room_booked, v_free_at
  from (
    select public.csp_appointment_end_at(a) as ends_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.room_id = p_room_id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_end_at(a) > v_start_at

    union all

    select h.end_at at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    where h.assigned_room_id = p_room_id
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
      and (h.end_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
  ) conflicts;

  free_slots := greatest(v_room_total - v_room_booked, 0);
  total_slots := v_room_total;
  available_now := free_slots > 0;
  free_at := v_free_at::time;
  return next;
end;
$$;

revoke all on function public.get_walkin_therapist_availability(
  date, time, integer
) from public, anon;
grant execute on function public.get_walkin_therapist_availability(
  date, time, integer
) to authenticated;

revoke all on function public.get_walkin_room_availability(
  date, time, integer, uuid
) from public, anon;
grant execute on function public.get_walkin_room_availability(
  date, time, integer, uuid
) to authenticated;
