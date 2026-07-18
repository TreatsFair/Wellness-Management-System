-- Keep public slots on clean interval boundaries even when an outlet's stored
-- opening time is not aligned to its configured booking interval. For example,
-- a 10:39 opening with a 10-minute interval now starts at 10:40, not 10:39.

do $migration$
declare
  v_definition text;
  v_old text :=
    E'v_anchor := p_date + greatest(v_settings.public_open_time, v_business.open_time);\n'
    || E'    v_steps := greatest(\n'
    || E'      ceil(extract(epoch from ((p_date + v_open) - v_anchor)) / 60.0 / v_interval)::integer,\n'
    || E'      0\n'
    || E'    );\n'
    || E'    v_slot_local := v_anchor + make_interval(mins => v_steps * v_interval);';
  v_new text :=
    E'v_anchor := p_date;\n'
    || E'    v_steps := greatest(\n'
    || E'      ceil(extract(epoch from ((p_date + v_open) - v_anchor)) / 60.0 / v_interval)::integer,\n'
    || E'      0\n'
    || E'    );\n'
    || E'    v_slot_local := v_anchor + make_interval(mins => v_steps * v_interval);';
begin
  select pg_get_functiondef(p.oid)
  into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_public_booking_slots_v2'
    and pg_get_function_identity_arguments(p.oid) =
      'p_catalogue_id uuid, p_date date, p_therapist_preference text';

  if v_definition is null or strpos(v_definition, v_old) = 0 then
    raise exception 'Unable to update public booking slot grid anchor';
  end if;

  execute replace(v_definition, v_old, v_new);
end;
$migration$;
