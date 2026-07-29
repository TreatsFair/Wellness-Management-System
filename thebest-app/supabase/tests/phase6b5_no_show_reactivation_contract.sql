\set ON_ERROR_STOP on

-- Run after migration 127 in a disposable database. These assertions protect
-- the dedicated no-show lifecycle boundary without mutating business rows.

begin;

do $contract$
declare
  v_rpc regprocedure;
  v_generic_update regprocedure;
  v_body text;
  v_generic_body text;
begin
  v_rpc := to_regprocedure(
    'public.reactivate_no_show_appointment(uuid,date,time without time zone,time without time zone,uuid,uuid,uuid,jsonb)'
  );
  if v_rpc is null then
    raise exception 'migration 127 no-show reactivation RPC is missing';
  end if;
  v_generic_update := to_regprocedure(
    'public.update_appointment_with_csp(uuid,uuid,uuid,date,time without time zone,time without time zone,text,uuid,text,boolean)'
  );
  if v_generic_update is null then
    raise exception 'generic appointment update RPC is missing';
  end if;

  select pg_get_functiondef(v_rpc) into v_body;
  select pg_get_functiondef(v_generic_update) into v_generic_body;

  if v_body not ilike '%is_staff_or_admin%'
     or v_body not ilike '%for update%'
     or v_body not ilike '%status::text) <> ''no_show''%'
     or v_body not ilike '%choose a new date or time%'
     or v_body not ilike '%pg_advisory_xact_lock%'
     or v_body not ilike '%check_booking_availability%'
     or v_body not ilike '%allocate_specific_room_unit%'
     or v_body not ilike '%status = ''confirmed''%'
     or v_body not ilike '%checked_in_at = null%'
     or v_body not ilike '%actual_started_at = null%'
     or v_body not ilike '%actual_completed_at = null%'
     or v_body not ilike '%resources_confirmed_at = now()%'
  then
    raise exception
      'no-show reactivation must lock, validate, clear and confirm atomically';
  end if;

  if v_body ilike '%update public.transactions%'
     or v_body ilike '%payment_status =%'
     or v_body ilike '%consume_therapist_queue%'
     or v_body ilike '%turn_consumed_at%'
  then
    raise exception
      'no-show reactivation must preserve payment/history and not rotate queue';
  end if;
  if v_generic_body not ilike '%no_show%' then
    raise exception
      'generic appointment updates must continue rejecting no-show rows';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.appointments'::regclass
      and tgname = 'appointments_write_audit_log'
      and not tgisinternal
  ) then
    raise exception 'appointment audit trigger must preserve the no-show event';
  end if;

  if has_function_privilege('anon', v_rpc, 'EXECUTE')
     or not has_function_privilege('authenticated', v_rpc, 'EXECUTE')
  then
    raise exception 'no-show reactivation RPC privileges are incorrect';
  end if;
end;
$contract$;

rollback;
