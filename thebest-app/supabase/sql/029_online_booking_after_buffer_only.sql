-- Online booking uses one cleanup buffer only: after the service.
-- The old before-buffer column is kept for compatibility with deployed
-- functions and existing rows, but is forced to zero and no longer admin-facing.

update public.online_booking_services
set buffer_before_minutes = 0;

update public.booking_holds
set buffer_before_minutes = 0
where expires_at > now();

create or replace function public.enforce_online_service_buffer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.buffer_before_minutes := 0;

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
before insert or update of service_id, buffer_before_minutes, buffer_after_minutes
on public.online_booking_services
for each row execute function public.enforce_online_service_buffer();
