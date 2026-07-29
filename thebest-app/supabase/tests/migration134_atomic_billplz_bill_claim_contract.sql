-- Static, rollback-only contract for migration 134.

begin;

do $contract$
declare
  v_body text;
begin
  select regexp_replace(
    pg_get_functiondef(
      'public.claim_billplz_bill_v2(uuid,text)'::regprocedure
    ),
    '[[:space:]]+',
    '',
    'g'
  )
  into v_body;

  if v_body not ilike '%forupdate%'
     or v_body not ilike '%hold.status<>''pending_payment''%'
     or v_body not ilike '%hold.expires_at<=now()%'
     or v_body not ilike '%v_existing_bill_idisnotnull%' then
    raise exception 'Billplz bill claim is not race-safe and idempotent';
  end if;

  if has_function_privilege(
       'anon',
       'public.claim_billplz_bill_v2(uuid,text)',
       'execute'
     )
     or has_function_privilege(
       'authenticated',
       'public.claim_billplz_bill_v2(uuid,text)',
       'execute'
     )
     or not has_function_privilege(
       'service_role',
       'public.claim_billplz_bill_v2(uuid,text)',
       'execute'
     ) then
    raise exception 'Billplz bill claim ACL is incorrect';
  end if;
end
$contract$;

rollback;
