-- ###################################################################
-- ##  STAGING DATA REPAIR — DO NOT REPLAY AGAINST CLEAN PRODUCTION  ##
-- ###################################################################
--
-- This migration contains NO schema or function changes. It repairs four
-- specific appointment rows that exist ONLY in the current dummy-data STAGING
-- project (hvyzexmsaxwendcexehx). Their UUIDs are hard-coded.
--
-- The future production project must be built from a CURATED CLEAN BASELINE
-- THAT EXCLUDES THIS FILE. On a clean database the guard below finds zero
-- matching rows and raises, which is the correct and intended outcome -- it is
-- a tripwire, not a failure to fix.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726065525.
-- This file is the verbatim SQL that was applied.
--
-- ------------------------------------------------------------------
-- WHY
-- ------------------------------------------------------------------
-- Before 122i, an early check-in could leave end_time < start_time, which
-- csp_end_at() reads as an overnight service. Four in-progress rows were left
-- with operational windows of up to 23.85 hours, phantom-blocking a therapist
-- and a room for a whole day.
--
-- Preview before applying (all four, 2026-07-25, Taman Wahyu):
--
--   0c2cde64  17:30-18:14  block  0.74h -> start 17:24:09, end 18:14:09
--   26f6b7c6  18:00-17:33  block 23.56h -> start 17:32:35, end 17:33:35
--   7a1d5d51  18:00-17:51  block 23.85h -> start 17:50:11, end 17:51:11
--   7b1ec37f  19:00-17:44  block 22.74h -> start 17:41:26, end 17:44:26
--
-- Result after applying: 0.833h / 0.017h / 0.017h / 0.050h, zero rows remaining
-- with actual_started_at < start_at while in_progress.
--
-- ------------------------------------------------------------------
-- DELIBERATELY NOT TOUCHED
-- ------------------------------------------------------------------
--   * The 10 COMPLETED rows with the same actual<scheduled pattern. Their
--     blocks are 0.83-1.17h with no inverted pair, they are historical, and
--     rewriting settled history would corrupt reporting.
--   * Cancelled rows (none matched).
--   * booked_start_time / booked_end_time on the repaired rows -- the
--     SCHEDULED truth is preserved untouched. Only the operational window
--     moves. e.g. 7b1ec37f still reads scheduled 19:00-19:03 with operational
--     17:41-17:44.
--
-- Scoped per the appointments-migration gotchas: an explicit id list, the
-- reconcile guard set so Migration 116's reconciler is not tripped, and the
-- overlap guard relaxed because we are shrinking windows, not creating
-- conflicts. This fires the audit-log trigger for 4 rows.
--
-- ROLLBACK: none provided, and none is wanted. Reverting would restore
-- 22-24 hour phantom blocks. If these rows must be restored for forensics,
-- read them from audit_log rather than re-corrupting live data.

do $repair$
declare
  v_ids uuid[] := array[
    '0c2cde64-2840-4615-91b6-36356e7b2391',
    '26f6b7c6-3fb1-4228-8b40-a603b2354e04',
    '7a1d5d51-21dc-45f6-9b89-c072a8f9bbff',
    '7b1ec37f-2a5b-46a4-8699-00298e2df91d'
  ]::uuid[];
  v_expected integer := 4;
  v_matched integer;
  v_updated integer;
  v_worst numeric;
begin
  -- Fail closed if the target set is not exactly what was previewed.
  -- On a clean production baseline this raises, by design.
  select count(*) into v_matched
  from public.appointments a
  where a.id = any(v_ids)
    and a.status::text = 'in_progress'
    and a.actual_started_at is not null
    and (a.actual_started_at at time zone 'Asia/Kuala_Lumpur') < a.start_at;

  if v_matched <> v_expected then
    raise exception
      '122j aborted: expected % previewed rows, found % still matching. Re-run the preview.',
      v_expected, v_matched;
  end if;

  perform set_config('app.assignment_reconcile_active', '1', true);
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  with target as (
    select a.id,
           (a.actual_started_at at time zone 'Asia/Kuala_Lumpur') as new_start_local,
           (a.actual_started_at at time zone 'Asia/Kuala_Lumpur')
             + coalesce(
                 a.booked_end_at - a.booked_start_at,
                 public.csp_end_at(
                   coalesce(a.booked_date, a.appointment_date),
                   coalesce(a.booked_start_time, a.start_time),
                   coalesce(a.booked_end_time, a.end_time)
                 )
                 - public.csp_start_at(
                     coalesce(a.booked_date, a.appointment_date),
                     coalesce(a.booked_start_time, a.start_time)
                   )
               ) as new_end_local
    from public.appointments a
    where a.id = any(v_ids)
  )
  update public.appointments a
  set appointment_date = t.new_start_local::date,
      start_time       = t.new_start_local::time,
      end_time         = t.new_end_local::time,
      start_at         = t.new_start_local,
      end_at           = t.new_end_local at time zone 'Asia/Kuala_Lumpur',
      updated_at       = now()
  from target t
  where a.id = t.id
    and (a.start_at is distinct from t.new_start_local
         or a.end_at is distinct from (t.new_end_local at time zone 'Asia/Kuala_Lumpur'));

  get diagnostics v_updated = row_count;

  if v_updated <> v_expected then
    raise exception '122j aborted: updated % rows, expected %.', v_updated, v_expected;
  end if;

  select max(extract(epoch from (public.csp_appointment_block_end_at(a)
              - public.csp_appointment_start_at(a))) / 3600.0)
  into v_worst
  from public.appointments a where a.id = any(v_ids);

  if v_worst >= 24 then
    raise exception '122j aborted: a repaired row still blocks % hours.', v_worst;
  end if;

  raise notice '122j repaired % rows; worst remaining block %h', v_updated, round(v_worst, 3);
end;
$repair$;
