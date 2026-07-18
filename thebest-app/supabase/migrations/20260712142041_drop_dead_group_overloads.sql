drop function if exists public.create_appointment_group_with_csp(
  uuid, text, integer, date, jsonb, text, text, uuid
);
drop function if exists public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, uuid
);;
