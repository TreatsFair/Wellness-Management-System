\set ON_ERROR_STOP on

-- Static post-migration contract for exact ten-minute online resource holds
-- and the atomic paid-callback boundary.

begin;

do $contract$
declare
  v_hold_guard regprocedure;
  v_conversion_guard regprocedure;
  v_single_callback regprocedure;
  v_group_callback regprocedure;
  v_hold_body text;
  v_conversion_body text;
  v_single_body text;
  v_group_body text;
begin
  v_hold_guard := to_regprocedure(
    'public.enforce_online_hold_concrete_resources()'
  );
  v_conversion_guard := to_regprocedure(
    'public.enforce_online_appointment_conversion()'
  );
  v_single_callback := to_regprocedure(
    'public.process_paid_public_booking_hold(uuid,text)'
  );
  v_group_callback := to_regprocedure(
    'public.process_paid_public_booking_group(uuid,text)'
  );

  if v_hold_guard is null or v_conversion_guard is null
     or v_single_callback is null or v_group_callback is null then
    raise exception 'online concrete-hold functions are missing';
  end if;

  select pg_get_functiondef(v_hold_guard) into v_hold_body;
  select pg_get_functiondef(v_conversion_guard) into v_conversion_body;
  select pg_get_functiondef(v_single_callback) into v_single_body;
  select pg_get_functiondef(v_group_callback) into v_group_body;

  if v_hold_body not ilike '%interval ''10 minutes''%'
     or v_hold_body not ilike '%assigned_therapist_id is null%'
     or v_hold_body not ilike '%assigned_room_unit_id is null%' then
    raise exception 'online exact-resource hold contract drifted';
  end if;

  if v_conversion_body not ilike '%actual_started_at := null%'
     or v_conversion_body not ilike '%status := ''confirmed''%'
     or v_conversion_body not ilike '%assigned_room_unit_id%' then
    raise exception 'online conversion starts service or loses held resources';
  end if;

  if v_single_body not ilike '%confirm_public_booking_hold%'
     or v_single_body not ilike '%record_online_booking_payment%'
     or v_single_body not ilike '%billplz_bill_id is distinct from p_bill_id%'
     or v_single_body not ilike '%expires_at <= now()%'
     or v_group_body not ilike '%confirm_public_booking_group_v1%'
     or v_group_body not ilike '%record_online_booking_group_payment%'
     or v_group_body not ilike '%billplz_bill_id is distinct from p_bill_id%'
     or v_group_body not ilike '%expires_at <= now()%' then
    raise exception 'paid callback is not atomic through one RPC';
  end if;

  if has_function_privilege('anon', v_single_callback, 'EXECUTE')
     or has_function_privilege('authenticated', v_single_callback, 'EXECUTE')
     or has_function_privilege('anon', v_group_callback, 'EXECUTE')
     or has_function_privilege('authenticated', v_group_callback, 'EXECUTE') then
    raise exception 'paid callback RPC ACL is too broad';
  end if;

  if has_function_privilege(
       'service_role',
       'public.confirm_public_booking_hold(uuid)',
       'EXECUTE'
     )
     or has_function_privilege(
       'service_role',
       'public.confirm_public_booking_group_v1(uuid)',
       'EXECUTE'
     ) then
    raise exception 'service_role can bypass the paid callback boundary';
  end if;

  if to_regprocedure('public.process_paid_public_booking_hold(uuid)') is not null
     or to_regprocedure('public.process_paid_public_booking_group(uuid)') is not null then
    raise exception 'legacy token-only paid callback wrapper still exists';
  end if;
end
$contract$;

rollback;
