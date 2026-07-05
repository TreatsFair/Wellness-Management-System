-- Allow the server-side booking Edge Function to perform its direct reads.
-- Browser roles remain unchanged; public traffic must still use booking-api.

grant usage on schema public to service_role;

grant select on table
  public.outlets,
  public.business_settings,
  public.services,
  public.booking_holds
to service_role;

