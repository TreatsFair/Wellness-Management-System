-- Expose the actual future appointment window that blocks each therapist so
-- counter UIs can show "Reserved 11:30 PM–12:30 AM" instead of an ambiguous
-- provisional label or end-time-only message. Assignment state remains an
-- internal scheduling distinction and queue order is unchanged.

drop function if exists public.get_therapist_queue(uuid, date, time, integer);

create function public.get_therapist_queue(
  p_outlet_id uuid,
  p_date date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid,
  name text,
  gender text,
  queue_position integer,
  status text,
  free_at time,
  reservation_start_at time,
  reservation_end_at time,
  free_in_minutes integer,
  protected_turn_owed boolean,
  is_recommended boolean,
  rotation_rank bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  return query
  with raw_availability as (
    select availability.therapist_id,
           availability.status,
           availability.free_at,
           availability.free_in_minutes
    from public.get_walkin_therapist_availability(
      p_date,
      p_now_time,
      p_duration
    ) availability
  ),
  availability as (
    select
      raw.therapist_id,
      case
        when raw.status = 'free_now' then 'free_now'
        when exists (
          select 1
          from public.appointments appointment
          where appointment.therapist_id = raw.therapist_id
            and appointment.actual_started_at is not null
            and appointment.actual_completed_at is null
            and public.csp_blocks_schedule(appointment.status::text)
            and appointment.actual_started_at
                  <= ((p_date + p_now_time) at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'busy_now'
        when exists (
          select 1
          from public.appointments appointment
          where appointment.therapist_id = raw.therapist_id
            and appointment.therapist_assignment_state = 'confirmed'
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment)
                  < p_date + p_now_time
                      + make_interval(mins => greatest(p_duration, 1))
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'reserved'
        else 'tentative_hold'
      end as status,
      raw.free_at,
      reservation.reservation_start_at,
      reservation.reservation_end_at,
      raw.free_in_minutes
    from raw_availability raw
    left join lateral (
      select
        public.csp_appointment_start_at(appointment)::time
          as reservation_start_at,
        public.csp_appointment_end_at(appointment)::time
          as reservation_end_at
      from public.appointments appointment
      where appointment.outlet_id = p_outlet_id
        and appointment.therapist_id = raw.therapist_id
        and appointment.actual_started_at is null
        and public.csp_blocks_schedule(appointment.status::text)
        and public.csp_appointment_start_at(appointment)
              < p_date + p_now_time
                  + make_interval(mins => greatest(p_duration, 1))
        and public.csp_appointment_block_end_at(appointment)
              > p_date + p_now_time
      order by public.csp_appointment_start_at(appointment), appointment.id
      limit 1
    ) reservation on raw.status <> 'free_now'
  ),
  ordered as (
    select
      queue.therapist_id,
      therapist.name,
      therapist.gender,
      queue.queue_position,
      availability.status,
      availability.free_at,
      availability.reservation_start_at,
      availability.reservation_end_at,
      availability.free_in_minutes,
      queue.protected_turn_owed,
      row_number() over (
        order by
          queue.protected_turn_owed desc,
          queue.turn_consumed_at nulls first,
          queue.queue_position
      ) as rotation_rank
    from public.therapist_queue queue
    join public.therapists therapist on therapist.id = queue.therapist_id
    join availability on availability.therapist_id = queue.therapist_id
    where queue.outlet_id = p_outlet_id
      and queue.queue_date = p_date
  )
  select
    ordered.therapist_id,
    ordered.name,
    ordered.gender,
    ordered.queue_position,
    ordered.status,
    ordered.free_at,
    ordered.reservation_start_at,
    ordered.reservation_end_at,
    ordered.free_in_minutes,
    ordered.protected_turn_owed,
    ordered.rotation_rank = (
      select min(candidate.rotation_rank)
      from ordered candidate
      where candidate.status = 'free_now'
    ) as is_recommended,
    ordered.rotation_rank
  from ordered
  order by ordered.rotation_rank;
end;
$$;

revoke all on function public.get_therapist_queue(uuid, date, time, integer)
  from public, anon;
grant execute on function public.get_therapist_queue(uuid, date, time, integer)
  to authenticated;

comment on function public.get_therapist_queue(uuid, date, time, integer) is
  'Live queue with actual nearest future reservation windows for counter UI.';
