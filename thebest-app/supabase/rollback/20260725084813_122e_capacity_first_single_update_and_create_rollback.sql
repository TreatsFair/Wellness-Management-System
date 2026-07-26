-- Rollback for 122e.
-- Restores original 121 single-appointment RPCs by replacing the wrappers
-- with the _121_legacy renamed versions.

begin;

drop function if exists public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
);

drop function if exists public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
);

alter function public.create_appointment_with_csp_121_legacy(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) rename to create_appointment_with_csp;

alter function public.update_appointment_with_csp_121_legacy(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) rename to update_appointment_with_csp;

-- 122e revoked every client role from the legacy names. The renames carry that
-- locked-down ACL back onto the public names, so the deployed grants
-- (postgres + authenticated) must be restored explicitly.
revoke all on function public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) from public, anon, service_role;

grant execute on function public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) to authenticated;

revoke all on function public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) from public, anon, service_role;

grant execute on function public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) to authenticated;

commit;
