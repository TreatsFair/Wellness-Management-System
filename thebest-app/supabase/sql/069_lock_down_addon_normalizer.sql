-- This function is invoked only by the transactions trigger. It must not be
-- callable directly through PostgREST.
revoke all on function public.normalize_appointment_addon_transaction()
  from public, anon, authenticated;
