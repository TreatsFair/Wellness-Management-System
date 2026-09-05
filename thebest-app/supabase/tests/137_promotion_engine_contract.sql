-- Static, rollback-only contract for the promotion engine.
-- Run after applying the promotion migrations in a disposable or Staging
-- verification session. It creates no persistent rows.

begin;

do $contract$
declare
  v_body text;
  v_table text;
begin
  foreach v_table in array array[
    'promotions', 'promotion_codes', 'promotion_outlets',
    'promotion_services', 'promotion_redemptions'
  ] loop
    if to_regclass('public.' || v_table) is null then
      raise exception 'Promotion table is missing: %', v_table;
    end if;
    if not exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = v_table
        and c.relrowsecurity
    ) then
      raise exception 'RLS is not enabled on public.%', v_table;
    end if;
  end loop;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'promotion_codes_normalized_uidx'
  ) then
    raise exception 'Promotion code uniqueness constraint is missing';
  end if;

  select regexp_replace(
    pg_get_functiondef(
      'public.reserve_public_booking_promotion(uuid,text,uuid)'::regprocedure
    ), '[[:space:]]+', '', 'g'
  ) into v_body;
  if v_body not ilike '%forupdate%'
     or v_body not ilike '%statusin(''reserved'',''redeemed'')%'
     or v_body not ilike '%max_redemptions%'
     or v_body not ilike '%insertintopublic.promotion_redemptions%'
     or v_body not ilike '%pricing_snapshot%' then
    raise exception 'Promotion reservation is not atomic, capacity-aware, or auditable';
  end if;

  select regexp_replace(
    pg_get_functiondef(
      'public.create_public_booking_group_hold_with_promotion_v1(jsonb,timestamp with time zone,text,text,text,text,text,text)'::regprocedure
    ), '[[:space:]]+', '', 'g'
  ) into v_body;
  if v_body not ilike '%reserve_public_booking_promotion%'
     or v_body not ilike '%raiseexception%'
     or v_body not ilike '%detail%' then
    raise exception 'Promotion hold wrapper does not roll back on failed application';
  end if;

  select regexp_replace(
    pg_get_functiondef('public.apply_booking_promotion_lifecycle()'::regprocedure),
    '[[:space:]]+', '', 'g'
  ) into v_body;
  if v_body not ilike '%status=''released''%'
     or v_body not ilike '%status=''redeemed''%' then
    raise exception 'Promotion lifecycle trigger does not release and redeem reservations';
  end if;

  if has_function_privilege(
       'anon', 'public.reserve_public_booking_promotion(uuid,text,uuid)', 'execute'
     )
     or has_function_privilege(
       'authenticated', 'public.reserve_public_booking_promotion(uuid,text,uuid)', 'execute'
     )
     or not has_function_privilege(
       'service_role', 'public.reserve_public_booking_promotion(uuid,text,uuid)', 'execute'
     )
     or has_function_privilege(
       'anon', 'public.upsert_staff_promotion(jsonb)', 'execute'
     )
     or not has_function_privilege(
       'authenticated', 'public.upsert_staff_promotion(jsonb)', 'execute'
     ) then
    raise exception 'Promotion RPC ACL is incorrect';
  end if;

  if has_function_privilege(
       'anon', 'public.create_public_booking_group_hold_with_promotion_v1(jsonb,timestamp with time zone,text,text,text,text,text,text)', 'execute'
     )
     or not has_function_privilege(
       'service_role', 'public.create_public_booking_group_hold_with_promotion_v1(jsonb,timestamp with time zone,text,text,text,text,text,text)', 'execute'
     ) then
    raise exception 'Promotion hold wrapper ACL is incorrect';
  end if;
end
$contract$;

rollback;
