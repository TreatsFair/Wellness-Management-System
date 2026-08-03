# Public Booking Architecture — Website → Supabase

How the public booking website reaches the database, and why the browser is
never trusted. This describes the **delivered system**, not a build plan.

## 1. System overview

There is no application server. The stack is:

```
Public website (static HTML/CSS/JS)
        │  HTTPS, publishable key only
        ▼
Supabase Edge Function  "booking-api"   (Deno, verify_jwt = false)
        │  service-role, server-side only
        ▼
PostgreSQL  — RPCs, constraints, triggers, RLS
```

The Flutter staff application talks to the same PostgreSQL database directly
(publishable key + an authenticated session), but the **public website never
does**. It can only call `booking-api`, which validates every request and
recalculates every price server-side.

All scheduling and booking logic lives in PostgreSQL — see
`supabase/sql/012_csp_core.sql` and
`028_service_buffers_and_resource_conflicts.sql`. An early Python prototype of
this layer was superseded before delivery and is preserved only in Git history.

## 2. Environments

Staging and Production are **separate Supabase projects** with separate
databases, secrets and payment credentials.

| | Staging | Production |
|---|---|---|
| Purpose | testing, dummy data | live |
| Billplz | Sandbox | Live |
| Website hosts | local dev, staging host | `thebestwellness.my`, `www.thebestwellness.my`, `tbwlive.netlify.app` |

`thebest-website/js/booking-config.js` selects the target by hostname. The
Flutter app selects by entrypoint (`lib/main_staging.dart` /
`lib/main_production.dart`).

Only publishable keys appear in client code. That is by design — they identify
the project, they do not grant access. Every secret (service-role key, all four
`BILLPLZ_*` values, `BOOKING_CLEANUP_SECRET`) is stored as an Edge Function
secret and read at runtime via `Deno.env.get()`. None is in this repository.

## 3. Public booking routes

`thebest-website/_redirects` maps outlet-specific paths onto one page:

```text
/booking              /booking.html  200
/booking-taman-wahyu  /booking.html  200
/booking-pv128        /booking.html  200
```

The page reads the path to preselect the outlet, so each branch can be linked
directly without a separate build.

## 4. The controlled catalogue

The website does **not** read operational `services`. Every public card is an
`online_booking_services` row, linked to one internal service and scoped to one
outlet. New outlets and catalogue rows are **disabled by default** and must be
enabled explicitly in Dashboard → Management → Online Booking.

This keeps internal pricing, room types, commissions and staff schedules out of
the public surface, and lets a service be sold online at a different name and
price from its counter equivalent.

Do not enable an outlet until its therapists have working-hour rows. The
scheduler deliberately returns no availability when it cannot prove a real
therapist and a real room slot can both be reserved.

## 5. Booking holds

A booking creates a **10-minute hold**, not an appointment.

```
create_public_booking_hold_v2  →  booking_holds row, status 'pending_payment',
                                  expires_at = now() + 10 minutes
```

Status lifecycle: `pending_payment` → `paid` → `confirmed`, or → `expired` /
`cancelled` / `payment_failed`.

A hold reserves the therapist and room while unpaid, so two customers cannot buy
the same slot. Expiry is enforced two ways: `expires_at` is checked on every
read, and the `expire-stale-booking-holds` cron job sweeps stale rows every
10 minutes.

The assigned therapist and room are chosen server-side and concurrency-safely.
Staff can reassign afterwards in the app.

## 6. Payment (Billplz)

```
submitHold()
  → POST /booking-holds        create the hold
  → POST /booking-holds/pay    create a Billplz bill, redirect to Billplz
                               ↓
              customer pays on Billplz' hosted page
                               ↓
   ┌───────────────────────────┴───────────────────────────┐
   │ redirect back to the browser        server-to-server  │
   │ (UX only, NOT trusted)              POST /billplz/callback │
   └───────────────────────────────────────────────────────┘
```

**Only the callback confirms a booking**, and only after its HMAC-SHA256
`x_signature` verifies. The browser redirect is presentation only —
`booking.html?bp_token=<token>` polls `GET /booking-holds/status` every 2s for
about two minutes and then shows confirmed, failed or timed-out.

