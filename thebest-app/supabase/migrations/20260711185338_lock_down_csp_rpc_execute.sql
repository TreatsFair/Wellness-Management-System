do $$
declare
  fn regprocedure;
begin
  for fn in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'create_appointment_with_csp',
        'update_appointment_with_csp',
        'create_appointment_group_with_csp',
        'update_appointment_group_with_csp'
      )
  loop
    execute format('revoke execute on function %s from public, anon;', fn);
    execute format('grant execute on function %s to authenticated;', fn);
  end loop;

  for fn in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'apply_appointment_service_buffer',
        'enforce_online_booking_outlet_match',
        'enforce_online_service_buffer',
        'prevent_appointment_resource_overlap',
        'rls_auto_enable',
        'seed_default_therapist_working_hours',
        'sync_inherited_staff_business_hours',
        'sync_service_buffer_after'
      )
  loop
    execute format('revoke execute on function %s from public, anon;', fn);
  end loop;
end $$;;
