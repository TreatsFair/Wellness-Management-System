\set ON_ERROR_STOP on

-- Static post-migration contract for the concrete-locking MVP. Run only
-- against a disposable database after all local migrations are applied.

begin;

do $contract$
declare
  v_allocator regprocedure;
  v_queue regprocedure;
  v_consumer regprocedure;
  v_active_start regprocedure;
  v_dormant_start regprocedure;
  v_allocator_body text;
  v_queue_body text;
  v_consumer_body text;
begin
  if exists (
    select 1 from public.business_settings where capacity_first_enabled
  ) then
    raise exception 'capacity-first remains enabled for an outlet';
  end if;

  if exists (
    select 1
    from public.therapist_queue
    where protected_turn_owed or protected_turn_reason is not null
  ) then
    raise exception 'protected-turn state remains active';
  end if;

  v_allocator := to_regprocedure(
    'public.allocate_provisional_slots(uuid,date,time,jsonb,uuid)'
  );
  v_queue := to_regprocedure(
    'public.get_therapist_queue(uuid,date,time,integer)'
  );
  v_consumer := to_regprocedure(
    'public.consume_therapist_queue_turn_for_start(uuid,date,uuid,timestamptz,uuid)'
  );
  v_active_start := to_regprocedure(
    'public.finalize_and_start_appointment(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );
  v_dormant_start := to_regprocedure(
    'public.finalize_and_start_appointment_122t_capacity_first_dormant(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );

  if v_allocator is null or v_queue is null or v_consumer is null
     or v_active_start is null or v_dormant_start is null then
    raise exception 'concrete-locking functions are missing';
  end if;

  select pg_get_functiondef(v_allocator) into v_allocator_body;
  select pg_get_functiondef(v_queue) into v_queue_body;
  select pg_get_functiondef(v_consumer) into v_consumer_body;

  if v_allocator_body not ilike '%specific_customer_request%'
     or v_allocator_body not ilike '%manual_override%'
     or v_allocator_body not ilike '%requested_gender%'
     or v_allocator_body not ilike '%turn_consumed_at nulls first%'
     or v_allocator_body not ilike '%buffer_after_minutes%' then
    raise exception 'concrete allocator contract drifted';
  end if;

  if v_queue_body ilike '%protected_turn_owed desc%'
     or v_queue_body ilike '%protected_turn_owed nulls%'
     or v_consumer_body ilike '%specific_customer_request%' then
    raise exception 'protected or source-skipping queue behavior is active';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.appointments'::regclass
      and tgname = 'zz_appointments_require_mvp_concrete_resources'
      and not tgisinternal
  ) then
    raise exception 'appointment concrete-resource trigger is missing';
  end if;
end
$contract$;

rollback;
