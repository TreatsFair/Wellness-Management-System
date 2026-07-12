-- One canonical cleanup buffer per internal service. The same value is used by
-- staff bookings, walk-ins, resource conflict checks and public online booking.

alter table public.services
  add column if not exists buffer_after_minutes integer not null default 5
    check (buffer_after_minutes between 0 and 240);

alter table public.appointments
  add column if not exists buffer_after_minutes integer not null default 5
    check (buffer_after_minutes between 0 and 240);

update public.services
set buffer_after_minutes = 5
where buffer_after_minutes is null;

update public.appointments appointment
set buffer_after_minutes = coalesce(service.buffer_after_minutes, 5)
from public.services service
where service.id = appointment.service_id;

update public.online_booking_services config
set buffer_after_minutes = service.buffer_after_minutes
from public.services service
where service.id = config.service_id;

create or replace function public.sync_service_buffer_after()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.online_booking_services
  set buffer_after_minutes = new.buffer_after_minutes
  where service_id = new.id;

  update public.appointments
  set buffer_after_minutes = new.buffer_after_minutes
  where service_id = new.id
    and public.csp_blocks_schedule(status::text);

  return new;
end;
$$;

drop trigger if exists services_sync_buffer_after on public.services;
create trigger services_sync_buffer_after
after insert or update of buffer_after_minutes on public.services
for each row execute function public.sync_service_buffer_after();

create or replace function public.apply_appointment_service_buffer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select coalesce(buffer_after_minutes, 5)
  into new.buffer_after_minutes
  from public.services
  where id = new.service_id;

  new.buffer_after_minutes := coalesce(new.buffer_after_minutes, 5);
  return new;
end;
$$;

drop trigger if exists appointments_apply_service_buffer
  on public.appointments;
create trigger appointments_apply_service_buffer
before insert or update of service_id on public.appointments
for each row execute function public.apply_appointment_service_buffer();

create or replace function public.enforce_online_service_buffer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select coalesce(buffer_after_minutes, 5)
  into new.buffer_after_minutes
  from public.services
  where id = new.service_id;

  new.buffer_after_minutes := coalesce(new.buffer_after_minutes, 5);
  return new;
end;
$$;

drop trigger if exists online_services_enforce_buffer
  on public.online_booking_services;
create trigger online_services_enforce_buffer
before insert or update of service_id, buffer_after_minutes
on public.online_booking_services
for each row execute function public.enforce_online_service_buffer();

create or replace function public.csp_appointment_block_end_at(
  a public.appointments
)
returns timestamp
language sql
stable
as $$
  select public.csp_appointment_end_at(a)
    + make_interval(mins => greatest(coalesce(a.buffer_after_minutes, 0), 0));
$$;

create or replace function public.prevent_appointment_resource_overlap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamp;
  v_block_end timestamp;
  v_room_total integer := 1;
  v_room_conflicts integer := 0;
begin
  if not public.csp_blocks_schedule(new.status::text) then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      coalesce(new.outlet_id::text, '') || ':' || new.appointment_date::text,
      0
    )
  );

  v_start := public.csp_appointment_start_at(new);
  v_block_end := public.csp_appointment_end_at(new)
    + make_interval(mins => greatest(coalesce(new.buffer_after_minutes, 0), 0));

  if new.therapist_id is not null and exists (
    select 1
    from public.appointments existing
    where existing.therapist_id = new.therapist_id
      and existing.id is distinct from new.id
      and public.csp_blocks_schedule(existing.status::text)
      and public.csp_appointment_start_at(existing) < v_block_end
      and public.csp_appointment_block_end_at(existing) > v_start
  ) then
    raise exception using
      errcode = '23P01',
      message = 'Therapist is already booked during this service or cleanup buffer.';
  end if;

  if new.therapist_id is not null and exists (
    select 1
    from public.booking_holds hold
    where hold.assigned_therapist_id = new.therapist_id
      and hold.status = 'pending_payment'
      and hold.expires_at > now()
      and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_block_end
      and ((
        hold.end_at
          + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
      ) at time zone 'Asia/Kuala_Lumpur') > v_start
  ) then
    raise exception using
      errcode = '23P01',
      message = 'Therapist is temporarily reserved by an online booking hold.';
  end if;

  if new.room_id is not null then
    select greatest(coalesce(total_slots, 1), 1)
    into v_room_total
    from public.rooms
    where id = new.room_id;

    select count(*)
    into v_room_conflicts
    from public.appointments existing
    where existing.room_id = new.room_id
      and existing.id is distinct from new.id
      and public.csp_blocks_schedule(existing.status::text)
      and public.csp_appointment_start_at(existing) < v_block_end
      and public.csp_appointment_block_end_at(existing) > v_start;

    v_room_conflicts := v_room_conflicts + (
      select count(*)
      from public.booking_holds hold
      where hold.assigned_room_id = new.room_id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
        and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_block_end
        and ((
          hold.end_at
            + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
        ) at time zone 'Asia/Kuala_Lumpur') > v_start
    );

    if v_room_conflicts >= coalesce(v_room_total, 1) then
      raise exception using
        errcode = '23P01',
        message = 'Room or bed capacity is already full during this service or cleanup buffer.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists appointments_prevent_resource_overlap
  on public.appointments;
create trigger appointments_prevent_resource_overlap
before insert or update of appointment_date, start_time, end_time, start_at,
  end_at, therapist_id, room_id, status, buffer_after_minutes
on public.appointments
for each row execute function public.prevent_appointment_resource_overlap();

-- Patch the deployed scheduling functions so therapist and room capacity stay
-- occupied through the service cleanup buffer.
do $$
declare
  v_signature text;
  v_definition text;
  v_patched text;
begin
  foreach v_signature in array array[
    'public.check_booking_availability(date,time without time zone,time without time zone,uuid,uuid,uuid,uuid)',
    'public.get_available_slots(date,uuid,uuid,integer,uuid)',
    'public.check_walkin_availability(date,time without time zone,integer,uuid)',
    'public.get_public_booking_slots_v2(uuid,date,text)',
    'public.create_public_booking_hold_v2(uuid,timestamp with time zone,text,text,text,text,text,text,text)'
  ] loop
    select pg_get_functiondef(v_signature::regprocedure) into v_definition;
    v_patched := replace(
      v_definition,
      'public.csp_appointment_end_at(a)',
      'public.csp_appointment_block_end_at(a)'
    );
    if v_patched <> v_definition then
      execute v_patched;
    end if;
  end loop;
end;
$$;
