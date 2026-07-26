-- Fix three related operating-date boundaries:
--   * public overnight slots must be revalidated against the business date
--     that generated the slot, not blindly against start_at's calendar date;
--   * an appointment may end at midnight but must not start at the exact
--     closing boundary;
--   * a partially/stale-seeded therapist_queue_day must rebuild its missing
--     queue rows instead of remaining unreadable for the whole business day.

-- Some production histories do not contain the older 074/075 migration
-- versions even though later booking work is present. Apply their two
-- overnight boundary corrections idempotently before replacing hold creation.
do $migration$
declare
  v_definition text;
  v_original text;
begin
  v_definition := pg_get_functiondef(
    'public.get_public_booking_slots_v2(uuid,date,text)'::regprocedure
  );

  if position('v_close_at timestamp;' in v_definition) = 0 then
    v_original := v_definition;
    v_definition := replace(
      v_definition,
      E'  v_close time;\n',
      E'  v_close time;\n  v_close_at timestamp;\n'
    );
    v_definition := replace(
      v_definition,
      E'    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);\n'
        || E'    v_close := least(v_window.end_time, v_settings.public_close_time, v_business.close_time);\n'
        || E'    if v_close <= v_open then continue; end if;\n',
      E'    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);\n'
        || E'    v_close_at := least(\n'
        || E'      p_date + v_window.end_time\n'
        || E'        + case when v_window.end_time <= v_window.start_time then interval ''1 day'' else interval ''0'' end,\n'
        || E'      p_date + v_settings.public_close_time\n'
        || E'        + case when v_settings.public_close_time <= v_settings.public_open_time then interval ''1 day'' else interval ''0'' end,\n'
        || E'      p_date + v_business.close_time\n'
        || E'        + case when v_business.close_time <= v_business.open_time then interval ''1 day'' else interval ''0'' end\n'
        || E'    );\n'
        || E'    if v_close_at <= p_date + v_open then continue; end if;\n'
    );
    v_definition := replace(
      v_definition,
      ') <= p_date + v_close loop',
      ') <= v_close_at loop'
    );
    v_definition := replace(
      v_definition,
      'p_date + wh.end_time >= v_block_end_local',
      E'p_date + wh.end_time\n'
        || E'              + case when wh.end_time <= wh.start_time then interval ''1 day'' else interval ''0'' end\n'
        || '              >= v_block_end_local'
    );

    if v_definition = v_original
       or position('v_close_at timestamp;' in v_definition) = 0
       or position(') <= v_close_at loop' in v_definition) = 0
       or position('case when wh.end_time <= wh.start_time' in v_definition) = 0 then
      raise exception 'Unable to apply the overnight single-slot boundary repair';
    end if;
    execute v_definition;
  end if;

  if to_regprocedure(
       'public.get_public_booking_group_slots_scan_v1(jsonb,date,boolean)'
     ) is not null then
    v_definition := pg_get_functiondef(
      'public.get_public_booking_group_slots_scan_v1(jsonb,date,boolean)'::regprocedure
    );
    if position(
         'case when wh.end_time <= wh.start_time'
         in v_definition
       ) = 0 then
      v_original := v_definition;
      v_definition := replace(
        v_definition,
        'p_date + wh.end_time >= (v_be at time zone ''Asia/Kuala_Lumpur'')',
        E'p_date + wh.end_time\n'
          || E'              + case when wh.end_time <= wh.start_time then interval ''1 day'' else interval ''0'' end\n'
          || '              >= (v_be at time zone ''Asia/Kuala_Lumpur'')'
      );
      if v_definition = v_original then
        raise exception 'Unable to apply the overnight group-slot boundary repair';
      end if;
      execute v_definition;
    end if;
  end if;
end
$migration$;

