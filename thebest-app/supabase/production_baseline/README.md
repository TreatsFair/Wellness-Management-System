# Treats Wellness System — Production Baseline

**Status: DRAFT — not yet approved for production.** No file in this directory
has been applied to any project. The production project has not been modified.

## Source of this baseline

| Field | Value |
|---|---|
| Source project ref | `hvyzexmsaxwendcexehx` (STAGING) |
| Source region | `ap-northeast-1` / Tokyo |
| Source server version | PostgreSQL 17.6 |
| Release tag | `v1.0.0-rc1` |
| Release commit SHA | `d9affad840e419bb3a951ee7e39d01314f2936b5` |
| Release branch | `release/v1.0.0` |
| Dump date | 2026-07-30 |
| Dump tool | `pg_dump` 17.10 (Debian 17.10-1.pgdg13+1), official `postgres:17` image |
| Target project (untouched) | `erjttzhownsxohpvzjbs` (PRODUCTION), `ap-southeast-1` / Singapore |

### Two copies of the public baseline

`000001_baseline_public.raw.sql` is the **immutable audit copy** — the exact
`pg_dump` output, never edited. `000001_baseline_public.sql` is the
**restore-ready copy** that will actually be applied.

| Field | `…raw.sql` (audit) | `…​.sql` (restore-ready) |
|---|---|---|
| Size | 882,947 bytes | 881,734 bytes |
| Lines | 21,902 | 21,890 |
| SHA-256 | `c6cad4aec611ae7e252fb77392decc9a335e21ea099b4d4ed0628caeecff9970` | `9e9cb60148519f8b14eee0471b58810ac94ce9dfba35aa6418eb7a905a7f0234` |
| `pg_dump` exit code | 0 | — derived |
| Completeness marker | ends with `-- PostgreSQL database dump complete` | same |

**The raw copy is unchanged.** Its SHA-256 was re-verified after the
restore-ready copy was produced and after every subsequent analysis pass, and
still matches the checksum recorded at Stage 3B.

### Approved transformations (exactly 13 lines, nothing else)

`diff` between the two files shows one replacement and twelve deletions:

1. **Line 26** — `CREATE SCHEMA public;` → `CREATE SCHEMA IF NOT EXISTS public;`
   Production already owns the `public` schema, so the original statement would
   abort the apply on its first statement under `ON_ERROR_STOP=1`.

2. **12 statements removed** — every
   `ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public …`
   (raw lines 21854-21857, 21871-21874, 21891-21894). Supabase's `postgres`
   role is not a member of `supabase_admin`, so these would fail with
   `42501`. Removal is safe because production **already has byte-identical
   defaults**, verified read-only on 2026-07-30 against `pg_default_acl`:

   | Object type | Dump grants `ALL` = | Production already has, for all four roles |
   |---|---|---|
   | SEQUENCES | `rwU` | `rwU` |
   | FUNCTIONS | `X` | `X` |
   | TABLES | `arwdDxtm` | `arwdDxtm` |

   Equivalence is exact, not merely "stronger". The pg_dump section-header
   comments above the deleted statements were left in place so the diff stays
   minimal and auditable.

Everything else is byte-identical. Verified unchanged in the restore-ready copy:
198 `GRANT`, 176 `REVOKE`, the 6 `ALTER DEFAULT PRIVILEGES FOR ROLE postgres`
statements, 30 `ENABLE ROW LEVEL SECURITY`, 72 `CREATE POLICY`, 193
`CREATE FUNCTION`, 30 `CREATE TABLE`, 73 `CREATE TRIGGER`, 141
`SECURITY DEFINER`, `COMMENT ON SCHEMA public`, both psql meta-commands, all
four Migration 132 objects, and every dormant/legacy function. No function body,
`search_path`, trigger, constraint, index, policy, table definition or role name
was altered.

Command shape used (connection string supplied through an environment variable
and never recorded):

```
pg_dump --schema-only --schema=public --no-owner --format=plain \
        --file=/out/000001_baseline_public.sql "$PGURL"
```

`--data-only`, `--clean`, `--if-exists` and `--no-privileges` were **not** used.
Privileges are deliberately retained because RLS policies and the Edge
Function's `service_role` access depend on them.

