-- =====================================================================
-- 135_audit_log_retention.sql
-- =====================================================================
-- Uniform 6-month retention for public.audit_log.
--
-- POLICY
--   Every row in public.audit_log is retained for 6 months, then purged.
--   There is NO long-term exemption -- not for table_name = 'transactions',
--   not for SECURE_CHECKOUT, and not for any future refund, void or
--   financial-correction action.
--
-- RATIONALE
--   The 7-year statutory retention duty attaches to the actual financial
--   records -- public.transactions (amounts, receipt_number), the linked
--   appointments, Billplz bill IDs and callback/payment evidence. Those
--   records live in their own tables and are never touched by this
--   migration. public.audit_log holds before/after row snapshots, which are
--   an operational forensic trail, not the financial record itself, and are
--   not required to be kept for 7 years.
--
-- SCOPE GUARANTEE
--   This migration contains exactly one DELETE, and its target is
--   public.audit_log. It does not delete or alter transactions,
--   appointments, receipt information, Billplz bill IDs, callback evidence
--   or any payment record.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Supporting index for changed_at-based deletion.
--
--    Deliberately a PLAIN, NON-PARTIAL btree index.
--
--    * Non-partial: a partial predicate would have to encode the retention
--      boundary, and now() / any moving date expression is NOT IMMUTABLE and
--      is rejected in an index predicate. A predicate on a fixed date would
--      silently stop matching as time passes. A plain index has no predicate
--      and therefore no immutability concern at all.
--
--    * Non-CONCURRENTLY: verified 2026-08-02 that the migration execution
--      path (Supabase apply_migration) wraps statements in a transaction
--      block, which rejects CREATE INDEX CONCURRENTLY with SQLSTATE 25001.
--      audit_log is small at deployment time (Staging 0 rows, Production
--      144 rows), so a normal CREATE INDEX takes microseconds and its brief
--      ACCESS EXCLUSIVE lock is immaterial. If this index ever has to be
--      rebuilt on a large table, do it outside the migration runner with
--      CREATE INDEX CONCURRENTLY in a standalone session.
-- ---------------------------------------------------------------------
create index if not exists audit_log_changed_at_idx
  on public.audit_log (changed_at);


-- ---------------------------------------------------------------------
-- 2. Run-status table.
-- ---------------------------------------------------------------------
create table if not exists public.audit_log_retention_runs (
  id                 bigint generated always as identity primary key,
  started_at         timestamptz not null,
  finished_at        timestamptz not null,
  duration_ms        integer     not null,
  retention_interval interval    not null,
  cutoff             timestamptz not null,
  rows_deleted       integer     not null,
  batches            integer     not null,
  rows_remaining     integer,
  status             text        not null
                     check (status in ('ok','partial','skipped','error')),
  error_message      text
);

comment on table public.audit_log_retention_runs is
  'Execution log for public.purge_audit_log(). One row per run.';

create index if not exists audit_log_retention_runs_started_at_idx
  on public.audit_log_retention_runs (started_at desc);

alter table public.audit_log_retention_runs enable row level security;

drop policy if exists audit_log_retention_runs_select_admin
  on public.audit_log_retention_runs;
create policy audit_log_retention_runs_select_admin
  on public.audit_log_retention_runs
  for select to authenticated
  using (public.is_admin());


