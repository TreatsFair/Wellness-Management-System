-- =====================================================================
-- ONE-TIME STAGING MAINTENANCE SCRIPT — NOT A MIGRATION
-- =====================================================================
-- Date        : 2026-08-02
-- Target      : STAGING ONLY (hvyzexmsaxwendcexehx)
-- Purpose     : Clear dummy operational history before launch, keeping
--               all configuration and testing infrastructure intact.
--
-- MUST NOT be added to supabase/sql/NNN_*.sql and MUST NEVER be run
-- against Production. The pre-flight assertions below are designed to
-- abort loudly if it is pointed at the wrong database.
--
-- Safety properties:
--   * explicit table list, no blanket schema wipe
--   * no DROP TABLE
--   * no TRUNCATE ... CASCADE  (RESTRICT only)
--   * short lock_timeout (5s)
--   * identities reset only on the two synthetic-key operational tables
--   * aborts on unexpected FK dependencies or unexpected row counts
--   * audit_log cleared LAST
--   * does not touch audit functions/triggers, RLS, grants, Vault,
--     Edge Function secrets, auth.users or storage objects
--
-- Pre-requisite: pause cron jobs 1,2,3 via cron.alter_job(id, active := false)
-- Post-requisite: re-enable them via cron.alter_job(id, active := true)
-- =====================================================================

do $$
declare
  -- Tables whose contents are disposable dummy operational history.
  -- Order is irrelevant for the single multi-table TRUNCATE, but the
  -- list is exhaustive with respect to the FK graph (verified below).
  k_operational constant text[] := array[
    'appointments',
    'appointment_groups',
    'appointment_therapist_allocations',
    'appointment_therapist_segments',
    'appointment_assignment_invalidations',
    'transactions',
    'booking_holds',
    'customers',
    'notifications',
    'therapist_queue',
    'therapist_queue_day'
  ];

  -- Expected row counts captured from the read-only inventory taken
  -- immediately before this script was authored (2026-08-02).
  k_expected constant jsonb := jsonb_build_object(
    'appointments',                         382,
    'appointment_groups',                    63,
    'appointment_therapist_allocations',    319,
    'appointment_therapist_segments',       149,
    'appointment_assignment_invalidations',   0,
    'transactions',                         229,
    'booking_holds',                        116,
    'customers',                             20,
    'notifications',                        259,
    'therapist_queue',                      106,
    'therapist_queue_day',                   17
  );

  -- Configuration that must survive untouched.
  k_config_expected constant jsonb := jsonb_build_object(
    'outlets',                          2,
    'therapists',                      13,
    'rooms',                            8,
    'room_units',                      14,
    'services',                        26,
    'service_categories',               8,
    'online_booking_services',         13,
    'online_booking_service_rooms',    22,
    'online_booking_outlet_settings',   2,
    'online_booking_closures',          2,
    'therapist_working_hours',         91,
    'therapist_unavailability',         5,
    'business_hours',                  14,
    'business_settings',                2,
    'settings',                         1,
    'profiles',                         2
  );

  v_tbl        text;
  v_actual     bigint;
  v_expected   bigint;
  v_orphan     text;
  v_active_cron integer;
