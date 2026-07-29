-- Per-environment operations template for abandoned Billplz bill cleanup.
-- Do not commit real secret values and do not run this until booking-api with
-- migration 133 is deployed in the same environment.
--
-- Edge Function environment secret:
--   BOOKING_CLEANUP_SECRET=<generate a long random value>
--
-- Vault secrets (create once per Supabase environment):
-- select vault.create_secret(
--   'https://PROJECT_REF.supabase.co/functions/v1/booking-api',
--   'booking_api_url',
--   'Full booking-api URL used by the Billplz cleanup Cron'
-- );
-- select vault.create_secret(
--   'THE_SAME_VALUE_AS_BOOKING_CLEANUP_SECRET',
--   'booking_cleanup_secret',
--   'Route-level secret for abandoned Billplz cleanup'
-- );

create extension if not exists pg_net with schema extensions;

do $cron$
declare
  v_job_id bigint;
begin
  select jobid
  into v_job_id
  from cron.job
  where jobname = 'cancel-expired-billplz-holds'
  limit 1;

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  perform cron.schedule(
    'cancel-expired-billplz-holds',
    '*/2 * * * *',
    $job$
      select net.http_post(
        url := (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'booking_api_url'
          limit 1
        ) || '/maintenance/expire-payment-holds',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-booking-cleanup-secret', (
            select decrypted_secret
            from vault.decrypted_secrets
            where name = 'booking_cleanup_secret'
            limit 1
          )
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 50000
      );
    $job$
  );
end
$cron$;
