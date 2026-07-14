-- Server-side backstop for the "future booking started -> invisible in_progress"
-- bug. The Flutter UI already blocks Check-in unless the appointment is today
-- and at/after its start time (appointment_screen.dart canAdvance /
-- isServiceStartDue), but the paid-booking Start path writes status directly via
-- SupabaseTableService.update (not only the checkout RPC), so a stale screen or
-- any direct call could still flip a future-dated appointment to in_progress and
-- make it disappear from today's timetable. This enforces the invariant at the
-- table for ALL write paths: a service cannot be in_progress or completed while
-- its scheduled date is still in the future (Asia/Kuala_Lumpur).
--
-- Walk-ins are always created for the current day, so this never blocks them.
-- Reschedule to a future date stays allowed (status stays confirmed).

-- Early check-in window: staff may start a service up to 30 minutes before its
-- scheduled time (an early-arriving customer), but not earlier. This keeps the
-- server guard in step with the UI gate (isServiceStartDue), which uses the
-- same 30-minute lead.
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
for each row execute function public.enforce_no_future_service_progress();

-- Repair the one row corrupted before the fix existed: booked for today 16:30
-- but actual_started_at was set yesterday while it was still a future booking.
-- Reset to confirmed and clear the bogus service timestamps; keep it paid.
update public.appointments
set status = 'confirmed',
    actual_started_at = null,
    actual_completed_at = null,
    updated_at = now()
where id = '451faaa1-15b1-4fd1-ad92-cb4a5a0e4adb'
  and status = 'in_progress'
  and actual_started_at is not null
  and (actual_started_at at time zone 'Asia/Kuala_Lumpur')::date < appointment_date;
