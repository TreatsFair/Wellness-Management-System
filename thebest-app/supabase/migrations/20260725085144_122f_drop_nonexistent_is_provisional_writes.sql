-- Phase 6B.1 corrective patch, found by the transactional smoke test on
-- 2026-07-25 immediately after 122d/122e were applied to the staging project.
--
-- ROOT CAUSE
--   122d and 122e (as shipped in phase6b1_corrected_package) wrote
--   public.appointments.is_provisional. That column does not exist anywhere in
--   the public schema — verified against information_schema.columns, which
--   returns zero rows for column_name = 'is_provisional' across every table.
--   The candidate package's claim that 122e "persists p_is_provisional" was
--   false.
--
--   The write sits inside the capacity_first_enabled = ON branch only, so with
--   the flag OFF nothing live was ever affected. With the flag ON, every
--   create / update / group-update would have raised
--       42703: column a.is_provisional does not exist
--   at runtime.
--
-- RESOLUTION
--   The deployed 121 functions accept p_is_provisional and never persist it.
--   That contract is restored: the parameter stays in every signature for
--   caller compatibility and is ignored. Adding the column is a schema change
--   and is deliberately out of scope for Phase 6B.1.
--
-- WHAT THIS FILE DOES
--   On the staging project this version was applied as a full
--   `create or replace function public.update_appointment_group_with_csp(...)`
--   carrying the corrected body. The checked-in 122d source has since been
--   corrected in place, so on a clean rebuild 122d already produces the
--   corrected body and this file only needs to fail closed if it does not.
--   Same ledger-preserving assertion pattern as 119b / 122b / 122c.
--
--   Function bodies only. No renames, no ACL changes, no data changes.

do $check$
declare
  v_definition text;
begin
  select lower(pg_get_functiondef(
    'public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'::regprocedure
  ))
  into v_definition;

  if position('is_provisional' in v_definition) <> 0 then
    raise exception
      '122f precondition failed: update_appointment_group_with_csp still references the non-existent appointments.is_provisional column';
  end if;

  if position('cross_outlet_move_not_supported' in v_definition) = 0
     or position('public.capacity_feasible(' in v_definition) = 0 then
    raise exception
      '122f precondition failed: the capacity-first group wrapper is missing';
  end if;
end;
$check$;