## Why a dump is authoritative rather than replaying migrations

The base tables — `customers`, `therapists`, `rooms`, `services`,
`appointments`, `transactions`, `profiles`, `settings` — were created through
the Supabase dashboard and exist in **no** migration file. Replaying migrations
against an empty project fails immediately. In addition there are two parallel,
non-authoritative migration stores (`supabase/sql/NNN_*.sql` and
`supabase/migrations/<timestamp>_*.sql`) containing pointer files (`\ir`
includes), 21 content-free `remote_ledger_placeholder` stubs, rollback twins,
and version-string drift from MCP-applied migrations. The migration ledger
begins at `040_…`; everything before that exists only in the database.

This dump therefore records what the tested staging database *is*, not what the
migration history claims it should be.

## Object reconciliation against staging

Verified after Migration 132 was applied to staging. Every count reconciles:

| Object | Staging | In dump | Notes |
|---|---|---|---|
| Base tables | 30 | 30 | — |
| Functions | 193 | 193 | includes overloads; 141 are `SECURITY DEFINER` |
| RLS policies | 72 | 72 | — |
| Tables with RLS enabled | 30 / 30 | 30 | `ENABLE ROW LEVEL SECURITY` × 30 |
| Triggers | 73 | 73 | — |
| Enum types | 7 | 7 | — |
| Indexes | 104 | 60 + 44 | 60 standalone `CREATE INDEX`/`CREATE UNIQUE INDEX`; the other 44 are created implicitly by their PRIMARY KEY (30) and UNIQUE (14) constraints |
| Constraints | 169 | 169 | 69 FK + 30 PK + 14 UNIQUE + 56 CHECK (55 inlined in `CREATE TABLE`, 1 as `ALTER TABLE`) |
| `ALTER … OWNER TO` | — | 0 | `--no-owner` confirmed effective |

## Migration 132 is included

`132_admin_only_service_management` was applied to staging on 2026-07-30 and is
present in this dump:

- policy `services_insert_admin` (INSERT, `is_admin()`)
- policy `services_update_admin` (UPDATE, `is_admin()`)
- function `protect_therapist_commission_overrides()` (`SECURITY INVOKER`,
  `search_path=public`, EXECUTE revoked from `public`/`anon`/`authenticated`)
- trigger `therapists_commission_overrides_admin_only`
- the superseded policy `services_insert_staff_admin` is **absent** (0 occurrences)

### Ledger drift for Migration 132

The local filename is `20260729151927_admin_only_service_management.sql`; the
remote ledger recorded it as version **`20260730091109`** because it was applied
through MCP rather than `supabase db push`. Content is byte-identical to the
copy in `v1.0.0-rc1` (SHA-256 `4aaba33856ce777a93efa02e94a849007408c82fe841da721380b6da468d77ef`,
git blob `9505bf7bb4704ef374cec7126792ddbb097726ea`). This is the 13th instance
of such drift in this project and has no effect on the dump.

## Migrations intentionally NOT applied

Both are present in `v1.0.0-rc1` and both were verified as never applied to
staging. Applying either would **regress** the system, so neither is part of
this baseline.

- **`115_midnight_booking_and_daily_queue_repair`** — line 93 redefines
  `create_public_booking_hold_v2`, which has since been reworked by the applied
  migrations `online_hold_concrete_resources`, `129_hour_aligned_capacity_slots`,
  `130_selling_fast_counts_online_only` and
  `131_earliest_available_capacity_candidate`. Running it would overwrite the
  current online-booking hold function with the 2026-07-23 version and break the
  public booking path.
- **`111_fix_group_walkin_start_and_receipt_allocation`** — redefines
  `project_appointment_end_on_actual_start` with a version older than the applied
  `122l_fix_operational_window_timezone_cast`, and ends with a stale data-repair
  `UPDATE`.

### Known consequence of not applying 115

