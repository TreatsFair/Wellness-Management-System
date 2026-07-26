-- Phase 6B.1 corrective patch, companion to 122f, for the single-appointment
-- RPCs. Same root cause and same resolution: public.appointments.is_provisional
-- does not exist, so 122e's flag-ON create and update could never have run.
-- See 20260725085144_122f_drop_nonexistent_is_provisional_writes.sql for the
-- full write-up.
--
-- On the staging project this version was applied as full
-- `create or replace function` statements for create_appointment_with_csp and
-- update_appointment_with_csp carrying the corrected bodies. The checked-in
-- 122e source has since been corrected in place, so on a clean rebuild this
-- file only needs to fail closed if the correction is absent.
--
-- Function bodies only. No renames, no ACL changes, no data changes.

do $check$
declare
  v_create text;
  v_update text;
begin
  select lower(pg_get_functiondef(
    'public.create_appointment_with_csp(uuid,uuid,uuid,uuid,date,time without time zone,time without time zone,numeric,text,uuid,text,jsonb,integer,text,uuid,text,uuid,text,boolean)'::regprocedure
  ))
  into v_create;

  select lower(pg_get_functiondef(
    'public.update_appointment_with_csp(uuid,uuid,uuid,date,time without time zone,time without time zone,text,uuid,text,boolean)'::regprocedure
  ))
  into v_update;

  -- p_is_provisional may appear (signature + verbatim legacy delegation);
  -- a bare is_provisional column reference may not.
  if position('is_provisional' in replace(v_create, 'p_is_provisional', '')) <> 0 then
    raise exception
      '122g precondition failed: create_appointment_with_csp still writes the non-existent appointments.is_provisional column';
  end if;

  if position('is_provisional' in replace(v_update, 'p_is_provisional', '')) <> 0 then
    raise exception
      '122g precondition failed: update_appointment_with_csp still writes the non-existent appointments.is_provisional column';
  end if;

  -- The flag-OFF delegation must still forward p_assignment_source verbatim.
  if position('p_assignment_source, p_requested_therapist_id, p_requested_gender, p_is_provisional' in v_update) = 0 then
    raise exception
      '122g precondition failed: update_appointment_with_csp no longer forwards p_assignment_source verbatim to the 121 legacy body';
  end if;

  if position('appointment_not_editable' in v_update) = 0 then
    raise exception
      '122g precondition failed: the flag-ON editability guard is missing';
  end if;
end;
$check$;
