-- Phase 6B.1 integration repair — RC-2.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726065220.
-- This file is the verbatim SQL that was applied.
--
-- PROBLEM (reproduced from scratch on staging, rolled back):
--   A 3-minute service scheduled at 16:50 and checked in at 14:50 (2h early)
--   produced an operational block of 22.05 HOURS.
--
--   check_in_paid_appointment_with_addon does:
--       update appointments
--       set actual_started_at = now(), status = 'in_progress',
--           end_time = coalesce(p_end_time, end_time), ...
--   It writes the app-supplied end_time WITHOUT moving start_time. The
--   BEFORE-UPDATE trigger appointments_set_schedule_at (which fires on
--   UPDATE OF end_time) then recomputes
--       end_at := csp_end_at(appointment_date, start_time, end_time)
--   and, seeing end_time < start_time, interprets it as an OVERNIGHT service
--   and pushes end_at to the next day.
--
--   Consequences, all observed:
--     * a ~22h phantom block on therapist and room (3 live rows);
--     * for longer services, a gap [actual_started_at, start_at) in which the
--       therapist is genuinely working but reads FREE to every availability
--       query -- the double-booking defect;
--     * switch_appointment_therapist validates against the corrupted end_at
--       and fails or leaves the appointment unstartable.
--
--   14 of 103 started rows already had actual_started_at < start_at.
--
-- TRIGGER FIRE ORDER on appointments (alphabetical, BEFORE triggers):
--   ... normalize_assignment_states -> prevent_resource_overlap
--    -> project_end_on_actual_start -> set_audit_fields -> set_schedule_at ...
--   project_end_on_actual_start runs BEFORE set_schedule_at, so if it leaves
--   appointment_date / start_time / end_time mutually consistent, the later
--   set_schedule_at re-derives start_at / end_at correctly -- including the
--   genuine overnight case, where end_time < start_time is CORRECT.
--
-- KEY SUBTLETY (a first attempt at this fix failed on it):
--   booked_* is NOT populated at appointment creation -- 130 of 277 rows had
--   booked_start_time NULL. On the check-in UPDATE the statement has already
--   overwritten end_time, so coalesce(new.booked_end_time, new.end_time) reads
--   the CHECK-IN value and computes a bogus ~22h "duration". The scheduled
--   truth must therefore fall back to the PRE-UPDATE row (OLD), not NEW.
--
-- VERIFIED transactionally before applying: the same scenario now yields
--   booked (scheduled) 16:51-16:54, operational 14:51-14:54,
--   same-day start_at/end_at, BLOCK_HOURS 0.050.
--
-- ROLLBACK: restore the prior definition, which differed only in that it
--   (a) returned early when booked_start_at/booked_end_at were set and
--       end_at > actual_started_at,
--   (b) set only new.end_at, never start_at/start_time/end_time/appointment_date.
--   Reverting reintroduces the phantom-block defect and should only be done
--   together with reverting 122j.

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

  -- Scheduled truth. Prefer an existing booked snapshot; on UPDATE fall back to
  -- the PRE-UPDATE row, because the same statement may already have replaced
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

  -- A real service never runs 24h. Anything longer means the scheduled pair was
  -- already corrupt; fail loudly rather than persist another phantom block.
  if v_duration >= interval '24 hours' then
    raise exception using
      errcode = '22023',
      message = 'Service duration must be under 24 hours; the scheduled start/end pair is inconsistent.';
  end if;

  -- Freeze the scheduled snapshot before the operational window moves.
  new.booked_date := v_booked_date;
  new.booked_start_time := v_booked_start_time;
  new.booked_end_time := v_booked_end_time;
  new.booked_start_at := coalesce(
    new.booked_start_at, v_booked_start_local at time zone 'Asia/Kuala_Lumpur'
  );
  new.booked_end_at := coalesce(
    new.booked_end_at, v_booked_end_local at time zone 'Asia/Kuala_Lumpur'
  );

  v_actual_local := new.actual_started_at at time zone 'Asia/Kuala_Lumpur';
  v_supplied_end := case
    when new.end_at is null then null
    else new.end_at at time zone 'Asia/Kuala_Lumpur'
  end;

  -- Honour an operator-approved expected end when it is sane; otherwise project
  -- the true service duration from the actual start.
  if v_supplied_end is not null
     and v_supplied_end > v_actual_local
     and v_supplied_end - v_actual_local < interval '24 hours' then
    v_end_local := v_supplied_end;
  else
    v_end_local := v_actual_local + v_duration;
  end if;

  -- Anchor the OPERATIONAL window to the actual start. Writing all of
  -- appointment_date / start_time / end_time keeps set_appointment_schedule_at
  -- consistent whether or not it fires, and preserves intentional midnight
  -- crossings (end_time < start_time is then genuinely overnight).
  new.appointment_date := v_actual_local::date;
  new.start_time := v_actual_local::time;
  new.end_time := v_end_local::time;
  new.start_at := v_actual_local;
  new.end_at := v_end_local at time zone 'Asia/Kuala_Lumpur';

  return new;
end;
$function$;
