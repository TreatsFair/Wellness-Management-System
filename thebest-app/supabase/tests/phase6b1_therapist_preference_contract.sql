\set ON_ERROR_STOP on
begin;

do $test$
declare
  v_preview regprocedure;
  v_allocate regprocedure;
  v_preview_body text;
  v_allocate_body text;
begin
  v_preview := to_regprocedure(
    'public.get_counter_preference_capacity_slots(uuid,date,jsonb,uuid,uuid)'
  );
  v_allocate := to_regprocedure(
    'public.allocate_preference_provisional_slots(uuid,date,time without time zone,jsonb,uuid)'
  );
  if v_preview is null or v_allocate is null then
    raise exception '122r preference capacity functions are missing';
  end if;

  select pg_get_functiondef(v_preview) into v_preview_body;
  select pg_get_functiondef(v_allocate) into v_allocate_body;
  if v_preview_body not ilike '%capacity_feasible%'
     or v_preview_body not ilike '%requested_gender%'
     or v_preview_body not ilike '%requested_therapist_id%'
     or v_preview_body not ilike '%conflict_start%' then
    raise exception '122r preview does not preserve preference diagnostics';
  end if;
  if v_allocate_body not ilike '%not (t.id = any(v_used))%'
     or v_allocate_body not ilike '%therapist_working_hours%'
     or v_allocate_body not ilike '%therapist_unavailability%'
     or v_allocate_body not ilike '%service_commissions%' then
    raise exception '122r allocator does not enforce full therapist eligibility';
  end if;
  if not has_function_privilege('authenticated', v_preview, 'EXECUTE')
     or not has_function_privilege('authenticated', v_allocate, 'EXECUTE')
  then
    raise exception '122r authenticated grants are missing';
  end if;
end
$test$;

rollback;
