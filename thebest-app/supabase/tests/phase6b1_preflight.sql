-- READ-ONLY preflight. Run before db push.

do $check$
declare
  v_enabled integer;
  v_anonymous integer;
begin
  select count(*) into v_enabled
  from public.business_settings
  where capacity_first_enabled;

  if v_enabled <> 0 then
    raise exception
      'Preflight failed: capacity_first_enabled is ON for % outlet(s)',
      v_enabled;
  end if;

  select count(*) into v_anonymous
  from public.appointments
  where actual_started_at is null
    and status::text in ('pending', 'confirmed')
    and (therapist_id is null or room_id is null);

  if v_anonymous <> 0 then
    raise exception
      'Preflight failed: expected zero current anonymous appointments, found %',
      v_anonymous;
  end if;

  if to_regprocedure(
       'public.capacity_feasible_119b_legacy(uuid,jsonb,text,uuid,uuid)'
     ) is not null then
    raise exception '119c appears partly/already applied';
  end if;

  if to_regprocedure(
       'public.update_appointment_group_with_csp_concrete_legacy(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'
     ) is not null then
    raise exception '122d appears partly/already applied';
  end if;

  if to_regprocedure(
       'public.create_appointment_with_csp_121_legacy(uuid,uuid,uuid,uuid,date,time without time zone,time without time zone,numeric,text,uuid,text,jsonb,integer,text,uuid,text,uuid,text,boolean)'
     ) is not null
     or to_regprocedure(
       'public.update_appointment_with_csp_121_legacy(uuid,uuid,uuid,date,time without time zone,time without time zone,text,uuid,text,boolean)'
     ) is not null then
    raise exception '122e appears partly/already applied';
  end if;
end;
$check$;

select
  version,
  name
from supabase_migrations.schema_migrations
where version in (
  '20260723164513',
  '20260723164719',
  '20260723164820'
)
order by version;

select
  count(*) filter (where capacity_first_enabled) as enabled_outlets,
  count(*) as total_settings_rows
from public.business_settings;

select
  count(*) as anonymous_future_appointments
from public.appointments
where actual_started_at is null
  and status::text in ('pending', 'confirmed')
  and (therapist_id is null or room_id is null);
