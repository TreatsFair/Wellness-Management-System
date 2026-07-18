alter table public.services
  alter column buffer_after_minutes set default 0;

alter table public.appointments
  alter column buffer_after_minutes set default 0;

alter table public.online_booking_services
  alter column buffer_after_minutes set default 0;

update public.online_booking_services
set buffer_after_minutes = 0
where buffer_after_minutes = 5;

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
;