create or replace function public.create_public_booking_hold_v2(
  p_catalogue_id uuid,
  p_start_at timestamptz,
  p_therapist_preference text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_therapist_request text default '',
  p_notes text default '',
  p_request_fingerprint text default ''
)
returns table (
  hold_id uuid,
  hold_token uuid,
  hold_expires_at timestamptz,
  total_price numeric,
  duration_minutes integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg public.online_booking_services%rowtype;
  v_service public.services%rowtype;
  v_pref text := lower(coalesce(p_therapist_preference, 'none'));
  v_local_start timestamp := p_start_at at time zone 'Asia/Kuala_Lumpur';
  v_business_date date;
  v_end_at timestamptz;
  v_block_start timestamptz;
  v_block_end timestamptz;
  v_therapist uuid;
  v_room uuid;
begin
  if length(trim(p_customer_name)) < 2
     or length(trim(p_customer_phone)) < 8
     or position('@' in p_customer_email) < 2 then
    raise exception 'Valid customer details are required';
  end if;

  select * into v_cfg
  from public.online_booking_services
  where id = p_catalogue_id;
  if not found then
    raise exception 'Online treatment is unavailable';
  end if;

  select * into v_service
  from public.services
  where id = v_cfg.service_id
    and outlet_id = v_cfg.outlet_id;
  if not found then
    raise exception 'Online treatment is unavailable';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      v_cfg.outlet_id::text || '|' || v_local_start::date::text,
      0
    )
  );
  perform public.expire_stale_booking_holds();

  -- A slot after midnight belongs to the preceding operating date. Check the
  -- calendar date first for ordinary slots, then the preceding date for an
  -- overnight slot. The slot RPC remains the source of truth for whether the
  -- requested timestamp is inside all outlet/public/service windows.
  select candidate.booking_date
  into v_business_date
  from (
    values
      (v_local_start::date, 0),
      (v_local_start::date - 1, 1)
  ) as candidate(booking_date, preference_rank)
  where exists (
    select 1
    from public.get_public_booking_slots_v2(
      v_cfg.id,
      candidate.booking_date,
      v_pref
    ) slot
    where slot.start_at = p_start_at
  )
  order by candidate.preference_rank
  limit 1;

  if v_business_date is null then
    raise exception 'The selected time is no longer available';
  end if;

  if trim(p_request_fingerprint) <> '' and (
    select count(*)
    from public.booking_holds hold
    where hold.request_fingerprint = trim(p_request_fingerprint)
      and hold.created_at > now() - interval '1 hour'
  ) >= 12 then
    raise exception 'Too many booking attempts. Please try again later';
  end if;

  v_end_at := p_start_at
    + make_interval(mins => greatest(v_service.duration, 1));
  v_block_start := p_start_at
    - make_interval(mins => greatest(v_cfg.buffer_before_minutes, 0));
  v_block_end := v_end_at
    + make_interval(mins => greatest(v_cfg.buffer_after_minutes, 0));

  select therapist.id
  into v_therapist
  from public.therapists therapist
  where therapist.outlet_id = v_cfg.outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and (
      v_pref = 'none'
      or lower(coalesce(therapist.gender, '')) = v_pref
    )
    and (
      coalesce(therapist.service_commissions, '{}'::jsonb) = '{}'::jsonb
      or therapist.service_commissions ? v_cfg.service_id::text
    )
    and exists (
      select 1
      from public.therapist_working_hours working_hours
      where working_hours.therapist_id = therapist.id
        and working_hours.day_of_week
              = extract(dow from v_business_date)::integer
        and v_business_date + working_hours.start_time
              <= (v_block_start at time zone 'Asia/Kuala_Lumpur')
        and v_business_date + working_hours.end_time
              + case
                  when working_hours.end_time <= working_hours.start_time
                    then interval '1 day'
                  else interval '0'
                end
              >= (v_block_end at time zone 'Asia/Kuala_Lumpur')
    )
    and not exists (
      select 1
      from public.therapist_unavailability unavailable
      where unavailable.therapist_id = therapist.id
        and unavailable.starts_at < v_block_end
        and unavailable.ends_at > v_block_start
    )
    and not exists (
      select 1
      from public.appointments appointment
      where appointment.therapist_id = therapist.id
        and public.csp_blocks_schedule(appointment.status::text)
        and public.csp_appointment_start_at(appointment)
              < (v_block_end at time zone 'Asia/Kuala_Lumpur')
        and public.csp_appointment_block_end_at(appointment)
              > (v_block_start at time zone 'Asia/Kuala_Lumpur')
    )
    and not exists (
      select 1
      from public.booking_holds hold
      where hold.assigned_therapist_id = therapist.id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
        and hold.start_at
              - make_interval(
                  mins => greatest(coalesce(hold.buffer_before_minutes, 0), 0)
                ) < v_block_end
        and hold.end_at
              + make_interval(
                  mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                ) > v_block_start
    )
  order by therapist.name
  for update of therapist skip locked
  limit 1;

  if v_therapist is null then
    raise exception 'The selected time is no longer available';
  end if;

  select room.id
  into v_room
  from public.rooms room
  join public.online_booking_service_rooms configured_room
    on configured_room.room_id = room.id
  where configured_room.online_booking_service_id = v_cfg.id
    and coalesce(room.is_active, true)
    and coalesce(room.total_slots, 1) >
      (
        select count(*)
        from public.appointments appointment
        where appointment.room_id = room.id
          and public.csp_blocks_schedule(appointment.status::text)
          and public.csp_appointment_start_at(appointment)
                < (v_block_end at time zone 'Asia/Kuala_Lumpur')
          and public.csp_appointment_block_end_at(appointment)
                > (v_block_start at time zone 'Asia/Kuala_Lumpur')
      )
      + (
        select count(*)
        from public.booking_holds hold
        where hold.assigned_room_id = room.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and hold.start_at
                - make_interval(
                    mins => greatest(coalesce(hold.buffer_before_minutes, 0), 0)
                  ) < v_block_end
          and hold.end_at
                + make_interval(
                    mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                  ) > v_block_start
      )
  order by room.name
  for update of room skip locked
  limit 1;

  if v_room is null then
    raise exception 'The selected time is no longer available';
  end if;

  insert into public.booking_holds (
    outlet_id,
    online_booking_service_id,
    customer_name,
    customer_phone,
    customer_email,
    therapist_preference,
    therapist_request,
    assigned_therapist_id,
    assigned_room_id,
    service_items,
    start_at,
    end_at,
    total_amount,
    buffer_before_minutes,
    buffer_after_minutes,
    status,
    expires_at,
    notes,
    request_fingerprint
  ) values (
    v_cfg.outlet_id,
    v_cfg.id,
    trim(p_customer_name),
    trim(p_customer_phone),
    lower(trim(p_customer_email)),
    v_pref,
    left(trim(p_therapist_request), 200),
    v_therapist,
    v_room,
    jsonb_build_array(
      jsonb_build_object(
        'service_id', v_cfg.service_id,
        'public_name', v_cfg.public_name,
        'duration', v_service.duration,
        'display_price', v_cfg.display_price
      )
    ),
    p_start_at,
    v_end_at,
    v_cfg.display_price,
    greatest(v_cfg.buffer_before_minutes, 0),
    greatest(v_cfg.buffer_after_minutes, 0),
    'pending_payment',
    now() + interval '10 minutes',
    left(trim(p_notes), 500),
    left(trim(p_request_fingerprint), 128)
  )
  returning
    booking_holds.id,
    booking_holds.public_token,
    booking_holds.expires_at
  into hold_id, hold_token, hold_expires_at;

  total_price := v_cfg.display_price;
  duration_minutes := v_service.duration;
  return next;
