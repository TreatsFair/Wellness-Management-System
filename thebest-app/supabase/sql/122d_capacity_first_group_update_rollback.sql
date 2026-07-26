-- Roll back only the 6B.1 wrapper. It does not alter 121/122, appointments,
-- holds, Cron, or the feature flag.

begin;

drop function if exists public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
);

alter function public.update_appointment_group_with_csp_concrete_legacy(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) rename to update_appointment_group_with_csp;

commit;