This matters: a customer who closes the browser after paying still gets a
confirmed booking, and a forged redirect cannot create one.

Required Edge Function secrets:

```powershell
supabase secrets set BILLPLZ_BASE_URL=<https://www.billplz-sandbox.com | https://www.billplz.com>
supabase secrets set BILLPLZ_API_KEY=<api secret key>
supabase secrets set BILLPLZ_COLLECTION_ID=<collection id>
supabase secrets set BILLPLZ_X_SIGNATURE_KEY=<x signature key>
supabase functions deploy booking-api --no-verify-jwt
```

`GET /booking-api/health` reports `payment_enabled: true` once all four are set.
Moving from sandbox to live is a credential swap — no code change.

`BOOKING_TEST_AUTOCONFIRM` exists in the code as a pre-Billplz development
fallback that confirms a hold without payment. It is **off in Staging and
Production** and must stay off — real confirmation comes only from a verified
Billplz callback.

## 7. Public safety boundary

The browser receives outlet presentation data, public catalogue fields, dates,
times and a safe hold status. It never receives internal service IDs, room
types, commissions, staff schedules, capacity counts or assigned resources.

Price, duration, eligibility and availability are **always recalculated in the
database** when a hold is created. Editing a price in developer tools changes
nothing — the server total is authoritative. The catalogue UUID is only an
identifier.

Database enforcement, not application trust:

- **RLS on every table.** `anon` has no access to any operational table.
- **Outlet isolation by trigger** (`enforce_appointment_outlet_consistency`,
  `enforce_booking_hold_outlet_consistency`) — a cross-outlet reference raises.
- **Resource conflicts by trigger** (`prevent_appointment_resource_overlap`) —
  therapist and room capacity, including each service's inherited cleanup
  buffer.
- **Financial mutation is admin-only**; the cashier is recorded as
  `counter_staff_id`.

## 8. Scheduled maintenance (pg_cron)

| Job | Schedule | Purpose |
|---|---|---|
| `reconcile-upcoming-appointment-assignments` | `*/5 * * * *` | re-validate resource assignments after config changes |
| `expire-stale-booking-holds` | `*/10 * * * *` | expire unpaid holds |
| `cancel-expired-billplz-holds` | `*/2 * * * *` | cancel the Billplz bill behind an expired hold |
| `purge-audit-log` | `30 19 * * 6` | 6-month audit retention (Sun 03:30 MYT) |

`audit_log` keeps before/after snapshots for **6 months**. Financial records
themselves — `transactions`, receipts, Billplz references — are retained
indefinitely in their own tables and are never touched by the purge.

## 9. Deploying the Edge Function

```powershell
supabase login
supabase link --project-ref <project ref>
supabase secrets set BOOKING_SITE_ORIGINS=https://thebestwellness.my
supabase secrets set BOOKING_RATE_LIMIT_SALT=<long random value>
supabase functions deploy booking-api --no-verify-jwt
```

For local website testing, add the local origin as a comma-separated value:

```powershell
supabase secrets set BOOKING_SITE_ORIGINS=https://thebestwellness.my,http://localhost:5500
```

`--no-verify-jwt` is intentional and matches `verify_jwt = false` in
`supabase/config.toml`: the public booking endpoints are anonymous by design,
and are protected by origin allow-listing, per-route rate limiting and
server-side validation rather than by a JWT.

SQL migrations live in `supabase/sql/` numbered in order and are applied through
the Supabase SQL editor; there is no migration runner in this repository.

## 10. Verification

**Concurrency.** Configure a test service with exactly one eligible therapist
and one room slot, then:

```bash
deno test --allow-env --allow-net supabase/functions/tests/booking_concurrency_test.ts
```

Two parallel requests must produce exactly one `201` and one `409`.

**Functional checks.**

- Each outlet shows only its own catalogue.
- Female/male preference changes availability.
- Existing appointments remove conflicting times.
- Two browsers cannot hold the same therapist/room slot.
- A hold appears in `booking_holds` as `pending_payment`.
- The hold becomes `expired` after 10 minutes and stops blocking the slot.
- Changing a price in developer tools does not change the server total.

**Health.**

```text
GET https://<project ref>.supabase.co/functions/v1/booking-api/health
{ "ok": true, "payment_enabled": true }
```
