-- Drop the two stale 8-arg overloads of create/update_appointment_group_with_csp
-- (from before p_type was added, see 014). CspService.dart always passes p_type,
-- so these were never reachable; they are dead code left over from the signature
-- change. Explicitly authorized for removal (see conversation).

drop function if exists public.create_appointment_group_with_csp(
  uuid, text, integer, date, jsonb, text, text, uuid
);
drop function if exists public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, uuid
);
