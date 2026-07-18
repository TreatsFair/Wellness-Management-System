create or replace function public.enforce_no_future_service_progress()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_scheduled_start timestamp;
begin
  v_scheduled_start := coalesce(
    new.start_at,
    new.appointment_date + new.start_time
  );

  if new.status in ('in_progress', 'completed')
     and v_scheduled_start - interval '30 minutes' > (now() at time zone 'Asia/Kuala_Lumpur') then
    raise exception using
      errcode = '23514',
      message = 'Cannot start or complete a service more than 30 minutes before its scheduled time.';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_no_future_progress on public.appointments;
create trigger appointments_no_future_progress
before insert or update of status on public.appointments
for each row execute function public.enforce_no_future_service_progress();;
