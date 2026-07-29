-- Therapists added after a daily queue has been seeded must join today's
-- running order without resetting positions or consumed turns. queue_position
-- is already rotated to the tail by record_therapist_queue_turn_consumption(),
-- so it is the authoritative live order.

do $preflight$
begin
  if to_regprocedure('public.seed_therapist_queue(uuid,date)') is null
     or to_regprocedure(
       'public.get_therapist_queue(uuid,date,time without time zone,integer)'
     ) is null
     or to_regprocedure(
       'public.rebuild_therapist_queue_from_starter(uuid,date,uuid)'
     ) is null then
    raise exception '125 requires the deployed daily therapist queue functions';
  end if;
end;
$preflight$;

create or replace function public.seed_therapist_queue(
  p_outlet_id uuid,
  p_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_starter_id uuid;
  v_max_position integer;
begin
  if p_outlet_id is null or p_date is null then
    return;
  end if;

  -- All seed, consume and manual-reorder paths use this same outlet/day lock.
  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );

  select day_state.starter_therapist_id
  into v_starter_id
  from public.therapist_queue_day day_state
  where day_state.outlet_id = p_outlet_id
    and day_state.queue_date = p_date;

  -- Preserve historical queue rows if day metadata is ever missing. Position
  -- one is the least surprising recovered starter and no live state is reset.
  if v_starter_id is null and exists (
    select 1
    from public.therapist_queue queue_row
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
  ) then
    select queue_row.therapist_id
    into v_starter_id
    from public.therapist_queue queue_row
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
    order by queue_row.queue_position, queue_row.therapist_id
    limit 1;

    insert into public.therapist_queue_day (
      outlet_id,
      queue_date,
      starter_therapist_id
    ) values (
      p_outlet_id,
      p_date,
      v_starter_id
    )
    on conflict (outlet_id, queue_date) do nothing;
  end if;

  -- A genuinely new day still uses the established starter/rebuild behavior.
  if not exists (
    select 1
    from public.therapist_queue queue_row
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
  ) then
    if v_starter_id is null then
      v_starter_id := public.automatic_therapist_queue_starter(
        p_outlet_id,
        p_date
      );
      if v_starter_id is null then
        return;
      end if;

      insert into public.therapist_queue_day (
        outlet_id,
        queue_date,
        starter_therapist_id
      ) values (
        p_outlet_id,
        p_date,
        v_starter_id
      )
      on conflict (outlet_id, queue_date) do update
      set starter_therapist_id = excluded.starter_therapist_id;
    end if;

    begin
      perform public.rebuild_therapist_queue_from_starter(
        p_outlet_id,
        p_date,
        v_starter_id
      );
    exception
      when sqlstate '22023' then
        v_starter_id := public.automatic_therapist_queue_starter(
          p_outlet_id,
          p_date
        );
        if v_starter_id is null then
          return;
        end if;
        update public.therapist_queue_day
        set starter_therapist_id = v_starter_id
        where outlet_id = p_outlet_id
          and queue_date = p_date;
        perform public.rebuild_therapist_queue_from_starter(
          p_outlet_id,
          p_date,
          v_starter_id
        );
    end;
    return;
  end if;

  select coalesce(max(queue_row.queue_position), 0)
  into v_max_position
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date;

  -- Mid-day joiners append after the current effective order. Existing queue
  -- rows are never updated, so consumed timestamps and staff reorders survive.
  with missing as (
    select
      therapist.id,
      row_number() over (
        order by
          therapist.display_order nulls last,
          therapist.name,
          therapist.id
      )::integer as append_offset
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and exists (
        select 1
        from public.therapist_working_hours working_hours
        join public.business_hours outlet_hours
          on outlet_hours.outlet_id = therapist.outlet_id
         and outlet_hours.day_of_week = working_hours.day_of_week
         and not coalesce(outlet_hours.is_closed, false)
        where working_hours.therapist_id = therapist.id
          and working_hours.day_of_week =
              extract(dow from p_date)::integer
      )
      and not exists (
        select 1
        from public.therapist_queue existing
        where existing.outlet_id = p_outlet_id
          and existing.queue_date = p_date
          and existing.therapist_id = therapist.id
      )
  )
  insert into public.therapist_queue (
    outlet_id,
    queue_date,
    therapist_id,
    queue_position
  )
  select
    p_outlet_id,
    p_date,
    missing.id,
    v_max_position + missing.append_offset
  from missing
  order by missing.append_offset
  on conflict (outlet_id, queue_date, therapist_id) do nothing;
end;
$function$;

revoke all on function public.seed_therapist_queue(uuid, date)
  from public, anon, authenticated, service_role;

create or replace function public.get_therapist_queue(
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
as $function$
begin
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  return query
  with raw_availability as (
    select a.therapist_id, a.status, a.free_at, a.free_in_minutes
    from public.get_walkin_therapist_availability(
      p_date,
      p_now_time,
      p_duration
    ) a
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
            and appointment.actual_started_at <=
                ((p_date + p_now_time) at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'busy_now'
        when exists (
          select 1
          from public.appointments appointment
          where appointment.therapist_id = raw.therapist_id
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment)
                  < p_date + p_now_time
                      + make_interval(mins => greatest(p_duration, 1))
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'reserved'
        else 'busy'
      end status,
      raw.free_at,
      reservation.reservation_start_at,
      reservation.reservation_end_at,
      raw.free_in_minutes
    from raw_availability raw
    left join lateral (
      select
        public.csp_appointment_start_at(appointment)::time,
        public.csp_appointment_end_at(appointment)::time
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
    ) reservation(
      reservation_start_at,
      reservation_end_at
    ) on raw.status <> 'free_now'
  ),
  ordered as (
    select
      queue_row.therapist_id,
      therapist.name,
      therapist.gender,
      queue_row.queue_position,
      availability.status,
      availability.free_at,
      availability.reservation_start_at,
      availability.reservation_end_at,
      availability.free_in_minutes,
      row_number() over (
        order by queue_row.queue_position, queue_row.therapist_id
      ) rotation_rank
    from public.therapist_queue queue_row
    join public.therapists therapist
      on therapist.id = queue_row.therapist_id
    join availability
      on availability.therapist_id = queue_row.therapist_id
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
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
    false,
    ordered.rotation_rank = (
      select min(candidate.rotation_rank)
      from ordered candidate
      where candidate.status = 'free_now'
    ),
    ordered.rotation_rank
  from ordered
  order by ordered.rotation_rank;
end;
$function$;

revoke all on function public.get_therapist_queue(
  uuid, date, time, integer
) from public, anon;
grant execute on function public.get_therapist_queue(
  uuid, date, time, integer
) to authenticated;

comment on function public.seed_therapist_queue(uuid, date) is
  'Seeds a new daily queue or appends newly active scheduled therapists to the tail without resetting live rotation.';
comment on function public.get_therapist_queue(uuid, date, time, integer) is
  'Returns the duration-aware live therapist queue in authoritative queue_position order.';
