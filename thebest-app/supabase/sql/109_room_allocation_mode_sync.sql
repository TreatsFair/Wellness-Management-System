-- Keep room-slot behavior consistent across outlets while leaving each outlet's
-- own room names and capacities independently configurable.

alter table public.rooms
  drop constraint if exists rooms_specific_allocation_body_only_check;
alter table public.rooms
  add constraint rooms_specific_allocation_body_only_check
  check (
    allocation_mode = 'capacity'
    or lower(coalesce(room_type::text, '')) = 'body_room'
  );

create or replace function public.sync_room_units_for_zone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform pg_advisory_xact_lock(
    hashtextextended('room-unit-sync:' || new.id::text, 0)
  );

  if new.allocation_mode = 'specific_room'
     and coalesce(new.is_active, true) then
    if exists (
      select 1
      from public.room_units unit
      where unit.zone_id = new.id
        and unit.unit_number > greatest(coalesce(new.total_slots, 1), 1)
        and (
          exists (
            select 1
            from public.appointments appointment
            where appointment.room_unit_id = unit.id
              and appointment.appointment_date >= v_today
              and public.csp_blocks_schedule(appointment.status::text)
          )
          or exists (
            select 1
            from public.booking_holds hold
            where hold.assigned_room_unit_id = unit.id
              and hold.status = 'pending_payment'
              and hold.expires_at > now()
          )
        )
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'Cannot reduce specific rooms while a removed room has an active or future booking.';
    end if;

    insert into public.room_units (
      zone_id,
      outlet_id,
      name,
      unit_number,
      is_active
    )
    select
      new.id,
      new.outlet_id,
      'Room ' || unit_number,
      unit_number,
      true
    from generate_series(
      1,
      greatest(coalesce(new.total_slots, 1), 1)
    ) unit_number
    on conflict (zone_id, unit_number) do update
    set outlet_id = excluded.outlet_id,
        is_active = true,
        updated_at = now();

    update public.room_units
    set is_active = false,
        updated_at = now()
    where zone_id = new.id
      and unit_number > greatest(coalesce(new.total_slots, 1), 1)
      and is_active;
  else
    update public.room_units
    set is_active = false,
        updated_at = now()
    where zone_id = new.id
      and is_active;
  end if;

  return new;
end;
$$;

drop trigger if exists rooms_sync_room_units on public.rooms;
create trigger rooms_sync_room_units
after insert or update of allocation_mode, total_slots, outlet_id, room_type,
  is_active
on public.rooms
for each row execute function public.sync_room_units_for_zone();

revoke all on function public.sync_room_units_for_zone() from public, anon, authenticated;

-- Seed or reconcile the existing configuration once. Capacity-only zones keep
-- no active unit rows; specific-room zones get exactly one unit per slot.
update public.rooms
set allocation_mode = allocation_mode;

-- Migration 104's per-pax allocator correctly separates body-room and foot-zone
-- requirements, but it also considered inactive rooms. Preserve its therapist
-- selection and reassign each result against active rooms only.
alter function public.allocate_provisional_slots(uuid, date, time, jsonb, uuid)
  rename to allocate_provisional_slots_unfiltered_rooms_legacy;

revoke all on function public.allocate_provisional_slots_unfiltered_rooms_legacy(
  uuid, date, time, jsonb, uuid
) from public, anon, authenticated;

create or replace function public.allocate_provisional_slots(
  p_outlet_id uuid,
  p_date date,
  p_start_time time,
  p_requirements jsonb,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  pax_index integer,
  therapist_id uuid,
  room_id uuid,
  end_time time
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_requirement jsonb;
  v_pax_index integer;
  v_duration integer;
  v_buffer integer;
  v_room_type text;
  v_reserved_end timestamp;
  v_legacy_results jsonb;
  v_legacy_result jsonb;
  v_room_id uuid;
  v_results jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'pax_index', allocation.pax_index,
        'therapist_id', allocation.therapist_id,
        'end_time', allocation.end_time
      )
      order by allocation.pax_index
    ),
    '[]'::jsonb
  )
  into v_legacy_results
  from public.allocate_provisional_slots_unfiltered_rooms_legacy(
    p_outlet_id,
    p_date,
    p_start_time,
    p_requirements,
    p_exclude_appointment_group_id
  ) allocation;

  if jsonb_array_length(v_legacy_results)
      <> jsonb_array_length(p_requirements) then
    return;
  end if;

  for v_requirement in
    select requirement
    from jsonb_array_elements(p_requirements) requirement
    order by
      coalesce((requirement ->> 'duration_minutes')::integer, 0)
        + greatest(
            coalesce((requirement ->> 'buffer_after_minutes')::integer, 0),
            0
          ) desc,
      (requirement ->> 'pax_index')::integer
  loop
    v_pax_index := (v_requirement ->> 'pax_index')::integer;
    v_duration := (v_requirement ->> 'duration_minutes')::integer;
    v_buffer := greatest(
      coalesce((v_requirement ->> 'buffer_after_minutes')::integer, 0),
      0
    );
    v_room_type := lower(trim(v_requirement ->> 'room_type'));
    v_reserved_end := v_start
      + make_interval(mins => v_duration + v_buffer);

    select result
    into v_legacy_result
    from jsonb_array_elements(v_legacy_results) result
    where (result ->> 'pax_index')::integer = v_pax_index
    limit 1;

    v_room_id := null;
    select room.id
    into v_room_id
    from public.rooms room
    where room.outlet_id = p_outlet_id
      and coalesce(room.is_active, true)
      and lower(coalesce(room.room_type::text, '')) = v_room_type
      and (
        (
          select count(*)
          from public.appointments appointment
          where appointment.appointment_date::date
                between p_date - 1 and p_date + 1
            and appointment.room_id = room.id
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment) < v_reserved_end
            and public.csp_appointment_block_end_at(appointment) > v_start
            and (
              p_exclude_appointment_group_id is null
              or appointment.appointment_group_id
                   is distinct from p_exclude_appointment_group_id
            )
        )
        + (
          select count(*)
          from public.booking_holds hold
          where hold.assigned_room_id = room.id
            and hold.status = 'pending_payment'
            and hold.expires_at > now()
            and (hold.start_at at time zone 'Asia/Kuala_Lumpur')
                < v_reserved_end
            and (
              hold.end_at
                + make_interval(
                    mins => greatest(
                      coalesce(hold.buffer_after_minutes, 0),
                      0
                    )
                  )
            ) at time zone 'Asia/Kuala_Lumpur' > v_start
        )
        + (
          select count(*)
          from jsonb_array_elements(v_results) assigned
          where (assigned ->> 'room_id')::uuid = room.id
        )
      ) < greatest(coalesce(room.total_slots, 1), 1)
    order by room.name, room.id
    limit 1;

    if v_room_id is null then
      return;
    end if;

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'pax_index', v_pax_index,
        'therapist_id', v_legacy_result ->> 'therapist_id',
        'room_id', v_room_id,
        'end_time', v_legacy_result ->> 'end_time'
      )
    );
  end loop;

  return query
  select
    (assigned ->> 'pax_index')::integer,
    (assigned ->> 'therapist_id')::uuid,
    (assigned ->> 'room_id')::uuid,
    (assigned ->> 'end_time')::time
  from jsonb_array_elements(v_results) assigned
  order by (assigned ->> 'pax_index')::integer;
end;
$$;

revoke all on function public.allocate_provisional_slots(
  uuid, date, time, jsonb, uuid
) from public, anon;
grant execute on function public.allocate_provisional_slots(
  uuid, date, time, jsonb, uuid
) to authenticated;
