begin;

-- pg_cron does not prune cron.job_run_details automatically. Keep enough
-- recent history for operations while preserving unfinished and unfamiliar
-- statuses by default.
create or replace function private.pg_cron_history_should_purge(
  p_status text,
  p_end_time timestamptz,
  p_reference_time timestamptz default now()
)
returns boolean
language sql
stable
set search_path = ''
as $function$
  select case
    when p_end_time is null then false
    when p_status = 'succeeded'
      then p_end_time < p_reference_time - interval '14 days'
    when p_status in ('failed', 'error')
      then p_end_time < p_reference_time - interval '90 days'
    else false
  end;
$function$;

comment on function private.pg_cron_history_should_purge(
  text, timestamptz, timestamptz
) is
  'Returns true only for completed, recognised pg_cron statuses beyond the '
  'approved retention window. Null end times and unknown statuses are kept.';

revoke all on function private.pg_cron_history_should_purge(
  text, timestamptz, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function private.pg_cron_history_should_purge(
  text, timestamptz, timestamptz
) to postgres;

create or replace function private.purge_pg_cron_history(
  p_reference_time timestamptz default now()
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_succeeded_deleted integer := 0;
  v_failed_deleted integer := 0;
begin
  delete from cron.job_run_details details
  where details.status = 'succeeded'
    and private.pg_cron_history_should_purge(
      details.status,
      details.end_time,
      p_reference_time
    );
  get diagnostics v_succeeded_deleted = row_count;

  delete from cron.job_run_details details
  where details.status in ('failed', 'error')
    and private.pg_cron_history_should_purge(
      details.status,
      details.end_time,
      p_reference_time
    );
  get diagnostics v_failed_deleted = row_count;

  return jsonb_build_object(
    'succeeded_deleted', v_succeeded_deleted,
    'failed_or_error_deleted', v_failed_deleted,
    'reference_time', p_reference_time
  );
end;
$function$;

comment on function private.purge_pg_cron_history(timestamptz) is
  'Prunes only completed pg_cron history: succeeded after 14 days and '
  'failed/error after 90 days. Running and unknown statuses are preserved.';

revoke all on function private.purge_pg_cron_history(timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function private.purge_pg_cron_history(timestamptz)
  to postgres;

-- Run daily at 18:45 UTC, which is 02:45 the following day in Malaysia.
-- Remove every same-named job first so applying this definition repeatedly
-- cannot create duplicate schedules. Existing operational jobs are untouched.
do $cron$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid
    from cron.job
    where jobname = 'purge-pg-cron-history'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'purge-pg-cron-history',
    '45 18 * * *',
    'select private.purge_pg_cron_history();'
  );
end
$cron$;

-- One safe initial prune using the same reusable predicate and retention rules.
select private.purge_pg_cron_history();

commit;
