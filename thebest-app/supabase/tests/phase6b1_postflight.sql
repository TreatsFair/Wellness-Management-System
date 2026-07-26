-- READ-ONLY postflight. Run immediately after db push.

do $check$
declare
  v_enabled integer;
  v_anonymous integer;
  v_group_definition text;
  v_capacity_definition text;
begin
  if to_regprocedure(
       'public.capacity_feasible_119b_legacy(uuid,jsonb,text,uuid,uuid)'
     ) is null then
    raise exception '119c legacy core is missing';
  end if;

  if to_regprocedure(
       'public.update_appointment_group_with_csp_concrete_legacy(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'
     ) is null then
    raise exception '122d legacy group function is missing';
  end if;

  select lower(pg_get_functiondef(
    'public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'::regprocedure
  ))
  into v_group_definition;

  if position('cross_outlet_move_not_supported' in v_group_definition) = 0
     or position('is distinct from' in v_group_definition) = 0
     or position('public.capacity_feasible(' in v_group_definition) = 0 then
    raise exception '122d wrapper definition is incomplete';
  end if;

  select lower(pg_get_functiondef(
    'public.capacity_feasible(uuid,jsonb,text,uuid,uuid)'::regprocedure
  ))
  into v_capacity_definition;

  if position('v_anonymous_appointments' in v_capacity_definition) = 0
     or position('v_anonymous_holds' in v_capacity_definition) = 0 then
    raise exception '119c wrapper does not count anonymous room demand';
  end if;

  select count(*) into v_enabled
  from public.business_settings
  where capacity_first_enabled;

  if v_enabled <> 0 then
    raise exception
      'Postflight failed: capacity_first_enabled unexpectedly ON';
  end if;

  select count(*) into v_anonymous
  from public.appointments
  where actual_started_at is null
    and status::text in ('pending', 'confirmed')
    and (therapist_id is null or room_id is null);

  if v_anonymous <> 0 then
    raise exception
      'Postflight failed: migration unexpectedly created anonymous rows';
  end if;
end;
$check$;

select
  jobid,
  jobname,
  schedule,
  active
from cron.job
where jobname = 'reconcile-upcoming-appointment-assignments';

select
  count(*) as blocked_sessions
from pg_stat_activity
where wait_event_type = 'Lock'
  and pid <> pg_backend_pid();

select
  count(*) as invalidation_backlog
from public.appointment_assignment_invalidations;
