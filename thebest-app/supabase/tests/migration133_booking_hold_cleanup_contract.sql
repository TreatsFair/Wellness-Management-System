-- Static contract for migration 133. Run after applying it to a disposable
-- local database; no fixture rows are created.

begin;

do $contract$
declare
  v_create_body text;
  v_group_body text;
  v_expire_body text;
  v_claim_body text;
  v_batch_body text;
  v_job_count integer;
begin
  select pg_get_functiondef(
    'public.create_public_booking_hold_v2('
    'uuid,timestamp with time zone,text,text,text,text,text,text,text)'
      ::regprocedure
  ) into v_create_body;
  select pg_get_functiondef(
    'public.confirm_public_booking_group_v1(uuid)'::regprocedure
  ) into v_group_body;
  select pg_get_functiondef(
    'public.expire_stale_booking_holds()'::regprocedure
  ) into v_expire_body;
  select pg_get_functiondef(
    'public.claim_booking_bill_cancellation(uuid,text)'::regprocedure
  ) into v_claim_body;
  select pg_get_functiondef(
    'public.claim_expired_billplz_cancellations(integer)'::regprocedure
  ) into v_batch_body;

  v_group_body := regexp_replace(v_group_body, '[[:space:]]+', '', 'g');
  v_expire_body := regexp_replace(v_expire_body, '[[:space:]]+', '', 'g');
  v_claim_body := regexp_replace(v_claim_body, '[[:space:]]+', '', 'g');
  v_batch_body := regexp_replace(v_batch_body, '[[:space:]]+', '', 'g');

  if v_create_body not ilike '%interval ''10 minutes''%'
     or v_create_body ilike '%interval ''15 minutes''%' then
    raise exception 'Public hold creation is not exactly ten minutes';
  end if;

  if v_group_body not ilike '%hold.status<>''pending_payment''%'
     or v_group_body not ilike '%hold.expires_at<=now()%' then
    raise exception 'Direct group confirmation lacks an all-pax expiry guard';
  end if;

  if v_expire_body not ilike '%status=''pending_payment''%'
     or v_expire_body not ilike '%expires_at<=now()%' then
    raise exception 'Expiry transition is not atomic on status and clock';
  end if;

  if v_claim_body not ilike '%forupdate%'
     or v_claim_body not ilike '%billplz_cancellation_claim_token%'
     or v_batch_body not ilike '%forupdateskiplocked%'
     or v_batch_body not ilike '%hold.status=''expired''%'
     or v_batch_body not ilike '%billplz_cancelled_atisnull%' then
    raise exception 'Billplz cancellation claiming is not race-safe';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'booking_holds'
      and column_name = 'billplz_cancelled_at'
  ) or not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'booking_holds'
      and column_name = 'billplz_cancellation_last_error'
  ) then
    raise exception 'Billplz cancellation audit columns are missing';
  end if;

  if has_function_privilege(
       'anon',
       'public.claim_booking_bill_cancellation(uuid,text)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.claim_booking_bill_cancellation(uuid,text)',
       'EXECUTE'
     )
     or not has_function_privilege(
       'service_role',
       'public.claim_booking_bill_cancellation(uuid,text)',
       'EXECUTE'
     ) then
    raise exception 'Billplz cancellation RPC ACL is incorrect';
  end if;

  select count(*)
  into v_job_count
  from cron.job
  where jobname = 'expire-stale-booking-holds'
    and schedule = '*/10 * * * *'
    and command = 'select public.expire_stale_booking_holds();'
    and active;
  if v_job_count <> 1 then
    raise exception 'Ten-minute booking-hold SQL Cron is missing';
  end if;

  if not exists (
    select 1
    from cron.job
    where jobname = 'reconcile-upcoming-appointment-assignments'
  ) then
    raise exception 'Existing appointment-reconciliation Cron was removed';
  end if;
end
$contract$;

rollback;
