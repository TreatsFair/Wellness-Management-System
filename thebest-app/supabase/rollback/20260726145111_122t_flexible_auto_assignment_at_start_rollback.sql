-- Roll back 122t only. Restores the exact 122q finalisation entry points kept
-- under owner-only legacy names by the forward migration.

drop function if exists public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
);

drop function if exists public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
);

drop function if exists public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
);

drop function if exists public.match_finalize_start_group_therapists(
  uuid, jsonb, timestamptz
);

drop function if exists public.match_finalize_start_therapists_recursive(
  jsonb, integer, uuid[], uuid, uuid, uuid
);

alter function public.finalize_and_start_appointment_core_122q_legacy(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) rename to finalize_and_start_appointment_core;

alter function public.finalize_and_start_appointment_122q_legacy(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment;

alter function public.finalize_and_start_appointment_group_122q_legacy(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment_group;

revoke all on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

revoke all on function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;

grant execute on function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;

revoke all on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;

grant execute on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;
