-- Preserve the reserved booking slot while allowing operational timing to
-- begin at the exact moment payment is confirmed.

alter table public.appointments
  add column if not exists booked_date date,
  add column if not exists booked_start_time time,
  add column if not exists booked_end_time time,
  add column if not exists booked_start_at timestamptz,
  add column if not exists booked_end_at timestamptz,
  add column if not exists actual_started_at timestamptz,
  add column if not exists actual_completed_at timestamptz;

update public.appointments
set booked_date = coalesce(booked_date, appointment_date),
    booked_start_time = coalesce(booked_start_time, start_time),
    booked_end_time = coalesce(booked_end_time, end_time),
    booked_start_at = coalesce(booked_start_at, start_at),
    booked_end_at = coalesce(booked_end_at, end_at)
where booked_date is null
   or booked_start_time is null
   or booked_end_time is null;

