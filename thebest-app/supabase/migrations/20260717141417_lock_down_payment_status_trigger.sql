-- Trigger functions execute through their owning trigger and do not need to be
-- callable through PostgREST.
revoke all on function public.sync_appointment_payment_status()
  from public, anon, authenticated;
