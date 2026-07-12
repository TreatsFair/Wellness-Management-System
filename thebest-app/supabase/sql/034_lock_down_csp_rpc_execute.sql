-- Security hardening: restrict who can EXECUTE the scheduling RPCs and the
-- internal trigger/util functions.
--
-- Problem: `create or replace function` grants EXECUTE to PUBLIC by default.
-- The staff scheduling RPCs are SECURITY DEFINER, so any caller holding only the
-- publishable/anon key (embedded in the public website JS) could invoke them via
-- /rest/v1/rpc/... and create, modify, or DELETE appointments directly, bypassing
-- the staff-only RLS. `update_appointment_group_with_csp` is the worst case: it
-- deletes every appointment for a supplied group id and re-inserts.
--
-- Fix: revoke EXECUTE from PUBLIC + anon on the staff RPCs (keep authenticated),
-- and drop anon exposure on the internal trigger/util functions. Triggers execute
-- their functions regardless of EXECUTE grants, so this does not affect enforcement.
-- The public website is unaffected: it only calls the service-role booking-api
-- Edge Function, never these RPCs.

do $$
declare
  fn regprocedure;
begin
  -- Staff scheduling RPCs: authenticated staff only.
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

  -- Internal trigger/util SECURITY DEFINER functions: never meant to be called
  -- directly over the REST API. Remove anonymous exposure; leave authenticated as-is.
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
end $$;
