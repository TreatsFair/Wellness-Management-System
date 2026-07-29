\set ON_ERROR_STOP on

-- Run after migration 126 in a disposable database. This protects the
-- next-window feedback without creating appointments, payments, or starts.

begin;

do $contract$
declare
  v_core regprocedure;
  v_legacy regprocedure;
  v_body text;
begin
  v_core := to_regprocedure(
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  );
  v_legacy := to_regprocedure(
    'public.finalize_and_start_appointment_core_126_legacy(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  );

  if v_core is null or v_legacy is null then
    raise exception 'migration 126 finalisation wrapper is missing';
  end if;

  select pg_get_functiondef(v_core) into v_body;

  if v_body not ilike '%finalize_and_start_appointment_core_126_legacy%'
     or v_body not ilike '%when sqlstate ''P0001''%'
     or v_body not ilike '%THERAPIST_BUSY%'
     or v_body not ilike '%get_available_slots%'
     or v_body not ilike '%generate_series%'
     or v_body not ilike '%next_available_start_at%'
     or v_body not ilike '%next_available_end_at%'
     or v_body not ilike '%next_available_therapist_id%'
     or v_body not ilike '%availability_searched_through%'
  then
    raise exception
      'delayed start must return a fully validated next service window';
  end if;

  if v_body ilike '%insert into public.transactions%'
     or v_body ilike '%actual_started_at =%'
  then
    raise exception
      'next-window feedback must not save payment or a future actual start';
  end if;

  if has_function_privilege(
    'authenticated',
    v_core,
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    v_legacy,
    'EXECUTE'
  ) then
    raise exception 'owner-only finalisation cores must not be client-callable';
  end if;
end;
$contract$;

rollback;
