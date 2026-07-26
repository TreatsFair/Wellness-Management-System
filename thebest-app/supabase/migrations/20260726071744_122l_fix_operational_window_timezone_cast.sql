-- Phase 6B.1 — corrects a REGRESSION INTRODUCED BY 122i.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726071744.
-- This file is the verbatim SQL that was applied.
--
-- BUG
--   public.appointments.start_at and end_at are `timestamp WITHOUT time zone`
--   holding LOCAL Asia/Kuala_Lumpur values. (booked_start_at / booked_end_at /
--   actual_started_at are timestamptz -- the table mixes both conventions.)
--
--   122i wrote:
--       v_supplied_end := new.end_at at time zone 'Asia/Kuala_Lumpur';
--       new.end_at     := v_end_local at time zone 'Asia/Kuala_Lumpur';
--
--   Applying `at time zone` to a local timestamp yields a timestamptz; storing
--   that back into a `timestamp without time zone` column re-renders it in the
--   session TimeZone (UTC on this project), shifting end_at by -8 hours.
--
--   Observed: a service started 15:15 local with a 50-minute duration stored
--   start_at 15:15 and end_at 08:05, i.e. block_end - block_start = -7.167
--   hours. A NEGATIVE blocking window blocks nothing: every availability query,
--   the overlap trigger and capacity_feasible would read the therapist and room
--   as free while the service is running -- the same class of double-booking
--   defect 122i was written to remove.
--
-- WHY NO ROWS WERE DAMAGED
--   The defect only manifests when set_appointment_schedule_at does NOT fire,
--   i.e. when the UPDATE does not touch appointment_date/start_time/end_time.
--   That is exactly the start_appointment_service path. The
--   check_in_paid_appointment_with_addon path includes end_time in its SET
--   list, so set_appointment_schedule_at re-derived end_at correctly and masked
--   the bug -- which is also why migration 122j's four repaired rows are
--   correct.
--
--   No appointment took the start path between 122i and this fix; verified at
--   apply time: 0 rows with end_at < start_at. Latent fix, not a data repair.
--
-- FIX
--   start_at / end_at are assigned plain local timestamps with no conversion.
--   booked_start_at / booked_end_at keep their `at time zone` conversion
--   because those columns really are timestamptz, as does the read of
--   actual_started_at.
--
-- VERIFIED transactionally before applying, both trigger paths:
--   A  start_appointment_service, 2h-early start, 50-min service
--      -> start_at 15:17, end_at 16:07, block 0.833h
--   B  check-in style UPDATE incl. end_time, 3-min service
--      -> start_at 15:17, end_at 15:20, block 0.050h, booked preserved 18:17
--
-- ROLLBACK: re-apply 122i's body. Doing so reintroduces the -8h shift.

create or replace function public.project_appointment_end_on_actual_start()
returns trigger
language plpgsql
set search_path = public
as $function$
declare
  v_booked_date date;
  v_booked_start_time time;
  v_booked_end_time time;
  v_booked_start_local timestamp;
  v_booked_end_local timestamp;
  v_duration interval;
  v_actual_local timestamp;
  v_end_local timestamp;
  v_supplied_end timestamp;
begin
  if new.actual_started_at is null then
    return new;
  end if;

  -- Idempotent: never re-anchor or re-extend an already-started service.
  if tg_op = 'UPDATE' and old.actual_started_at is not null then
    return new;
  end if;

  -- Scheduled truth. Prefer the booked snapshot; on UPDATE fall back to the
  -- PRE-UPDATE row, because the same statement may already have replaced
  -- start_time/end_time with check-in values; only then fall back to NEW.
  v_booked_date := coalesce(
    new.booked_date,
    case when tg_op = 'UPDATE' then old.appointment_date end,
    new.appointment_date
  );
  v_booked_start_time := coalesce(
    new.booked_start_time,
    case when tg_op = 'UPDATE' then old.start_time end,
    new.start_time
  );
  v_booked_end_time := coalesce(
    new.booked_end_time,
    case when tg_op = 'UPDATE' then old.end_time end,
    new.end_time
  );

  v_booked_start_local := public.csp_start_at(v_booked_date, v_booked_start_time);
  v_booked_end_local := public.csp_end_at(
    v_booked_date, v_booked_start_time, v_booked_end_time
  );
  v_duration := v_booked_end_local - v_booked_start_local;

  if v_duration is null or v_duration <= interval '0 seconds' then
    raise exception using
      errcode = '22023',
      message = 'Service duration must be greater than zero.';
  end if;

  if v_duration >= interval '24 hours' then
    raise exception using
      errcode = '22023',
      message = 'Service duration must be under 24 hours; the scheduled start/end pair is inconsistent.';
  end if;

  -- booked_start_at / booked_end_at ARE timestamptz: convert local -> tz.
  new.booked_date := v_booked_date;
  new.booked_start_time := v_booked_start_time;
  new.booked_end_time := v_booked_end_time;
  new.booked_start_at := coalesce(
    new.booked_start_at, v_booked_start_local at time zone 'Asia/Kuala_Lumpur'
  );
  new.booked_end_at := coalesce(
    new.booked_end_at, v_booked_end_local at time zone 'Asia/Kuala_Lumpur'
  );

  -- actual_started_at IS timestamptz: convert tz -> local.
  v_actual_local := new.actual_started_at at time zone 'Asia/Kuala_Lumpur';

  -- end_at is ALREADY a local timestamp: no conversion (this was the bug).
  v_supplied_end := new.end_at;

  if v_supplied_end is not null
     and v_supplied_end > v_actual_local
     and v_supplied_end - v_actual_local < interval '24 hours' then
    v_end_local := v_supplied_end;
  else
    v_end_local := v_actual_local + v_duration;
  end if;

  -- Anchor the OPERATIONAL window to the actual start. start_at / end_at are
  -- local timestamps and are assigned directly.
  new.appointment_date := v_actual_local::date;
  new.start_time := v_actual_local::time;
  new.end_time := v_end_local::time;
  new.start_at := v_actual_local;
  new.end_at := v_end_local;

  return new;
end;
$function$;
