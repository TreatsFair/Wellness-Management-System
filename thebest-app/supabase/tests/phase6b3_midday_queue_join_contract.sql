\set ON_ERROR_STOP on

-- Run after migration 125 in a disposable database. These assertions protect
-- the live-queue reconciliation contract without creating business rows.

begin;

do $contract$
declare
  v_seed regprocedure;
  v_queue regprocedure;
  v_consume_trigger regprocedure;
  v_seed_body text;
  v_queue_body text;
  v_consume_trigger_body text;
begin
  v_seed := to_regprocedure(
    'public.seed_therapist_queue(uuid,date)'
  );
  v_queue := to_regprocedure(
    'public.get_therapist_queue(uuid,date,time without time zone,integer)'
  );
  v_consume_trigger := to_regprocedure(
    'public.record_therapist_queue_turn_consumption()'
  );

  if v_seed is null or v_queue is null or v_consume_trigger is null then
    raise exception 'migration 125 queue functions are missing';
  end if;

  select pg_get_functiondef(v_seed) into v_seed_body;
  select pg_get_functiondef(v_queue) into v_queue_body;
  select pg_get_functiondef(v_consume_trigger)
  into v_consume_trigger_body;

  if v_seed_body not ilike '%pg_advisory_xact_lock%'
     or v_seed_body not ilike '%max(queue_row.queue_position)%'
     or v_seed_body not ilike '%not exists (%public.therapist_queue existing%'
     or v_seed_body not ilike '%v_max_position + missing.append_offset%'
     or v_seed_body ilike '%if exists (%public.therapist_queue%return;%'
  then
    raise exception
      'seed must reconcile missing eligible therapists at the queue tail';
  end if;

  if v_seed_body ilike '%update public.therapist_queue%set queue_position%'
  then
    raise exception
      'midday reconciliation must not rewrite existing live queue positions';
  end if;

  if v_queue_body not ilike
       '%order by queue_row.queue_position, queue_row.therapist_id%'
     or v_queue_body ilike
       '%turn_consumed_at nulls first, queue_row.queue_position%'
  then
    raise exception
      'live queue ranking must use authoritative queue_position order';
  end if;

  if v_consume_trigger_body not ilike
       '%new.queue_position := v_last_position%'
  then
    raise exception
      'turn consumption must continue rotating the therapist to the tail';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.seed_therapist_queue(uuid,date)',
    'EXECUTE'
  ) then
    raise exception 'internal queue seeding must not be client-callable';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.get_therapist_queue(uuid,date,time without time zone,integer)',
    'EXECUTE'
  ) then
    raise exception 'authenticated dashboard must retain queue read access';
  end if;
end;
$contract$;

rollback;
