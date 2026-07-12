-- 028/029 introduced a 5-minute after-service cleanup buffer as the default
-- for every service, which was never an intentional per-service business
-- decision -- it just auto-applied everywhere and started blocking
-- legitimate back-to-back bookings (e.g. a 10:00-11:00 slot rejected because
-- the prior service's buffer pushed its occupied window to 11:05).
-- Default the buffer back to 0; staff can still opt a specific service into
-- a cleanup buffer via the "Cleanup buffer" field in Management > Services.
--
-- Existing service rows that are still at the accidental old default of 5 are
-- backfilled to 0. Existing active appointments for today/future are also
-- backfilled to 0 so timetable/booking availability immediately stops showing
-- the inherited cleanup gap. Past appointments are intentionally left as-is so
-- historical data remains an accurate snapshot of what was booked at the time.

alter table public.services
  alter column buffer_after_minutes set default 0;

alter table public.appointments
  alter column buffer_after_minutes set default 0;

alter table public.online_booking_services
  alter column buffer_after_minutes set default 0;

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
    and public.csp_blocks_schedule(status::text)
    and appointment_date >= ((now() at time zone 'Asia/Kuala_Lumpur')::date);

  return new;
end;
$$;

create or replace function public.apply_appointment_service_buffer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select coalesce(buffer_after_minutes, 0)
  into new.buffer_after_minutes
  from public.services
  where id = new.service_id;

  new.buffer_after_minutes := coalesce(new.buffer_after_minutes, 0);
  return new;
end;
$$;

do $$
begin
  -- The updates below only reduce inherited cleanup windows, but older data can
  -- contain duplicate/overlapping active rows that predate the overlap trigger.
  -- Disable that trigger during this data correction so those old rows do not
  -- block the cleanup-buffer reset.
  alter table public.appointments
    disable trigger appointments_prevent_resource_overlap;

  update public.services
  set buffer_after_minutes = 0
  where buffer_after_minutes = 5;

  update public.appointments
  set buffer_after_minutes = 0
  where buffer_after_minutes = 5
    and public.csp_blocks_schedule(status::text)
    and appointment_date >= ((now() at time zone 'Asia/Kuala_Lumpur')::date);

  update public.online_booking_services
  set buffer_after_minutes = 0
  where buffer_after_minutes = 5;

  alter table public.appointments
    enable trigger appointments_prevent_resource_overlap;
exception
  when others then
    alter table public.appointments
      enable trigger appointments_prevent_resource_overlap;
    raise;
end;
$$;

create or replace function public.enforce_online_service_buffer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.buffer_before_minutes := 0;

  select coalesce(buffer_after_minutes, 0)
  into new.buffer_after_minutes
  from public.services
  where id = new.service_id;

  new.buffer_after_minutes := coalesce(new.buffer_after_minutes, 0);
  return new;
end;
$$;