begin
  set local lock_timeout = '5s';

  -- -----------------------------------------------------------------
  -- GUARD 0: cron must be paused, or concurrent jobs will mutate rows
  --          mid-script and invalidate the count assertions.
  -- -----------------------------------------------------------------
  select count(*) into v_active_cron from cron.job where active;
  if v_active_cron <> 0 then
    raise exception
      'ABORT: % cron job(s) still active. Pause jobs 1,2,3 first.', v_active_cron;
  end if;

  -- -----------------------------------------------------------------
  -- GUARD 1: every table in the list must actually exist.
  -- -----------------------------------------------------------------
  foreach v_tbl in array k_operational loop
    if to_regclass('public.'||v_tbl) is null then
      raise exception 'ABORT: expected table public.% does not exist', v_tbl;
    end if;
  end loop;
  if to_regclass('public.audit_log') is null then
    raise exception 'ABORT: public.audit_log does not exist';
  end if;

  -- -----------------------------------------------------------------
  -- GUARD 2: no table OUTSIDE the disposable list may reference a table
  --          INSIDE it. If one appears, TRUNCATE ... RESTRICT would
  --          fail anyway -- fail early with a readable message instead.
  -- -----------------------------------------------------------------
  select string_agg(distinct child.relname||' -> '||parent.relname, ', ')
    into v_orphan
  from pg_constraint con
  join pg_class  child  on child.oid  = con.conrelid
  join pg_class  parent on parent.oid = con.confrelid
  join pg_namespace n   on n.oid      = child.relnamespace
  where con.contype = 'f'
    and n.nspname = 'public'
    and parent.relname = any(k_operational)
    and child.relname <> all(k_operational);

  if v_orphan is not null then
    raise exception
      'ABORT: unexpected FK dependency on disposable tables: %', v_orphan;
  end if;

  -- -----------------------------------------------------------------
  -- GUARD 3: nothing may reference audit_log.
  -- -----------------------------------------------------------------
  if exists (
    select 1 from pg_constraint where confrelid = 'public.audit_log'::regclass
  ) then
    raise exception 'ABORT: unexpected FK dependency on public.audit_log';
  end if;

  -- -----------------------------------------------------------------
  -- GUARD 4: disposable row counts must match the verified inventory.
  --          Any drift means this is not the database that was surveyed.
  -- -----------------------------------------------------------------
  foreach v_tbl in array k_operational loop
    execute format('select count(*) from public.%I', v_tbl) into v_actual;
    v_expected := (k_expected ->> v_tbl)::bigint;
    if v_actual <> v_expected then
      raise exception
        'ABORT: public.% has % rows, expected % (wrong database or data drifted)',
        v_tbl, v_actual, v_expected;
    end if;
  end loop;

  -- -----------------------------------------------------------------
  -- GUARD 5: configuration must match too -- this is the strongest
  --          "am I really on Staging?" signal available.
  -- -----------------------------------------------------------------
  for v_tbl, v_expected in select key, value::bigint from jsonb_each_text(k_config_expected) loop
    execute format('select count(*) from public.%I', v_tbl) into v_actual;
    if v_actual <> v_expected then
      raise exception
        'ABORT: config table public.% has % rows, expected % -- refusing to run',
        v_tbl, v_actual, v_expected;
    end if;
  end loop;

  raise notice 'All pre-flight guards passed. Clearing operational history.';

  -- -----------------------------------------------------------------
  -- STEP 1: single multi-table TRUNCATE. Every FK child of every listed
  --         table is itself listed (verified by GUARD 2), so RESTRICT
  --         is satisfied without CASCADE.
  --
  --         RESTART IDENTITY applies only to the two tables with
  --         synthetic bigint keys (appointment_assignment_invalidations);
  --         all others use UUID keys where identity reset is a no-op.
  -- -----------------------------------------------------------------
  truncate table
    public.appointments,
    public.appointment_groups,
    public.appointment_therapist_allocations,
    public.appointment_therapist_segments,
    public.appointment_assignment_invalidations,
    public.transactions,
    public.booking_holds,
    public.customers,
    public.notifications,
    public.therapist_queue,
    public.therapist_queue_day
  restart identity restrict;

  raise notice 'Operational history cleared.';
end
$$;

-- =====================================================================
-- STEP 2: clear audit_log LAST, in its own statement, so that any audit
--         rows produced by the cleanup above are also removed.
--         (No TRUNCATE-level triggers exist, so STEP 1 does not in fact
--          write audit rows -- this is belt-and-braces.)
-- =====================================================================
do $$
begin
  set local lock_timeout = '5s';
  truncate table public.audit_log restart identity restrict;
end
$$;

-- =====================================================================
-- POST-RUN (manual):
--   1. re-enable cron:
--        select cron.alter_job(1, active := true),
--               cron.alter_job(2, active := true),
--               cron.alter_job(3, active := true);
--   2. run the verification block in
--      PROJECT_GUIDE/14_SESSION_HANDOFF_2026-08-02.md
-- =====================================================================