`validate_appointment_business_window` and its trigger
`appointments_validate_business_window` do not exist. No database object enforces
an appointment business-hours window; enforcement is advisory, in slot generation
(`get_counter_capacity_slots`, `get_available_slots`,
`get_public_booking_slots_v2` all read business hours), plus
`prevent_staff_hours_on_closed_day` for staff hours. The residual exposure is a
hand-crafted Data API insert by an authenticated staff user. Accepted for this
release as a documented low-severity gap. If it is ever addressed, the function
and trigger must be extracted into a **new forward migration** — never applied
from 115 itself.

### Known consequence of not applying 111

Of the group payment RPCs, only `pay_appointment_group_addons` embeds
`appointmentId` in `service_items`. Per-pax receipt allocation now flows through
explicit RPC parameters (`p_per_appointment_updates`, `p_pax_updates`,
`p_appointment_ids`, `p_addon_items_by_appointment`), and no Flutter code path
reads `appointmentId` from transaction `service_items`. 111's trigger is
superseded by design, not missing.

## Dormant and legacy functions retained deliberately

Preserved so the baseline faithfully reproduces the tested staging schema and
keeps rollback paths intact. No schema object was manually pruned.

`allocate_provisional_slots_unfiltered_rooms_legacy`,
`capacity_feasible_119b_legacy`, `create_appointment_with_csp_121_legacy`,
`update_appointment_with_csp_121_legacy`,
`update_appointment_group_with_csp_concrete_legacy`,
`finalize_and_start_appointment_core_124_legacy`,
`finalize_and_start_appointment_core_126_legacy`,
`finalize_and_start_appointment_122t_capacity_first_dormant`,
`finalize_and_start_appointment_core_122t_capacity_first_dormant`,
`finalize_and_start_appointment_group_122t_capacity_first_dorman` (name truncated
by PostgreSQL's 63-byte identifier limit), plus the
`allocate_preference_provisional_slots_122r_impl`,
`get_counter_preference_capacity_slots_122r_impl` and
`validate_one_based_capacity_requirements_122s` helpers.

**Do not prune by name pattern.** Several `_v1` / `_v2` functions are live and
called by the deployed `booking-api`, including `list_public_booking_outlets_v2`,
`create_public_booking_hold_v2`, `get_public_booking_slots_v2`,
`get_public_booking_dates_v2`, `get_public_booking_hold_status_v2`,
`create_public_booking_group_hold_v1`,
`get_public_booking_group_slot_status_v1`, `get_public_booking_group_status_v1`
and `claim_billplz_bill_v2`.

## What `000001` does NOT contain

Confirmed by search of the generated file.

**No operational row data.** `COPY` = 0, `INSERT INTO` = 0, `setval` = 0. None
of the staging customers (20), appointments (377), transactions (225), booking
holds (113), audit rows (4,601), therapist queue rows, dummy `auth.users` (2) or
`profiles` (2) are present. No dummy Storage files (19 objects in staging's
`app-images`) and no Vault secret values.

**No references to any other schema's objects**, other than two legitimate
foreign keys to `auth.users(id)`:

- line 19104 — `appointments.resources_confirmed_by`
- line 19360 — `profiles.id` (`ON DELETE CASCADE`)

Counts of `storage.`, `vault.`, `cron.`, `realtime.`, `extensions.` references:
**0 each**. `auth.uid()` appears 79 times inside RLS policies and functions,
which is expected and correct.

**No `CREATE EXTENSION`** (0) and **no `CREATE EVENT TRIGGER`** (0), because
`--schema=public` excludes them. Production currently lacks `pg_cron` and
`pg_net`; `000003_cron.sql` must install them.

**No secrets or environment values.** Searches for `hvyzexmsaxwendcexehx`,
`erjttzhownsxohpvzjbs`, `aws-1-ap-northeast-1`, `pooler.supabase.com`,
`localhost`, `127.0.0.1`, `sandbox`, `billplz.com`, `postgresql://`,
`PGPASSWORD`, `sb_secret`, `sb_publishable`, `eyJ` and `password` each returned
**0 matches**.

## Schemas omitted from `000001`, and the companion files still required

`--schema=public` captures only the `public` schema. The three companion files
now exist as drafts. **None has been applied anywhere.**

### `000002_storage.sql` — DRAFT, complete and believed applyable

Recreates the `app-images` bucket (`public=true`, 5,242,880-byte limit, MIME
`image/jpeg,image/png,image/webp`) and the three `storage.objects` policies
`app_images_staff_insert`, `app_images_staff_update`, `app_images_staff_delete`.
Idempotent. Copies **no** files — staging's 19 dummy objects are not referenced.

Confirmed: **no SELECT policy is needed.** The bucket is public, so Supabase
serves `/storage/v1/object/public/...` without consulting `storage.objects` RLS.
Migration 015's own comment states this.

One faithfully-reproduced wart is flagged in the file: the three policies are
named "staff" but their predicate is only `bucket_id = 'app-images'` — they do
**not** call `is_staff_or_admin()`, so any authenticated user can write to the
bucket. This matches staging exactly and was not tightened unilaterally.

### `000003_cron.sql` — DRAFT, deliberately split into three sections

- **Section A — extensions.** Installs `pg_cron` (schema `pg_catalog`) and
  `pg_net` (schema `extensions`); asserts `supabase_vault` is present rather
  than creating it. Safe during baseline application. Production currently has
  neither `pg_cron` nor `pg_net`; `pg_net` will land at 0.20.4 against staging's
  0.20.3.
- **Section B — jobs 1 and 2.** `reconcile-upcoming-appointment-assignments`
  (`*/5 * * * *`) and `expire-stale-booking-holds` (`*/10 * * * *`). Database
  calls only, no network, no secrets. Safe during baseline application; guarded
  so it refuses if the target functions are missing.
- **Section C — job 3, `cancel-expired-billplz-holds` (`*/2 * * * *`).**
  **Must NOT be run during baseline application.** It makes outbound HTTP calls
  and is fenced off until (1) `booking-api` is deployed to production,
  (2) `BOOKING_CLEANUP_SECRET` is set, (3) Vault entry `booking_api_url` exists,
  (4) Vault entry `booking_cleanup_secret` exists. The section raises a clear
  exception rather than scheduling if any is missing, and additionally refuses if
  `booking_api_url` contains the staging ref. Contains no secret values and no
  URLs — both are read from Vault at execution time, inside the scheduled
  command, so nothing sensitive is stored in `cron.job.command`.

Job 2 is **knowingly redundant and kept anyway**:
`claim_expired_billplz_cancellations()` opens its body with
`perform public.expire_stale_booking_holds();`, so job 3 already does job 2's
work five times as often. Job 2 is retained as the database-only fallback that
still releases therapist and room capacity if pg_net, Vault or the Edge Function
is down. No conflict is possible — the expiry is idempotent, and duplicate
Billplz cancellation is prevented by a claim token plus `FOR UPDATE SKIP LOCKED`
rather than by scheduling.

Re-running never duplicates a job: each is unscheduled by name first.

### `000004_seed_configuration.sql` — DRAFT, **deliberately not runnable**

This file opens with an execution guard that raises an exception, and it will
stay that way until the configuration decisions are resolved. Inspection of
staging found its configuration is substantially **test data**, so seeding it
would put wrong prices and wrong staff in front of paying customers.

It contains the FK-ordered structure, the UUID strategy, the full inventory of
staging's configuration with a per-table assessment, and a `TODO(DECISION)`
marker at every unconfirmed value. No business value is invented anywhere.

Unresolved decisions recorded in the file: `capacity_first_enabled` for both
outlets; online-booking enablement per outlet; the authoritative service list
(3 rows are literally named `test`/`testing`/`test2`, and one has the spelling
error "Traditonal"); room `total_slots`; the entire therapist roster (all 13 rows
have placeholder phones `a`/`-`, rotation numbers embedded in names, and one male
name recorded as gender Female); the SST matrix (pv128 inclusive vs taman-wahyu
exclusive, differing rounding modes, addon SST disabled on one outlet);
`settings.business_name` (currently the abbreviation `TBW`); business hours
(taman-wahyu Wednesday closes 23:55); `minimum_advance_minutes` (pv128 is 1
minute); and two reasonless full-day closures.

**One finding requires attention before any seeding.** pv128's public
online-booking card "Body Massage", priced RM240.00, is linked to the internal
service "Head Massage" (RM12.00, 21 minutes). A customer paying RM240 would be
booked a 21-minute head massage and would consume a `foot_chair` slot. The card
is currently `enabled = false`, which is the only thing preventing customer harm.
It must not be seeded in this state.

`service_commissions` must remain `'{}'::jsonb` on every therapist — it is
deprecated, and a non-empty map is read by nine scheduling functions as an
exclusive eligibility whitelist. Rates belong in `commission_overrides`. All 13
staging rows already satisfy this, and the trigger
`therapists_service_commissions_stay_empty` (arriving with `000001`) enforces it.

Also not carried by a `public` dump and required separately: `auth.users` (real
staff accounts created through Supabase Auth, using **production** UUIDs, never
staging's), Vault entries, Edge Function secrets, and Realtime publication
membership. Staging publishes exactly one application table to
`supabase_realtime`: `public.notifications`.

Also not carried by a `public` dump and required separately: `auth.users` (real
staff accounts, created through Supabase Auth — production UUIDs, never
staging's), Vault entries, Edge Function secrets, and Realtime publication
membership. Staging publishes exactly one application table to
`supabase_realtime`: `public.notifications`.

## Applying this baseline (NOT YET DONE — production is untouched)

Nothing in this directory has been applied to any project. The production
project `erjttzhownsxohpvzjbs` has never been written to: every inspection of it
was a read-only `SELECT`.

Application order, one file at a time, verifying after each before moving on:

| # | File | Notes |
|---|---|---|
| 1 | `000001_baseline_public.sql` | the restore-ready copy, **never** `…raw.sql` |
| 2 | `000002_storage.sql` | bucket + `storage.objects` policies |
| 3 | `000003_cron.sql` | **Sections A and B only.** Section C is deferred |
| 4 | *(Auth users + `profiles`)* | must precede `000004`; `profiles.id` FKs to `auth.users(id)` |
| 5 | `000004_seed_configuration.sql` | blocked by its own guard until decisions are resolved |
| 6 | `000003_cron.sql` Section C | only after `booking-api` is deployed and both Vault entries exist |

```
psql -v ON_ERROR_STOP=1 -f 000001_baseline_public.sql "$PRODUCTION_DATABASE_URL"
```

`000001` contains two psql meta-commands, `\restrict` (line 5) and
`\unrestrict` (line 21889 in the restore-ready copy; 21901 in the raw copy),
introduced in the August 2025 PostgreSQL security releases. It **must** be
applied with **psql 17.6 or newer**; an older client fails with
`invalid command \restrict`. The `postgres:17` image used to produce the dump
ships psql 17.10 and is suitable.

`--single-transaction` is recommended for `000001` so a mid-file failure leaves
production untouched, and is **not** recommended for `000003`, where
`CREATE EXTENSION pg_cron` and `cron.schedule()` are better run outside a
wrapping transaction.

Two ordering constraints worth restating because getting them wrong is
expensive: real Auth users must exist before `profiles` rows are seeded, and
`000004` must run on a privileged connection — after `000001`, only an admin can
write `therapists.commission_overrides`.

## File manifest (Stage 3D final state, 2026-07-30)

| File | Bytes | Lines | SHA-256 |
|---|---|---|---|
| `000001_baseline_public.raw.sql` | 882,947 | 21,902 | `c6cad4aec611ae7e252fb77392decc9a335e21ea099b4d4ed0628caeecff9970` |
| `000001_baseline_public.sql` | 881,734 | 21,890 | `9e9cb60148519f8b14eee0471b58810ac94ce9dfba35aa6418eb7a905a7f0234` |
| `000002_storage.sql` | 6,979 | 167 | `c1d611de92088433…` (write policies tightened, Stage 3D) |
| `000003_cron.sql` | 11,259 | 244 | `a67acd1d8160c3bc2184a3112fe902f178a9ecfd0ab0379bf4c2f850d6a59b37` |
| `000004_seed_configuration.sql` | 39,148 | 680 | `99413d400a4468e7…` (finalised, guard removed, Stage 3D) |
| `image_migration_manifest.md` | 6,270 | 105 | `b6ebbf57dce4c641…` |

## Stage 3D revision 2 — final amendments

Six amendments were applied after the first Stage 3D pass. Every one is reflected
in the files and in the sections below.

| # | Amendment | Effect |
|---|---|---|
| 1 | Public booking close raised from 19:00 | **19:30** — the exact value at which all five cards reach an 18:00 last start. 20:00 would have exposed a 19:00 start on the shorter services. |
| 2 | `Traditonal` → `Traditional` | Corrected at source in `services.name`, so internal and public naming now agree; no `public_name` workaround remains. |
| 3 | Foot massage belongs in a foot chair | The 75 and 90-minute Foot Massage records moved `body_room` → `foot_chair`. Card→room mappings grew from 6 to **8**. |
| 4 | Duplicate images accepted | Five files still migrated individually so each service keeps its own path and can be given a distinct image later. |
| 5 | Zero PV128 services accepted | PV128 keeps outlet, hours, SST and rooms; catalogue stays empty and online booking disabled. |
| 6 | Controlled test therapists approved | New `000005_controlled_smoke_test_data.sql` + `000005_cleanup_smoke_test_data.sql`, kept out of `000004`. |

**Capacity consequence of amendment 3.** Foot-chair demand now spans three
services drawing on Ground Floor (7) + Upper Foot (5) = 12 concurrent chairs.
Body-room demand narrows to the two Traditional Body Massage services on Upper
Massage Room (8); Ground Massage Room stays inactive.

### `000005` — controlled smoke-test data (separate approval required)

Five clearly-labelled temporary rows at Taman Wahyu, every name beginning
`PRODUCTION TEST —`, seeding **40 rows across 2 tables** (5 therapists + 35
working-hour rows).

Four therapists is the floor, not a convenience: queue rotation needs three or
more to visibly advance, switching needs a third free while two are engaged, and
a concurrent two-pax booking with per-pax gender preference needs two of each
gender — hence 2 male + 2 female. The fifth row is a `Counter` record, required
because `transactions.counter_staff_id` is a foreign key to `therapists(id)`.

No personal information: `phone` is `NULL`, no images, no real names.
`service_commissions` and `commission_overrides` are never written and keep their
`'{}'` defaults. Nothing operational is pre-seeded — no customers, appointments,
transactions, holds or queue rows.

Findable three independent ways: id range `ffffffff-0000-…`, name prefix
`PRODUCTION TEST —`, or `notes = 'CONTROLLED SMOKE TEST — remove before go-live'`.

`000005_cleanup_smoke_test_data.sql` removes only those five and their temporary
scheduling/queue records. It **refuses to run** while any appointment,
transaction or allocation still references a test therapist — deleting a
therapist would otherwise null the cashier on a test receipt via
`ON DELETE SET NULL` rather than fail. All 14 column references were verified to
exist before the script was written.

## Stage 3D — confirmed business configuration

`000004_seed_configuration.sql` is now **runnable**: the Stage 3C execution guard
has been removed because every business value is confirmed. `000002_storage.sql`
diverges from staging in exactly one deliberate way (write policies).

**Business identity.** Name is `The Best Family Wellness`. Verified 2026-07-30
against the official site `thebestwellness.my`, which is linked from the official
Linktree (`linktr.ee/thebestwellness`), and it matched the product owner's
supplied values exactly for both branches.

| Branch | Address | Trading hours |
|---|---|---|
| Taman Wahyu / Kepong | 50G, Jalan Seri Utara 1, Taman Wahyu, 68100 Kuala Lumpur | Mon-Thu 11:00-23:00, Fri-Sun 11:00-23:30 |
| PV128 / Setapak | G13-A, PV128, Jalan Genting Kelang, Setapak, 53300 Kuala Lumpur | Daily 10:30-23:00 |

**Google Maps could not be machine-verified.** Its listing pages are JavaScript
applications and returned no readable content to a fetcher. Two naming variants
were observed on the Maps links themselves — the Kepong listing is titled
"The Best Massage Family Wellness" and the Setapak one "The Best Family Wellness
@ Setapak" — but neither address nor hours could be read from Maps. The official
website was used as the authoritative source instead.

**Online booking closes at 19:00**, not at the trading close. Only the public
window is shortened; the counter trades until 23:00/23:30. Because a service must
finish inside the public window and the grid is hourly, the last available start
differs per card: 18:00 for the 50-minute and 60-minute services, **17:00** for
the 75, 80 and 90-minute services. "Last booking 6pm" is therefore true only for
the two shorter services — recorded as an open decision.

**Five Taman Wahyu services selected**, by the stated rule (Taman Wahyu outlet,
real non-empty `image_url`, not a test row, not duplicated or mislinked). The
query returned exactly five, so no judgement was required.

| Service ID | Name | Price | Duration | Room type | Therapist / counter commission |
|---|---|---|---|---|---|
| `83893724-…` | Foot Massage | RM39.00 | 50 min | `foot_chair` | 20 / 4 |
| `a5f9c703-…` | Foot Massage | RM59.00 | 75 min | `body_room` | 25 / 5 |
| `edd2553e-…` | Foot Massage | RM78.00 | 90 min | `body_room` | 30 / 6 |
| `4af490ba-…` | Traditional Body Massage | RM99.00 | 60 min | `body_room` | 35 / 7 |
| `c5c786c0-…` | Traditonal Body Massage | RM129.00 | 80 min | `body_room` | 40 / 8 |

Service-level commission lives in `services.therapist_commission` and
`services.counter_commission` — both preserved above. No therapist
`commission_overrides` are seeded, and the deprecated `service_commissions` is
never written.

**Two data-quality issues inside the five**, reported rather than silently fixed:
`Traditonal Body Massage` is misspelt in the internal record (the public card
publishes the correct spelling), and three services share the name "Foot Massage"
with two of them mapped to `body_room` rather than `foot_chair`.

**Rooms and capacity preserved verbatim for both outlets** — PV128's four zones
plus six numbered units were confirmed accurate by the product owner and are now
included. 8 rooms, 14 room units, no capacity value changed. Taman Wahyu's
`Ground Massage Room` is carried over `is_active = false`, exactly as in staging.

**PV128 remains non-operational for bookings.** Outlet record, business hours,
SST and rooms are seeded; its service catalogue is not, and online booking is
disabled with no public cards. With no services there is nothing to book.

**Zero therapists are seeded.** All 13 staging records are placeholders. This
blocks therapist assignment, queue seeding, check-in, start-service, therapist
switching, counter booking, walk-ins and all online booking, since public
availability resolves against eligible therapists.

**Zero closure rows.** Staging's two full-day taman-wahyu closures are not
carried over and no replacements were added.

**Images are seeded NULL** and migrated separately per
`image_migration_manifest.md`: five service images plus the business logo, six
objects of nineteen, paths preserved unchanged. The five public cards reuse their
service image rather than a second copy.

### `000002_storage.sql` — one deliberate divergence from staging

Staging's three `storage.objects` policies are named "staff" but check only
`bucket_id`, so any authenticated user can write. Production adds
`public.is_staff_or_admin()` to INSERT, UPDATE and DELETE, keeping the
`bucket_id` condition. Public reads are unaffected because the bucket is public
and public-bucket reads bypass `storage.objects` RLS. A guard fails loudly if
`000001` has not been applied, since `is_staff_or_admin()` comes from it.

### Safety-scan correction applied to `000003_cron.sql`

The first draft of Section C guarded the Vault URL with
`if v_url like '%<staging-ref>%' then raise` — which placed a staging project
reference inside **executable** SQL, not a comment. That was replaced with a
positive assertion against the production ref:

```sql
if v_url not like '%erjttzhownsxohpvzjbs%' then
  raise exception 'Vault entry "booking_api_url" does not point at the Treats
    Production project. Refusing to schedule a production job against another
    target.';
end if;
```

Stronger as well as compliant: it rejects *any* wrong target rather than only
the one target we thought to blacklist. After this change, the staging ref
appears nowhere in executable SQL in any file — only in provenance comments
(`000002` ×1, `000003` ×2, `000004` ×1) and in this README ×2.

## This baseline is not approved

`000001`, `000002` and `000003` are believed complete and correct.
`000004_seed_configuration.sql` is not, and the baseline as a whole cannot be
called production-approved until the configuration decisions listed above are
resolved by the product owner. The raw dump remains unedited as the audit
reference for everything derived from it.
