-- =====================================================================
-- MONTHLY STORAGE MONITORING — READ ONLY
-- =====================================================================
-- Safe to run against Staging or Production at any time. Creates nothing,
-- changes nothing. Run monthly and compare against the healthy baseline
-- documented at the bottom.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Headline: database size and the four tables that matter.
-- ---------------------------------------------------------------------
select
  pg_size_pretty(pg_database_size(current_database()))            as db_size,
  round(pg_database_size(current_database())/1024.0/1024.0, 1)    as db_mb,
  -- % of the Supabase Free 500 MB database limit
  round(100.0 * pg_database_size(current_database())
        / (500::numeric * 1024*1024), 1)                          as pct_of_free_500mb,
  case
    when pg_database_size(current_database()) >= 425::bigint*1024*1024 then 'CRITICAL (>=425 MB)'
    when pg_database_size(current_database()) >= 350::bigint*1024*1024 then 'WARNING (>=350 MB)'
    else 'OK'
  end                                                              as storage_alert;

-- ---------------------------------------------------------------------
-- 2. Per-table detail: total / heap / index / TOAST, tuples, vacuum times.
-- ---------------------------------------------------------------------
select
  c.relname                                                        as table_name,
  pg_size_pretty(pg_total_relation_size(c.oid))                    as total,
  pg_size_pretty(pg_relation_size(c.oid))                          as heap,
  pg_size_pretty(pg_indexes_size(c.oid))                           as indexes,
  pg_size_pretty(coalesce(pg_total_relation_size(c.reltoastrelid), 0)) as toast,
  s.n_live_tup                                                     as live_tuples,
  s.n_dead_tup                                                     as dead_tuples,
  case when s.n_live_tup > 0
       then round(100.0 * s.n_dead_tup / s.n_live_tup, 1) end      as dead_pct,
  s.last_vacuum, s.last_autovacuum, s.last_analyze, s.last_autoanalyze
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where n.nspname = 'public'
  and c.relkind = 'r'
  and c.relname in ('audit_log','appointments','transactions','booking_holds')
order by pg_total_relation_size(c.oid) desc;

-- ---------------------------------------------------------------------
-- 3. Anything in public that has grown unexpectedly large.
--    Only audit_log should ever legitimately appear here.
-- ---------------------------------------------------------------------
select c.relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) as total,
       s.n_live_tup, s.n_dead_tup
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_stat_user_tables s on s.relid = c.oid
where n.nspname = 'public' and c.relkind = 'r'
  and pg_total_relation_size(c.oid) > 25 * 1024 * 1024
order by pg_total_relation_size(c.oid) desc;

-- ---------------------------------------------------------------------
-- 4. Growth over the previous 30 days + implied audit cost per booking.
-- ---------------------------------------------------------------------
select
  (select count(*) from public.audit_log
     where changed_at >= now() - interval '30 days')               as audit_rows_30d,
  (select count(*) from public.appointments
     where created_at >= now() - interval '30 days')               as appointments_30d,
  (select round(
      (select count(*) from public.audit_log
         where changed_at >= now() - interval '30 days')::numeric
      / nullif((select count(*) from public.appointments
                  where created_at >= now() - interval '30 days'), 0), 1))
                                                                   as audit_rows_per_appointment,
  pg_size_pretty(
    ((select count(*) from public.audit_log
        where changed_at >= now() - interval '30 days')
     * coalesce((select pg_total_relation_size('public.audit_log')
                 / nullif((select count(*) from public.audit_log), 0)), 2700))::bigint)
                                                                   as est_audit_growth_30d;

-- ---------------------------------------------------------------------
-- 5. Cron health — retention/maintenance jobs must not be silently failing.
-- ---------------------------------------------------------------------
select j.jobid, j.jobname, j.schedule, j.active,
       r.status, r.start_time, r.end_time,
       left(coalesce(r.return_message, ''), 120) as last_message
from cron.job j
left join lateral (
  select * from cron.job_run_details d
  where d.jobid = j.jobid order by d.start_time desc limit 1
) r on true
order by j.jobid;

-- =====================================================================
-- EXPECTED HEALTHY BASELINE (post-cleanup, 2026-08-02)
-- ---------------------------------------------------------------------
--   Production db_size .............. 19 MB   (pre-launch, near-empty)
--   Staging   db_size ............... 23 MB
--   audit_log ....................... ~290 MB steady state and BOUNDED --
--                                     uniform 6-month retention, no exemptions
--                                     (migration 135, deployed 2026-08-03).
--                                     It plateaus; it does not keep growing.
--   appointments .................... ~1 KB per row; < 50 MB at 30k rows
--   transactions / booking_holds .... single-digit MB in year 1
--   dead_pct ........................ < 20% steady state; brief spikes to
--                                     100%+ right after a bulk change are
--                                     normal until autovacuum runs
--   audit_rows_per_appointment ...... ~12   (alert if it exceeds ~20)
--   All 3 cron jobs ................. active = true, last status 'succeeded'
--
-- ALERT THRESHOLDS  (Supabase Free tier, 500 MB database limit)
--   WARNING   database reaches 350 MB (70% of 500 MB)
--   CRITICAL  database reaches 425 MB (85% of 500 MB)
--
--   With uniform 6-month retention the database is projected to PLATEAU at
--   roughly 320-350 MB (~290 MB audit + operational tables + base), i.e. near
--   but below the warning threshold, and it does not grow past it. If the
--   WARNING fires and keeps climbing, the cause is higher-than-projected
--   booking volume or a mass-update regression -- not the retention policy.
--   Remedy in that case: diff-only auditing (cuts audit ~55-65%, to ~110 MB)
--   or a Pro-tier upgrade.
--   WARN  audit_rows_30d > 2x the trailing 3-month average
--   WARN  audit_rows_per_appointment > 20 (a mass-update regression)
--   WARN  dead_tuples > live_tuples on a table with > 10k live rows
--         and last_autovacuum older than 24h
--   ALARM any operational table other than audit_log exceeds 25-50 MB
--   ALARM any cron job inactive, or last run status <> 'succeeded'
-- =====================================================================
