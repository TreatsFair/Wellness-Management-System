create index if not exists audit_log_changed_at_idx
  on public.audit_log (changed_at);

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

  perform set_config('lock_timeout', '2s', true);
  perform set_config('statement_timeout', '60s', true);

  begin
    loop
      exit when v_batches >= p_max_batches;

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
      v_status := 'skipped';
    elsif v_remaining > 0 then
      v_status := 'partial';
    end if;

  exception when others then
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

revoke all on function public.purge_audit_log(interval, integer, integer)
  from public;
revoke all on function public.purge_audit_log(interval, integer, integer)
  from anon, authenticated, service_role;
grant execute on function public.purge_audit_log(interval, integer, integer)
  to postgres;

select cron.schedule(
  'purge-audit-log',
  '30 19 * * 6',
  $$select public.purge_audit_log();$$
);