-- Phase 6B.1 — Priority 2: separate check-in tracking from service start.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726070717.
-- This file is the verbatim SQL that was applied.
--
-- Lifecycle decision recorded by the product owner 2026-07-26:
--   booked_start_at / booked_start_time  original scheduled start
--   booked_end_at   / booked_end_time    original scheduled end
--   checked_in_at                        when the customer checks in
--   actual_started_at                    when the therapist starts the service
--   start_at / end_at                    active operational blocking window
--
-- A checked-in appointment may remain:
--     status = confirmed, checked_in_at IS NOT NULL, actual_started_at IS NULL
-- A started appointment must be:
--     status = in_progress, actual_started_at IS NOT NULL
-- For a walk-in that starts immediately the two timestamps may be equal.
--
-- No new appointment status is introduced.
--
-- VERIFIED transactionally before applying: a row created at 17:06-17:09 and
-- checked in at 15:06 kept booked_* = 17:06-17:09, checked_in_at = 15:06,
-- actual_started_at NULL, status confirmed, operational window unchanged.
--
-- ROLLBACK:
--   drop trigger if exists appointments_set_booked_snapshot on public.appointments;
--   drop function if exists public.set_appointment_booked_snapshot();
--   alter table public.appointments
--     drop column if exists checked_in_by,
--     drop column if exists checked_in_at;
--   Safe while nothing reads the columns. Dropping them discards any recorded
--   check-in times permanently.

alter table public.appointments
  add column if not exists checked_in_at timestamptz,
  add column if not exists checked_in_by uuid;

do $fk$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.appointments'::regclass
      and conname = 'appointments_checked_in_by_fkey'
  ) then
    alter table public.appointments
      add constraint appointments_checked_in_by_fkey
      foreign key (checked_in_by) references public.profiles(id) on delete set null;
  end if;
end;
$fk$;

comment on column public.appointments.checked_in_at is
  'When the customer physically checked in. Independent of actual_started_at: an appointment may be checked in (status still confirmed) long before the therapist starts the service. Never overwrites booked_* and never moves the operational start_at/end_at window.';

comment on column public.appointments.checked_in_by is
  'Staff profile that recorded the check-in. NULL for rows created before check-in tracking existed.';

comment on column public.appointments.booked_start_at is
  'Original SCHEDULED start. Frozen at creation and never rewritten by check-in or service start. Display "Scheduled" from coalesce(booked_start_at, start_at).';

comment on column public.appointments.booked_end_at is
  'Original SCHEDULED end. Frozen at creation and never rewritten by check-in or service start.';

comment on column public.appointments.actual_started_at is
  'When the therapist actually began the service. Setting it moves the operational start_at/end_at window (see project_appointment_end_on_actual_start) but never booked_*.';

comment on column public.appointments.start_at is
  'ACTIVE OPERATIONAL resource-blocking window start. Equals the scheduled start until the service starts, then the actual start. This is NOT the scheduled time -- do not display it as such.';

-- Populate booked_* at INSERT. 130 of 277 existing rows had booked_start_time
-- NULL because booked_* was only ever backfilled lazily at service start; that
-- made the scheduled truth destroyable (122i had to recover it from OLD).
--
-- INSERT-only by design so check-in and service start can never overwrite the
-- scheduled snapshot.
--
-- Existing rows are deliberately NOT backfilled: for an already-started row,
-- appointment_date/start_time now hold the OPERATIONAL window, so backfilling
-- from them would record the actual start as the scheduled time.

create or replace function public.set_appointment_booked_snapshot()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if new.appointment_date is null
     or new.start_time is null
     or new.end_time is null then
    return new;
  end if;

  new.booked_date := coalesce(new.booked_date, new.appointment_date);
  new.booked_start_time := coalesce(new.booked_start_time, new.start_time);
  new.booked_end_time := coalesce(new.booked_end_time, new.end_time);
  new.booked_start_at := coalesce(
    new.booked_start_at,
    public.csp_start_at(new.booked_date, new.booked_start_time)
      at time zone 'Asia/Kuala_Lumpur'
  );
  new.booked_end_at := coalesce(
    new.booked_end_at,
    public.csp_end_at(new.booked_date, new.booked_start_time, new.booked_end_time)
      at time zone 'Asia/Kuala_Lumpur'
  );

  return new;
end;
$function$;

drop trigger if exists appointments_set_booked_snapshot on public.appointments;
create trigger appointments_set_booked_snapshot
  before insert on public.appointments
  for each row execute function public.set_appointment_booked_snapshot();