end;
$$;

revoke all on function public.create_public_booking_hold_v2(
  uuid, timestamptz, text, text, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.create_public_booking_hold_v2(
  uuid, timestamptz, text, text, text, text, text, text, text
) to service_role;

-- Validate the actual calendar window represented by appointment_date/time.
-- The previous day's window is considered so a genuinely overnight outlet
-- (for example, closing at 01:00) can accept a 00:30 appointment on its real
-- calendar date. The end boundary is inclusive; the start boundary is not.
create or replace function public.validate_appointment_business_window()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamp;
  v_end timestamp;
  v_valid boolean := false;
begin
  if new.outlet_id is null
     or new.appointment_date is null
     or new.start_time is null
     or new.end_time is null then
    return new;
  end if;

  v_start := public.csp_start_at(new.appointment_date, new.start_time);
  v_end := public.csp_end_at(
    new.appointment_date,
    new.start_time,
    new.end_time
  );

  select exists (
    select 1
    from (
      values
        (new.appointment_date),
        (new.appointment_date - 1)
    ) as candidate(business_date)
    join public.business_hours hours
      on hours.outlet_id = new.outlet_id
     and hours.day_of_week
           = extract(dow from candidate.business_date)::integer
    cross join lateral (
      select
        candidate.business_date + hours.open_time as opens_at,
        candidate.business_date + hours.close_time
          + case
              when hours.close_time <= hours.open_time then interval '1 day'
              else interval '0'
            end as closes_at
    ) bounds
    where not coalesce(hours.is_closed, false)
      and v_start >= bounds.opens_at
      and v_start < bounds.closes_at
      and v_end <= bounds.closes_at
  ) into v_valid;

  if not coalesce(v_valid, false) then
    raise exception using
      errcode = '22023',
      message = 'Appointment time is outside the outlet business hours.';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_appointment_business_window()
  from public, anon, authenticated;

drop trigger if exists appointments_validate_business_window
  on public.appointments;
create trigger appointments_validate_business_window
before insert or update of outlet_id, appointment_date, start_time, end_time
on public.appointments
for each row execute function public.validate_appointment_business_window();

-- A day-state row is not a sufficient seed if its queue rows are absent. This
-- can happen after older daily-seed implementations or an interrupted manual
-- rebuild. Reuse the stored starter when possible; otherwise recalculate it.
create or replace function public.seed_therapist_queue(
  p_outlet_id uuid,
  p_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_starter_id uuid;
begin
  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );

  select day_state.starter_therapist_id
  into v_starter_id
  from public.therapist_queue_day day_state
  where day_state.outlet_id = p_outlet_id
    and day_state.queue_date = p_date;

  if v_starter_id is not null then
    if exists (
      select 1
      from public.therapist_queue queue_row
      where queue_row.outlet_id = p_outlet_id
        and queue_row.queue_date = p_date
    ) then
      return;
    end if;

    begin
      perform public.rebuild_therapist_queue_from_starter(
        p_outlet_id,
        p_date,
        v_starter_id
      );
      return;
    exception
      when sqlstate '22023' then
        delete from public.therapist_queue_day day_state
        where day_state.outlet_id = p_outlet_id
          and day_state.queue_date = p_date;
        v_starter_id := null;
    end;
  end if;

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

  perform public.rebuild_therapist_queue_from_starter(
    p_outlet_id,
    p_date,
    v_starter_id
  );
end;
$$;

revoke all on function public.seed_therapist_queue(uuid, date)
  from public, anon, authenticated;

comment on function public.create_public_booking_hold_v2(
  uuid, timestamptz, text, text, text, text, text, text, text
) is
  'Creates an online hold using the business date that generated an overnight slot.';
comment on function public.validate_appointment_business_window() is
  'Rejects service starts at/after closing while allowing valid previous-day overnight windows.';
comment on function public.seed_therapist_queue(uuid, date) is
  'Seeds or repairs the stored daily therapist queue without consuming a turn.';
