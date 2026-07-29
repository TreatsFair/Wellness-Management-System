-- Run after migration 124 in a disposable database.
-- These assertions protect the atomic finalisation boundary without creating
-- business rows or payments.

do $test$
declare
  v_guard text;
  v_single text;
  v_group text;
begin
  if to_regprocedure(
    'public.finalize_and_start_appointment_core_124_legacy(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  ) is null then
    raise exception '124 must preserve the previous core behind an owner-only name';
  end if;

  select pg_get_functiondef(
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'::regprocedure
  ) into v_guard;
  select pg_get_functiondef(
    'public.finalize_and_start_appointment(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'::regprocedure
  ) into v_single;
  select pg_get_functiondef(
    'public.finalize_and_start_appointment_group(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'::regprocedure
  ) into v_group;

  if v_guard not like '%THERAPIST_CONFIRMATION_REQUIRED%'
     or v_guard not like '%THERAPIST_BUSY%'
     or v_guard not like '%p_therapist_id is null%'
     or v_guard not like '%check_booking_availability%' then
    raise exception '124 guard must require confirmation and revalidate the actual window';
  end if;
  if v_guard like '%v_therapist := v_queue.therapist_id%' then
    raise exception '124 guard must never silently choose a therapist';
  end if;
  if v_single not like '%exception when others%'
     or v_single not like '%insert into public.transactions%'
     or v_single not like '%finalize_and_start_appointment_core%' then
    raise exception 'single finalisation must retain atomic payment/start rollback';
  end if;
  if v_group not like '%exception when others%'
     or v_group not like '%order by a.id%'
     or v_group not like '%finalize_and_start_appointment_core%' then
    raise exception 'group finalisation must retain ordered all-or-nothing start';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)',
    'EXECUTE'
  ) then
    raise exception 'owner-only finalisation core must not be client-callable';
  end if;
end;
$test$;
