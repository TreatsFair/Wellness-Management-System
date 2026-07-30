-- ============================================================================
-- 000003_ab_internal_cron.sql
-- ============================================================================
-- Sections A and B ONLY, extracted verbatim from 000003_cron.sql
-- (source SHA-256 a67acd1d8160c3bc2184a3112fe902f178a9ecfd0ab0379bf4c2f850d6a59b37).
--
-- WHY THIS FILE EXISTS
-- 000003_cron.sql cannot be applied as a whole during the baseline build.
-- Its Section C is an executable DO block whose guard raises an exception when
-- the Vault entries `booking_api_url` and `booking_cleanup_secret` are absent —
-- which they are, deliberately, until the Vault/Cron configuration stage.
-- Under --single-transaction with ON_ERROR_STOP=1 that exception would roll back
-- Sections A and B as well, so applying the combined file would install nothing.
--
-- This file therefore contains ONLY:
--   SECTION A  extensions (pg_cron, pg_net; asserts supabase_vault)
--   SECTION B  the two database-only jobs
--                reconcile-upcoming-appointment-assignments  */5  * * * *
--                expire-stale-booking-holds                  */10 * * * *
--
-- It contains NO outbound HTTP call, NO Vault read, NO secret and NO URL.
-- Section C stays in 000003_cron.sql and is applied later, on its own, once the
-- production booking-api is deployed and both Vault entries exist.
--
-- Nothing below is modified from the source file; only Section C is omitted.
-- ============================================================================

-- ============================================================================
-- 000003_cron.sql  —  Extensions and scheduled jobs for Treats Production
-- ============================================================================
-- Target : erjttzhownsxohpvzjbs (PRODUCTION, ap-southeast-1)
-- Derived: read-only inspection of staging hvyzexmsaxwendcexehx, 2026-07-30
-- Status : DRAFT — not applied anywhere. Nothing scheduled yet.
--
-- Production currently has NEITHER pg_cron NOR pg_net installed (verified
-- 2026-07-30). Staging has pg_cron 1.6.4 in pg_catalog and pg_net 0.20.3 in
-- extensions. Production's catalogue offers pg_net 0.20.4, so production will
-- land one patch release ahead. That difference is expected and benign.
--
-- Idempotent: re-running never creates duplicate jobs. cron.schedule() upserts
-- by jobname within the same database/user, and each job is explicitly
-- unscheduled first by name.
--
-- ============================================================================
-- SECTION LAYOUT — read this before running anything
-- ============================================================================
--   SECTION A  Extensions.                      Safe during baseline apply.
--   SECTION B  Jobs 1 and 2 (database-only).    Safe during baseline apply.
--   SECTION C  Job 3 (outbound HTTP).           DO NOT RUN during baseline.
--
-- Section C is fenced off deliberately. Job 3 makes outbound HTTP calls to the
-- production booking-api and must not start firing until ALL of these exist:
--
--     1. booking-api deployed to production;
--     2. BOOKING_CLEANUP_SECRET set as a production Edge Function secret;
--     3. Vault entry `booking_api_url`         (production function base URL);
--     4. Vault entry `booking_cleanup_secret`  (same value as (2)).
--
-- If job 3 were scheduled before those, every run would POST to a missing
-- endpoint or send an empty secret, producing a 403/404 loop every 2 minutes.
-- Section C therefore refuses to schedule unless the Vault entries are present,
-- and is intended to be run later, during the Vault/Cron configuration stage.
-- ============================================================================

-- ============================================================================
-- SECTION A — Extensions  (run during baseline application)
-- ============================================================================

-- pg_cron must live in pg_catalog to match staging.
create extension if not exists pg_cron with schema pg_catalog;

-- pg_net provides net.http_post, used only by job 3.
create extension if not exists pg_net with schema extensions;

-- supabase_vault is pre-installed by the platform (verified present in
-- production, v0.3.1, schema `vault`). Asserted rather than created, because
-- creating it is the platform's job.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'supabase_vault') then
    raise exception
      'supabase_vault is not installed. It is normally provisioned by Supabase; '
      'do not create it manually — investigate the project instead.';
  end if;
end
$$;

-- ============================================================================
-- SECTION B — Database-only jobs  (run during baseline application)
-- ============================================================================
-- These call local functions only. No network, no secrets, no Vault. They are
-- safe to schedule the moment 000001 has been applied, because both target
-- functions come from the public baseline.

do $$
declare
  v_jobid bigint;
begin
  -- Guard: the functions must exist, or the jobs would fail silently forever.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'reconcile_upcoming_appointment_assignments'
  ) then
    raise exception 'public.reconcile_upcoming_appointment_assignments() is missing — apply 000001 first.';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'expire_stale_booking_holds'
  ) then
    raise exception 'public.expire_stale_booking_holds() is missing — apply 000001 first.';
  end if;

  -- ---- Job 1: assignment reconciliation, every 5 minutes ------------------
  -- Repairs drift between appointments and their assigned therapist/room.
  -- Wholly distinct purpose from jobs 2 and 3; no overlap with either.
  select jobid into v_jobid from cron.job
   where jobname = 'reconcile-upcoming-appointment-assignments' limit 1;
  if v_jobid is not null then perform cron.unschedule(v_jobid); end if;

  perform cron.schedule(
    'reconcile-upcoming-appointment-assignments',
    '*/5 * * * *',
    'select public.reconcile_upcoming_appointment_assignments();'
  );

  -- ---- Job 2: hold expiry, every 10 minutes -------------------------------
  -- Flips booking_holds from 'pending_payment' to 'expired' once expires_at
  -- has passed. Pure status transition; never contacts Billplz.
  --
  -- DELIBERATELY REDUNDANT, AND KEPT ANYWAY. Job 3 already performs this work
  -- more often: claim_expired_billplz_cancellations() opens its body with
  -- `perform public.expire_stale_booking_holds();`. Job 2 is retained as the
  -- database-only fallback, so therapist and room capacity is still released
  -- if pg_net, Vault, or the Edge Function is down or misconfigured.
  --
  -- No conflict is possible: expire_stale_booking_holds is idempotent (its
  -- predicate stops matching once rows are flipped), and duplicate Billplz
  -- cancellation is prevented by job 3's claim token plus FOR UPDATE SKIP
  -- LOCKED — not by scheduling. Job 2's status flip is a PREREQUISITE for
  -- job 3's cancellation candidacy, not a race against it.
  select jobid into v_jobid from cron.job
   where jobname = 'expire-stale-booking-holds' limit 1;
  if v_jobid is not null then perform cron.unschedule(v_jobid); end if;

  perform cron.schedule(
    'expire-stale-booking-holds',
    '*/10 * * * *',
    'select public.expire_stale_booking_holds();'
  );
end
$$;
