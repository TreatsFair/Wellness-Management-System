-- Qualify a PL/pgSQL column reference and keep the declared pax-count input in use.

do $migration$
declare
  v_definition text;
  v_updated text;
begin
  select pg_get_functiondef(
    'public.pay_appointment_group_addons(uuid,uuid[],jsonb,uuid,text,numeric,numeric,numeric,text,text)'::regprocedure
  ) into v_definition;

  v_updated := replace(
    v_definition,
    E'from public.appointments\n    where id = v_id and appointment_group_id = p_appointment_group_id',
    E'from public.appointments a\n    where a.id = v_id and a.appointment_group_id = p_appointment_group_id'
  );
  if v_updated = v_definition then
    raise exception 'pay_appointment_group_addons qualification target was not found';
  end if;
  execute v_updated;

  select pg_get_functiondef(
    'public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'::regprocedure
  ) into v_definition;

  v_updated := replace(
    v_definition,
    'pax_count = jsonb_array_length(p_allocations),',
    'pax_count = greatest(coalesce(p_pax_count, jsonb_array_length(p_allocations)), 1),'
  );
  if v_updated = v_definition then
    raise exception 'update_appointment_group_with_csp pax-count target was not found';
  end if;
  execute v_updated;
end;
$migration$;
