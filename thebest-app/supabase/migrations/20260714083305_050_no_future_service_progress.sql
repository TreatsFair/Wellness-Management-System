create or replace function public.enforce_no_future_service_progress()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status in ('in_progress', 'completed')
     and new.appointment_date > (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using
      errcode = '23514',
      message = 'Cannot start or complete a service before its scheduled date.';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_no_future_progress on public.appointments;
create trigger appointments_no_future_progress
before insert or update of status on public.appointments
for each row execute function public.enforce_no_future_service_progress();

update public.appointments
set status = 'confirmed',
    actual_started_at = null,
    actual_completed_at = null,
    updated_at = now()
where id = '451faaa1-15b1-4fd1-ad92-cb4a5a0e4adb'
  and status = 'in_progress'
  and actual_started_at is not null
  and (actual_started_at at time zone 'Asia/Kuala_Lumpur')::date < appointment_date;;