-- ---------------------------------------------------------------------
-- 3. Purge function.
-- ---------------------------------------------------------------------
create or replace function public.purge_audit_log(
  p_retention interval default interval '6 months',
  p_batch_size     integer default 5000,
  p_max_batches    integer default 20
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_cutoff    timestamptz;
  v_deleted   integer := 0;
  v_total     integer := 0;
  v_batches   integer := 0;
  v_remaining integer := null;
  v_started   timestamptz := clock_timestamp();
  v_finished  timestamptz;
  v_status    text := 'ok';
  v_error     text := null;
begin
  if p_retention is null or p_retention < interval '30 days' then
    raise exception
      'purge_audit_log: refusing to purge with retention < 30 days (got %)',
      p_retention;
  end if;
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 50000 then
    raise exception 'purge_audit_log: p_batch_size out of range (got %)', p_batch_size;
  end if;

  v_cutoff := now() - p_retention;

  -- Advisory lock: only one purge at a time. If it cannot be obtained,
  -- return immediately so normal booking/payment activity is unaffected.
  if not pg_try_advisory_xact_lock(hashtextextended('audit-log-retention-v1', 0)) then
    v_finished := clock_timestamp();
    insert into public.audit_log_retention_runs (
      started_at, finished_at, duration_ms, retention_interval, cutoff,
      rows_deleted, batches, rows_remaining, status, error_message
    ) values (
      v_started, v_finished,
      (extract(epoch from (v_finished - v_started)) * 1000)::integer,
      p_retention, v_cutoff, 0, 0, null, 'skipped',
      'advisory lock held by another run; exited immediately'
    );
    return 0;
  end if;

  -- Yield to live traffic rather than blocking it.
  perform set_config('lock_timeout', '2s', true);
  perform set_config('statement_timeout', '60s', true);

  begin
    loop
      exit when v_batches >= p_max_batches;

      -- Bounded batch, deleted by primary key from an ordered subselect so
      -- each statement is short and holds few row locks.
      delete from public.audit_log al
      where al.id in (
        select id
        from public.audit_log
        where changed_at < v_cutoff
        order by changed_at
        limit p_batch_size
      );

      get diagnostics v_deleted = row_count;
      v_total   := v_total + v_deleted;
      v_batches := v_batches + 1;

      exit when v_deleted = 0;
    end loop;

    select count(*) into v_remaining
    from public.audit_log
    where changed_at < v_cutoff;

    if v_total = 0 then
      v_status := 'skipped';          -- nothing eligible; idempotent no-op
    elsif v_remaining > 0 then
      v_status := 'partial';          -- batch ceiling hit; next run resumes
    end if;

  exception when others then
    -- Never propagate into the cron worker, never block bookings.
    v_status := 'error';
    v_error  := sqlerrm;
  end;

  v_finished := clock_timestamp();

  insert into public.audit_log_retention_runs (
    started_at, finished_at, duration_ms, retention_interval, cutoff,
    rows_deleted, batches, rows_remaining, status, error_message
  ) values (
    v_started, v_finished,
    (extract(epoch from (v_finished - v_started)) * 1000)::integer,
    p_retention, v_cutoff, v_total, v_batches, v_remaining, v_status, v_error
  );

  return v_total;
end;
$function$;

comment on function public.purge_audit_log(interval, integer, integer) is
  'Deletes rows from public.audit_log older than p_retention (default 6 '
  'months) in bounded batches. Touches no table other than public.audit_log.';


-- ---------------------------------------------------------------------
-- 4. Execution restricted to the pg_cron maintenance owner.
--    Verified: all existing cron jobs run as username = 'postgres'.
-- ---------------------------------------------------------------------
revoke all on function public.purge_audit_log(interval, integer, integer)
  from public;
revoke all on function public.purge_audit_log(interval, integer, integer)
  from anon, authenticated, service_role;
grant execute on function public.purge_audit_log(interval, integer, integer)
  to postgres;


-- ---------------------------------------------------------------------
-- 5. Weekly schedule: Sunday 03:30 Asia/Kuala_Lumpur.
--    The server clock is UTC and MYT is UTC+8, so 03:30 Sunday MYT is
--    19:30 Saturday UTC -> '30 19 * * 6'.
--
--    pg_cron 1.6 updates an existing job when cron.schedule is called with
--    the same jobname, so this migration is idempotent and cannot create
--    the job twice.
-- ---------------------------------------------------------------------
select cron.schedule(
  'purge-audit-log',
  '30 19 * * 6',
  $$select public.purge_audit_log();$$
);
