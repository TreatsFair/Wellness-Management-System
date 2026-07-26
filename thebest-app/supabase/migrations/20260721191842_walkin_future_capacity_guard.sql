-- Prevent a walk-in from consuming the therapist capacity required by an
-- upcoming appointment or active booking hold. Existing therapist/room overlap
-- checks still validate the selected walk-in itself; this guard protects the
-- outlet-level capacity that future appointments rely on.

create or replace function public.check_walkin_protects_future(
  p_outlet_id uuid,
  p_start timestamp without time zone,
  p_duration integer,
  p_therapist_id uuid,
  p_exclude_appointment_id uuid default null
)
returns boolean
language plpgsql
stable
security invoker
set search_path to 'public'
as $$
declare
  v_end timestamp without time zone;
  v_checkpoint timestamp without time zone;
  v_scheduled integer;
  v_demand integer;
  v_candidate_reduces_capacity integer;
begin
  if p_outlet_id is null
     or p_start is null
     or coalesce(p_duration, 0) < 1
     or p_therapist_id is null then
    raise exception using
      errcode = '22023',
      message = 'Outlet, start, positive duration, and therapist are required.';
  end if;

  v_end := p_start + make_interval(mins => p_duration);

  if not exists (
    select 1
    from public.therapists therapist
    where therapist.id = p_therapist_id
      and therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
  ) then
    return false;
  end if;

  for v_checkpoint in
    select checkpoint
    from (
      select public.csp_appointment_start_at(appointment) as checkpoint
      from public.appointments appointment
      where appointment.outlet_id = p_outlet_id
        and appointment.id is distinct from p_exclude_appointment_id
        and appointment.type::text = 'appointment'
        and public.csp_blocks_schedule(appointment.status::text)
        and public.csp_appointment_start_at(appointment) >= p_start
        and public.csp_appointment_start_at(appointment) < v_end

      union

      select hold.start_at at time zone 'Asia/Kuala_Lumpur'
      from public.booking_holds hold
      where hold.outlet_id = p_outlet_id
        and hold.assigned_therapist_id is not null
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
        and coalesce(hold.hold_kind, '') <> 'staff_walkin_draft'
        and (hold.start_at at time zone 'Asia/Kuala_Lumpur') >= p_start
        and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end
    ) upcoming
    where checkpoint >= now() at time zone 'Asia/Kuala_Lumpur'
    order by checkpoint
  loop
    select count(*)
    into v_scheduled
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = therapist.id
          and (
            (
              hours.day_of_week = extract(dow from v_checkpoint::date)::integer
              and v_checkpoint::date + hours.start_time <= v_checkpoint
              and v_checkpoint::date + hours.end_time
                + case
                    when hours.end_time <= hours.start_time then interval '1 day'
                    else interval '0'
                  end > v_checkpoint
            )
            or (
              hours.end_time <= hours.start_time
              and hours.day_of_week =
                extract(dow from v_checkpoint::date - 1)::integer
              and (v_checkpoint::date - 1) + hours.start_time <= v_checkpoint
              and (v_checkpoint::date - 1) + hours.end_time
                + interval '1 day' > v_checkpoint
            )
          )
      )
      and not exists (
        select 1
        from public.therapist_unavailability unavailable
        where unavailable.therapist_id = therapist.id
          and (unavailable.starts_at at time zone 'Asia/Kuala_Lumpur')
            <= v_checkpoint
          and (unavailable.ends_at at time zone 'Asia/Kuala_Lumpur')
            > v_checkpoint
      );

    select
      (
        select count(*)
        from public.appointments appointment
        where appointment.outlet_id = p_outlet_id
          and appointment.id is distinct from p_exclude_appointment_id
          and public.csp_blocks_schedule(appointment.status::text)
          and public.csp_appointment_start_at(appointment) <= v_checkpoint
          and public.csp_appointment_block_end_at(appointment) > v_checkpoint
      )
      + (
        select count(*)
        from public.booking_holds hold
        where hold.outlet_id = p_outlet_id
          and hold.assigned_therapist_id is not null
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and coalesce(hold.hold_kind, '') <> 'staff_walkin_draft'
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur') <= v_checkpoint
          and (
            hold.end_at
              + make_interval(
                  mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                )
          ) at time zone 'Asia/Kuala_Lumpur' > v_checkpoint
      )
    into v_demand;

    select case when exists (
      select 1
      from public.therapist_working_hours hours
      where hours.therapist_id = p_therapist_id
        and (
          (
            hours.day_of_week = extract(dow from v_checkpoint::date)::integer
            and v_checkpoint::date + hours.start_time <= v_checkpoint
            and v_checkpoint::date + hours.end_time
              + case
                  when hours.end_time <= hours.start_time then interval '1 day'
                  else interval '0'
                end > v_checkpoint
          )
          or (
            hours.end_time <= hours.start_time
            and hours.day_of_week =
              extract(dow from v_checkpoint::date - 1)::integer
            and (v_checkpoint::date - 1) + hours.start_time <= v_checkpoint
            and (v_checkpoint::date - 1) + hours.end_time
              + interval '1 day' > v_checkpoint
          )
        )
    ) then 1 else 0 end
    into v_candidate_reduces_capacity;

    if v_scheduled < v_demand + v_candidate_reduces_capacity then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

revoke all on function public.check_walkin_protects_future(
  uuid, timestamp without time zone, integer, uuid, uuid
) from public, anon;
grant execute on function public.check_walkin_protects_future(
  uuid, timestamp without time zone, integer, uuid, uuid
) to authenticated;

create or replace function public.enforce_walkin_future_capacity()
returns trigger
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  v_start timestamp without time zone;
  v_block_end timestamp without time zone;
  v_duration integer;
begin
  if new.type::text <> 'walkin'
     or not public.csp_blocks_schedule(new.status::text) then
    return new;
  end if;

  v_start := public.csp_appointment_start_at(new);
  v_block_end := public.csp_appointment_block_end_at(new);
  v_duration := greatest(
    ceil(extract(epoch from (v_block_end - v_start)) / 60.0)::integer,
    1
  );

  perform pg_advisory_xact_lock(
    hashtextextended(
      'walkin-capacity:' || new.outlet_id::text || ':' || new.appointment_date::text,
      0
    )
  );

  if not public.check_walkin_protects_future(
    new.outlet_id,
    v_start,
    v_duration,
    new.therapist_id,
    new.id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'This walk-in would leave too little therapist capacity for an upcoming appointment. Choose another therapist or a later start.';
  end if;

  return new;
end;
$$;

drop trigger if exists appointments_walkin_future_capacity_guard
  on public.appointments;
create trigger appointments_walkin_future_capacity_guard
before insert on public.appointments
for each row
execute function public.enforce_walkin_future_capacity();

revoke all on function public.enforce_walkin_future_capacity()
  from public, anon, authenticated;
