-- ============================================================================
-- 000004_seed_configuration.sql  —  Real business configuration
-- ============================================================================
-- Target : erjttzhownsxohpvzjbs  (Treats PRODUCTION, ap-southeast-1 / Singapore)
-- Derived: read-only inspection of staging hvyzexmsaxwendcexehx, 2026-07-30,
--          plus product-owner decisions recorded in the Stage 3D approval.
-- Status : RUNNABLE. The Stage 3C execution guard has been removed because
--          every business value below is now confirmed.
--
-- Business identity verified 2026-07-30 against the official site
-- thebestwellness.my, which is the site linked from the official Linktree
-- (linktr.ee/thebestwellness). Google Maps' own listing pages could not be
-- machine-read (they are JavaScript applications and serve no content to a
-- fetcher), so Maps hours were NOT independently confirmed — see the Stage 3D
-- report. The official website matched the product owner's supplied values
-- exactly, for both branches, so those values are used.
--
-- CONTAINS NO OPERATIONAL DATA. No customers, profiles, auth.users,
-- appointments, appointment_groups, appointment_therapist_allocations,
-- appointment_therapist_segments, transactions, booking_holds, notifications,
-- audit_log, therapist_queue, therapist_queue_day, or payment rows.
--
-- CONTAINS NO THERAPISTS. See SECTION 9 — this is deliberate and blocking for
-- several later smoke tests.
--
-- CONTAINS NO STORAGE URLs. Image columns are seeded NULL and are populated
-- later from image_migration_manifest.md, after 000002_storage.sql is applied.
--
-- CONTAINS NO CLOSURE ROWS. online_booking_closures is intentionally empty.
--
-- Idempotent: every statement is INSERT … ON CONFLICT (id) DO UPDATE, so the
-- file may be re-run safely. Transactional: a single BEGIN/COMMIT, so any
-- failure leaves production untouched.
--
-- PRIVILEGE REQUIREMENT: run as `postgres`. After 000001, Migration 132's
-- trigger `therapists_commission_overrides_admin_only` and the admin-only
-- services policies mean a non-admin session cannot write parts of this file.
-- ============================================================================


begin;


-- ============================================================================
-- SECTION 1 — FOREIGN-KEY ORDERING (do not reorder)
-- ============================================================================
--   1. outlets                        root
--   2. settings                       global, no outlet FK
--   3. business_hours               -> outlets
--   4. business_settings            -> outlets
--   5. service_categories           -> outlets
--   6. services                     -> outlets, service_categories(by name)
--   7. rooms                        -> outlets
--   8. room_units                   -> rooms (via zone_id), outlets
--   9. online_booking_outlet_settings -> outlets
--  10. online_booking_services      -> outlets, services
--  11. online_booking_service_rooms -> online_booking_services, rooms
--
-- Deliberately absent: therapists, therapist_working_hours,
-- therapist_unavailability, online_booking_closures, online_booking_service_hours,
-- profiles. Each is explained in its own section below.


-- ============================================================================
-- SECTION 2 — ID STRATEGY
-- ============================================================================
-- All identifiers below are LITERAL and carried over from staging. This is a
-- deliberate change from the Stage 3C draft, for three concrete reasons:
--
--   (a) Auditability. A literal id can be diffed against staging and against
--       this file. A gen_random_uuid() seed cannot be re-verified after the
--       fact.
--   (b) Idempotency. ON CONFLICT (id) DO UPDATE only works with stable ids.
--   (c) Image paths. Storage objects live at services/<service_id>/<file>, so
--       preserving the five service ids lets the migrated objects keep their
--       existing safe paths, as instructed.
--
-- Reusing these ids imports NO data: production has zero appointments, zero
-- transactions and zero holds, so no staging row id can resolve to anything
-- operational. Outlet ids are hand-crafted and deterministic in staging
-- (…000128 / …000002) and are preserved verbatim.
--
-- online_booking_services.id intentionally MIRRORS its services.id, 1:1, so the
-- card→service mapping is self-evident in every query and cannot silently drift
-- the way staging's did (staging has a card named "Body Massage" priced RM240
-- pointing at a RM12 21-minute "Head Massage").


-- ============================================================================
-- SECTION 3 — outlets
-- ============================================================================
-- Both real branches retained. PV128 is NOT deleted; see SECTION 12 for its
-- limited operational status.
--
-- `outlets` has no address column (verified: id, code, name, is_active, plus
-- audit columns). Street addresses are therefore recorded in this file's
-- comments and in the README, and belong in the app's Business Settings screen
-- once a field exists. They are NOT invented into a column that does not exist.
--
--   pv128        G13-A, PV128, Jalan Genting Kelang, Setapak, 53300 Kuala Lumpur
--                phone 012-7449 266
--   taman-wahyu  50G, Jalan Seri Utara 1, Taman Wahyu, 68100 Kuala Lumpur
--                phone 012-5262 551

insert into public.outlets (id, code, name, is_active) values
  ('00000000-0000-0000-0000-000000000128', 'pv128',       'PV128',       true),
  ('00000000-0000-0000-0000-000000000002', 'taman-wahyu', 'Taman Wahyu', true)
on conflict (id) do update set
  code = excluded.code, name = excluded.name, is_active = excluded.is_active;


-- ============================================================================
-- SECTION 4 — settings  (global business identity)
-- ============================================================================
-- business_name corrected from staging's placeholder 'TBW' to the official
-- name. `location` is the single generic field, so 'Kuala Lumpur' is used as
-- instructed; per-branch addresses are in SECTION 3's comments.
--
-- logo_url is seeded NULL on purpose. Staging's value points at the staging
-- project. The genuine logo object is listed in image_migration_manifest.md and
-- is copied across after 000002 is applied.

insert into public.settings (id, business_name, location, logo_url) values
  ('business', 'The Best Family Wellness', 'Kuala Lumpur', null)
on conflict (id) do update set
  business_name = excluded.business_name,
  location      = excluded.location;
  -- logo_url deliberately NOT overwritten on re-run: once the real logo has
  -- been migrated, re-running this file must not blank it again.


-- ============================================================================
-- SECTION 5 — business_hours  (per weekday)
-- ============================================================================
-- day_of_week follows PostgreSQL DOW: 0 = Sunday … 6 = Saturday. Confirmed by
-- matching staging's existing taman-wahyu pattern against the published
-- Mon–Thu / Fri–Sun split; only Wednesday deviated.
--
-- CONFIRMED HOURS (official site, matching the product owner's instruction):
--
--   Taman Wahyu / Kepong   Mon–Thu 11:00–23:00,  Fri–Sun 11:00–23:30
--   PV128 / Setapak        Mon–Sun 10:30–23:00
--
-- CHANGES FROM STAGING — both deliberate corrections, not drift:
--   * taman-wahyu Wednesday was 23:55 in staging -> 23:00 here.
--   * pv128 was 00:00–00:30 (past midnight) on six of seven days in staging
--     -> 23:00 here on all seven. This REMOVES pv128's overnight window.
--     Flagged in the Stage 3D report: it changes overnight-appointment
--     behaviour relative to what was smoke-tested on staging.

delete from public.business_hours
 where outlet_id in ('00000000-0000-0000-0000-000000000128',
                     '00000000-0000-0000-0000-000000000002');

insert into public.business_hours (outlet_id, day_of_week, open_time, close_time, is_closed) values
  -- Taman Wahyu: Sun 23:30, Mon-Thu 23:00, Fri-Sat 23:30
  ('00000000-0000-0000-0000-000000000002', 0, '11:00', '23:30', false),
  ('00000000-0000-0000-0000-000000000002', 1, '11:00', '23:00', false),
  ('00000000-0000-0000-0000-000000000002', 2, '11:00', '23:00', false),
  ('00000000-0000-0000-0000-000000000002', 3, '11:00', '23:00', false),
  ('00000000-0000-0000-0000-000000000002', 4, '11:00', '23:00', false),
  ('00000000-0000-0000-0000-000000000002', 5, '11:00', '23:30', false),
  ('00000000-0000-0000-0000-000000000002', 6, '11:00', '23:30', false),
  -- PV128: every day 10:30-23:00
  ('00000000-0000-0000-0000-000000000128', 0, '10:30', '23:00', false),
  ('00000000-0000-0000-0000-000000000128', 1, '10:30', '23:00', false),
  ('00000000-0000-0000-0000-000000000128', 2, '10:30', '23:00', false),
  ('00000000-0000-0000-0000-000000000128', 3, '10:30', '23:00', false),
  ('00000000-0000-0000-0000-000000000128', 4, '10:30', '23:00', false),
  ('00000000-0000-0000-0000-000000000128', 5, '10:30', '23:00', false),
  ('00000000-0000-0000-0000-000000000128', 6, '10:30', '23:00', false);


-- ============================================================================
-- SECTION 6 — business_settings  (SST, capacity mode, lateness rules)
-- ============================================================================
-- SST PRESERVED EXACTLY as staging has it, per instruction. The two outlets are
-- deliberately NOT normalised: pv128 is inclusive/nearest_cent with add-on SST
-- disabled; taman-wahyu is exclusive/nearest_10_sen with add-on SST exclusive.
-- Both are 8.00%, both enabled, and both use inclusive for Billplz.
--
-- capacity_first_enabled = false for BOTH outlets, per decision 1. This is the
-- tested MVP concrete-locking path; the app's counter UI is built around it.
--
-- open_time/close_time here mirror SECTION 5's envelope for each outlet.

insert into public.business_settings (
  id, outlet_id, open_time, close_time,
  sst_enabled, sst_pricing_mode, sst_rate_percent, sst_rounding_mode,
  billplz_sst_pricing_mode, counter_sst_pricing_mode,
  appointment_addon_sst_pricing_mode,
  late_grace_minutes, no_show_threshold_minutes,
  auto_extend_late_arrivals, delay_warning_minutes,
  capacity_first_enabled
) values
  (1, '00000000-0000-0000-0000-000000000128',
   '10:30', '23:00',
   true, 'inclusive', 8.00, 'nearest_cent',
   'inclusive', 'inclusive',
   'disabled',
   10, 25,
   true, 5,
   false),
  (2, '00000000-0000-0000-0000-000000000002',
   '11:00', '23:30',
   true, 'exclusive', 8.00, 'nearest_10_sen',
   'inclusive', 'exclusive',
   'exclusive',
   15, 30,
   true, 10,
   false)
on conflict (id) do update set
  outlet_id                          = excluded.outlet_id,
  open_time                          = excluded.open_time,
  close_time                         = excluded.close_time,
  sst_enabled                        = excluded.sst_enabled,
  sst_pricing_mode                   = excluded.sst_pricing_mode,
  sst_rate_percent                   = excluded.sst_rate_percent,
  sst_rounding_mode                  = excluded.sst_rounding_mode,
  billplz_sst_pricing_mode           = excluded.billplz_sst_pricing_mode,
  counter_sst_pricing_mode           = excluded.counter_sst_pricing_mode,
  appointment_addon_sst_pricing_mode = excluded.appointment_addon_sst_pricing_mode,
  late_grace_minutes                 = excluded.late_grace_minutes,
  no_show_threshold_minutes          = excluded.no_show_threshold_minutes,
  auto_extend_late_arrivals          = excluded.auto_extend_late_arrivals,
  delay_warning_minutes              = excluded.delay_warning_minutes,
  capacity_first_enabled             = excluded.capacity_first_enabled;


-- ============================================================================
-- SECTION 7 — service_categories
-- ============================================================================
-- Only the ONE category the five selected services need. Staging's taman-wahyu
-- 'Add-ons', 'Online' and 'Packages' categories are excluded because no
-- selected service belongs to them, per the instruction to keep only required
-- categories. PV128 categories are excluded entirely (SECTION 12).

insert into public.service_categories (id, outlet_id, code, name, is_active) values
  ('48624316-7b85-4c64-9b3a-33515480882f',
   '00000000-0000-0000-0000-000000000002', 'services', 'Services', true)
on conflict (id) do update set
  outlet_id = excluded.outlet_id, code = excluded.code,
  name = excluded.name, is_active = excluded.is_active;


-- ============================================================================
-- SECTION 8 — services  (the five selected Taman Wahyu records)
-- ============================================================================
-- Selection rule, applied exactly as instructed: Taman Wahyu outlet, non-null
-- and non-empty image_url, not a literal test row, not a duplicate or mislinked
-- row. The query returned EXACTLY five. No judgement was needed to reach five.
--
-- Values below are staging's confirmed values, unchanged, including
-- therapist_commission and counter_commission (the service-level commission
-- configuration — see SECTION 11).
--
-- image_url is NULL here. Real files are migrated per
-- image_migration_manifest.md and the URLs written afterwards.
--
-- TWO CORRECTIONS APPLIED, both approved by the product owner in Stage 3D:
--
--   1. NAME. 'Traditonal Body Massage' (id c5c786c0…) was misspelt in staging
--      and is corrected to 'Traditional Body Massage' here. Both body-massage
--      records now carry the same correctly-spelt name, distinguished by
--      duration and price (60 min RM99, 80 min RM129).
--
--   2. ROOM TYPE. Staging had the 75-minute and 90-minute 'Foot Massage'
--      records set to room_type = 'body_room'. A foot massage belongs in a foot
--      chair, so both are corrected to 'foot_chair'. All three Foot Massage
--      records are therefore consistent.
--
--      CAPACITY CONSEQUENCE — deliberate and worth knowing: foot-chair demand
--      now covers three services instead of one, drawing on Ground Floor (7) +
--      Upper Foot (5) = 12 concurrent chairs. Body-room demand drops to the two
--      Traditional Body Massage services, served by Upper Massage Room (8);
--      Ground Massage Room stays inactive. This also changes the card→room
--      mappings in section 13.2.
--
-- Three services still share the name 'Foot Massage', distinguished only by
-- price and duration. That is unchanged from staging and was accepted.

insert into public.services (
  id, outlet_id, name, category, price, duration, room_type,
  therapist_commission, counter_commission,
  is_active, display_order, buffer_after_minutes,
  service_description, image_url
) values
  ('83893724-c584-4603-b208-1db6db0b2ab0', '00000000-0000-0000-0000-000000000002',
   'Foot Massage',             'Services',  39.00,  50, 'foot_chair', 20, 4, true, 0, 0, 'Foot Massage', null),
  ('a5f9c703-9d80-42a6-9282-449fbdb29d65', '00000000-0000-0000-0000-000000000002',
   'Foot Massage',             'Services',  59.00,  75, 'foot_chair', 25, 5, true, 1, 0, '',             null),
  ('edd2553e-9d98-45d2-9b89-c67a2c6444c8', '00000000-0000-0000-0000-000000000002',
   'Foot Massage',             'Services',  78.00,  90, 'foot_chair', 30, 6, true, 2, 0, '',             null),
  ('4af490ba-064b-4fd4-85fd-9edba196a62d', '00000000-0000-0000-0000-000000000002',
   'Traditional Body Massage', 'Services',  99.00,  60, 'body_room',  35, 7, true, 3, 0, '',             null),
  ('c5c786c0-7a5b-4cd4-84ac-b8c7f83986dd', '00000000-0000-0000-0000-000000000002',
   'Traditional Body Massage', 'Services', 129.00,  80, 'body_room',  40, 8, true, 4, 0, '',             null)
on conflict (id) do update set
  outlet_id            = excluded.outlet_id,
  name                 = excluded.name,
  category             = excluded.category,
  price                = excluded.price,
  duration             = excluded.duration,
  room_type            = excluded.room_type,
  therapist_commission = excluded.therapist_commission,
  counter_commission   = excluded.counter_commission,
  is_active            = excluded.is_active,
  display_order        = excluded.display_order,
  buffer_after_minutes = excluded.buffer_after_minutes,
  service_description  = excluded.service_description;
  -- image_url deliberately NOT overwritten on re-run.


-- ============================================================================
-- SECTION 9 — therapists  [INTENTIONALLY EMPTY — BLOCKING FOR SMOKE TESTS]
-- ============================================================================
-- ZERO therapist rows are seeded. All 13 staging therapists are placeholders:
-- phone values are literally 'a' or '-', rotation numbers are baked into the
-- name field ('(1) Alex' … '(7) Lily', '(1) Pong' … '(5) Ong'), one male name
-- is recorded as gender Female, and PV128 has a 'Counter'-role row named
-- 'Counter'.
--
-- Also NOT seeded, all of which depend on real therapists:
--   therapist_working_hours        (91 staging rows, all placeholder-derived)
--   therapist_unavailability       (5 staging rows — operational, not config)
--   therapist_queue                (operational)
--   therapist_queue_day            (operational)
--   commission_overrides           (see SECTION 11)
--
-- ***WHAT THIS BLOCKS.*** Until real therapists and their working hours are
-- entered through the app, production CANNOT perform: therapist assignment,
-- queue seeding or rotation, check-in, start-service, therapist switching,
-- counter booking, walk-ins, or any online booking (public availability
-- resolves against eligible therapists and returns nothing without them).
-- Effectively every functional smoke test is gated on this. Entering real
-- staff is the first task after this baseline is applied.


-- ============================================================================
-- SECTION 10 — rooms and room_units  (BOTH outlets)
-- ============================================================================
-- Preserved EXACTLY, per instruction: same ids, names, room_type, total_slots,
-- active/inactive states and unit numbering. No capacity value is changed.
--
-- PV128 rooms are included: the product owner confirmed the existing PV128
-- room and capacity configuration is accurate, so it is carried over verbatim
-- alongside Taman Wahyu's.
--
--   PV128
--     Ground Body Massage Rooms  body_room   3 slots  active  3 units (Room 1..3)
--     Ground Floor Foot Zone     foot_chair  6 slots  active  0 units
--     Upper Body Massage Rooms   body_room   3 slots  active  3 units (Room 1..3)
--     Upper Floor Foot Zone      foot_chair  6 slots  active  0 units
--
--   TAMAN WAHYU
--
--   Ground Floor         foot_chair  7 slots  active    0 units
--   Ground Massage Room  body_room   3 slots  INACTIVE  0 units
--   Upper Foot           foot_chair  5 slots  active    0 units
--   Upper Massage Room   body_room   8 slots  active    8 units (Room 1..8)
--
-- 'Ground Massage Room' is carried over with is_active = false, exactly as in
-- staging. It is retained rather than dropped so its capacity can be enabled
-- later without re-creating the zone.
--
-- Only 'Upper Massage Room' has numbered units. The foot zones use slot
-- capacity without individually numbered chairs — that is staging's model and
-- is preserved.

insert into public.rooms (id, outlet_id, name, room_type, total_slots, is_active) values
  -- Taman Wahyu
  ('94263d9a-14aa-47a1-a868-4b704951a993', '00000000-0000-0000-0000-000000000002', 'Ground Floor',        'foot_chair', 7, true),
  ('d7403730-f6b7-4ed7-ae42-c7f45b6045f0', '00000000-0000-0000-0000-000000000002', 'Ground Massage Room', 'body_room',  3, false),
  ('6a48a888-7dcc-47ff-a74b-4f84a959162d', '00000000-0000-0000-0000-000000000002', 'Upper Foot',          'foot_chair', 5, true),
  ('8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Upper Massage Room',  'body_room',  8, true),
  -- PV128 (confirmed accurate by the product owner)
  ('0f1503b5-1ed8-4f65-b421-55696bdb229a', '00000000-0000-0000-0000-000000000128', 'Ground Body Massage Rooms', 'body_room',  3, true),
  ('39c75366-1205-48b2-963b-92c4b984e9c8', '00000000-0000-0000-0000-000000000128', 'Ground Floor Foot Zone',    'foot_chair', 6, true),
  ('f01292e8-928e-4256-9c81-866fff17d566', '00000000-0000-0000-0000-000000000128', 'Upper Body Massage Rooms',  'body_room',  3, true),
  ('3927cbdc-2540-4e0c-9873-cfc55c4c4182', '00000000-0000-0000-0000-000000000128', 'Upper Floor Foot Zone',     'foot_chair', 6, true)
on conflict (id) do update set
  outlet_id = excluded.outlet_id, name = excluded.name,
  room_type = excluded.room_type, total_slots = excluded.total_slots,
  is_active = excluded.is_active;

insert into public.room_units (id, zone_id, outlet_id, name, unit_number, is_active) values
  ('7e69cd81-b306-4e3f-a4d6-b1bcce7363e7', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 1', 1, true),
  ('d8227fb6-ed59-411d-94d7-151e0bb012a4', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 2', 2, true),
  ('87c6c5a1-e77e-45f7-b1bc-6ca1de9de488', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 3', 3, true),
  ('2f796fac-b1fc-4429-91eb-d82cb35b0e8e', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 4', 4, true),
  ('e75b7ee4-76c4-413e-8372-fb2a2fe958e6', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 5', 5, true),
  ('2905fa44-e334-4bc3-86b7-6db66b4a7de8', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 6', 6, true),
  ('086e6ee4-af7e-499c-ac3b-927543a96dac', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 7', 7, true),
  ('7ffe0b97-77f6-4463-b6da-f99393e2f4e0', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002', 'Room 8', 8, true),
  -- PV128 Ground Body Massage Rooms (zone 0f1503b5…)
  ('3b6d1f7d-6760-4708-bcff-57b3576c9c6a', '0f1503b5-1ed8-4f65-b421-55696bdb229a', '00000000-0000-0000-0000-000000000128', 'Room 1', 1, true),
  ('551b9624-24b2-46d8-8868-f4c5f7ed3e5c', '0f1503b5-1ed8-4f65-b421-55696bdb229a', '00000000-0000-0000-0000-000000000128', 'Room 2', 2, true),
  ('45f856d6-c55f-4a82-abe0-39ca852394a8', '0f1503b5-1ed8-4f65-b421-55696bdb229a', '00000000-0000-0000-0000-000000000128', 'Room 3', 3, true),
  -- PV128 Upper Body Massage Rooms (zone f01292e8…)
  ('17f942d8-5611-4114-9efd-5e33161df1e0', 'f01292e8-928e-4256-9c81-866fff17d566', '00000000-0000-0000-0000-000000000128', 'Room 1', 1, true),
  ('e4a1178d-2af4-4718-a414-864c3e8d8fa3', 'f01292e8-928e-4256-9c81-866fff17d566', '00000000-0000-0000-0000-000000000128', 'Room 2', 2, true),
  ('121920e5-bdff-4681-b3cf-2b7b80872cdf', 'f01292e8-928e-4256-9c81-866fff17d566', '00000000-0000-0000-0000-000000000128', 'Room 3', 3, true)
on conflict (id) do update set
  zone_id = excluded.zone_id, outlet_id = excluded.outlet_id,
  name = excluded.name, unit_number = excluded.unit_number,
  is_active = excluded.is_active;


-- ============================================================================
-- SECTION 11 — commission configuration
-- ============================================================================
-- WHERE COMMISSION LIVES, precisely:
--
--   public.services.therapist_commission   service-level therapist rate
--   public.services.counter_commission     service-level counter/cashier rate
--       -> both seeded in SECTION 8, values preserved from staging:
--          RM39/50min  20 / 4
--          RM59/75min  25 / 5
--          RM78/90min  30 / 6
--          RM99/60min  35 / 7
--          RM129/80min 40 / 8
--
--   public.therapists.commission_overrides   per-therapist, per-service rate
--       -> NOT seeded. Zero rows exist to attach them to. Staging's two
--          overrides (22% on one PV128 service, 2% on one Taman Wahyu service)
--          are deliberately NOT copied, per decision 5.
--
--   public.therapists.service_commissions    DEPRECATED. Must stay '{}'.
--       -> Not written anywhere in this file. Migration 132's sibling trigger
--          `therapists_service_commissions_stay_empty` rejects non-empty
--          writes, and every scheduling path treats a non-empty map as an
--          exclusive eligibility whitelist, which silently removes a therapist
--          from all other services.
--
-- No commission value is invented. Realised commission amounts land on
-- transactions at checkout (therapist_commission_amount,
-- counter_commission_amount) and are computed, never seeded.


-- ============================================================================
-- SECTION 12 — PV128 operational status
-- ============================================================================
-- Seeded for PV128: the outlet record (SECTION 3), business hours (SECTION 5),
-- business_settings including its own SST matrix (SECTION 6), and its four
-- rooms plus six numbered units (SECTION 10) — the product owner confirmed the
-- room and capacity configuration is accurate.
--
-- NOT seeded for PV128: service_categories, services, and any public online
-- card. Online booking stays disabled.
--
-- ***PV128 STILL CANNOT TAKE AN APPOINTMENT.*** Its rooms and capacity are now
-- correct, but with no services in its catalogue there is nothing to book, so a
-- counter booking or walk-in has no service to select. Two things are needed
-- before PV128 is operational:
--
--     1. its genuine service catalogue (names, prices, durations, room types,
--        commission rates) — the staging PV128 services were not confirmed and
--        include a literal 'test' row, an 'Eye Mask' add-on priced RM230, two
--        21-minute durations and a duplicated 'Neck Massage';
--     2. real therapists (SECTION 9), which blocks both outlets equally.
--
-- The outlet is deliberately NOT deleted, so adding the catalogue later needs no
-- schema change and no id changes.


-- ============================================================================
-- SECTION 13 — online booking
-- ============================================================================
-- Taman Wahyu ENABLED. PV128 DISABLED with no cards at all, per decision 3.
--
-- Non-booking settings preserved from staging for taman-wahyu (slot interval
-- 60, minimum advance 15 min, 7-day window, same-day allowed, customers cannot
-- pick a therapist, therapist names not public).
--
-- For pv128, online_booking_enabled = false. Its other values are carried over
-- but are inert while disabled. NOTE: staging's pv128 minimum_advance_minutes
-- was 1, which would let a customer book 60 seconds ahead; it is set to 15 here
-- to match taman-wahyu rather than preserve an untested value on a disabled
-- outlet. Flagged in the Stage 3D report.
--
-- ***ONLINE BOOKING CLOSES AT 19:30, NOT AT THE TRADING CLOSE TIME.***
-- Online booking follows the confirmed opening times but closes early so the
-- last bookable slot is 18:00. The counter still trades until 23:00/23:30 —
-- only the PUBLIC window is shortened. public_open_time keeps the real opening
-- time; public_close_time is 19:30 for both outlets.
--
-- WHY 19:30 AND NOT 19:00 OR 20:00. The engine requires a service to FINISH
-- inside the public window and the grid is hourly (slot_interval_minutes = 60).
-- 19:30 is the exact value at which every one of the five cards reaches an
-- 18:00 last start — the stated intent. 19:00 would have capped the three
-- longer services at 17:00; 20:00 would additionally expose a 19:00 start on
-- the shorter ones, past the intended cut-off.
--
--     Foot Massage 50 min   last start 18:00  (ends 18:50)
--     Traditional  60 min   last start 18:00  (ends 19:00)
--     Foot Massage 75 min   last start 18:00  (ends 19:15)
--     Traditional  80 min   last start 18:00  (ends 19:20)
--     Foot Massage 90 min   last start 18:00  (ends 19:30, exactly on close)
--
-- All five now honour "last booking 6pm".

insert into public.online_booking_outlet_settings (
  outlet_id, online_booking_enabled, public_open_time, public_close_time,
  slot_interval_minutes, minimum_advance_minutes, maximum_booking_days,
  same_day_booking_allowed, customer_therapist_selection_allowed,
  public_therapist_names_allowed
) values
  ('00000000-0000-0000-0000-000000000002', true,  '11:00', '19:30', 60, 15, 7, true, false, false),
  ('00000000-0000-0000-0000-000000000128', false, '10:30', '19:30', 30, 15, 7, true, false, false)
on conflict (outlet_id) do update set
  online_booking_enabled              = excluded.online_booking_enabled,
  public_open_time                    = excluded.public_open_time,
  public_close_time                   = excluded.public_close_time,
  slot_interval_minutes               = excluded.slot_interval_minutes,
  minimum_advance_minutes             = excluded.minimum_advance_minutes,
  maximum_booking_days                = excluded.maximum_booking_days,
  same_day_booking_allowed            = excluded.same_day_booking_allowed,
  customer_therapist_selection_allowed= excluded.customer_therapist_selection_allowed,
  public_therapist_names_allowed      = excluded.public_therapist_names_allowed;


-- ---------------------------------------------------------------------------
-- 13.1  Public cards — five NEW rows, one per selected service
-- ---------------------------------------------------------------------------
-- NOT ONE staging card is reused. Every existing taman-wahyu card points at an
-- '(Online Exclusive) …' service that is excluded from this seed, and staging's
-- PV128 card 'Body Massage' (RM240) is mislinked to 'Head Massage' (RM12,
-- 21 min). Reusing any of them was explicitly ruled out.
--
-- Card id mirrors service_id 1:1 (SECTION 2) so a mislink is impossible to
-- introduce silently.
--
-- display_price is set equal to the internal service price, and duration is
-- inherited from the linked service rather than stored separately (the table
-- has no duration column — verified). enabled = true for all five: Taman Wahyu
-- online booking is going live with exactly this catalogue.
--
-- public_image_url is NULL. It is populated after migration and deliberately
-- points at the SAME migrated object as the service image rather than a second
-- copy — staging's nine online-booking PNGs are 1.7-1.9 MB duplicates belonging
-- to excluded services and are not migrated.
--
-- short_description: taken from the service where staging had one, otherwise
-- left NULL rather than invented.

insert into public.online_booking_services (
  id, outlet_id, service_id, enabled, public_name, short_description,
  public_image_url, display_price, deposit_amount, show_price, display_order,
  buffer_before_minutes, buffer_after_minutes, maximum_concurrent_bookings,
  use_custom_hours
) values
  ('83893724-c584-4603-b208-1db6db0b2ab0', '00000000-0000-0000-0000-000000000002',
   '83893724-c584-4603-b208-1db6db0b2ab0', true, 'Foot Massage (50 min)',
   'Foot Massage', null,  39.00, 0, true, 0, 0, 0, 6, false),
  ('a5f9c703-9d80-42a6-9282-449fbdb29d65', '00000000-0000-0000-0000-000000000002',
   'a5f9c703-9d80-42a6-9282-449fbdb29d65', true, 'Foot Massage (75 min)',
   null, null,  59.00, 0, true, 1, 0, 0, 6, false),
  ('edd2553e-9d98-45d2-9b89-c67a2c6444c8', '00000000-0000-0000-0000-000000000002',
   'edd2553e-9d98-45d2-9b89-c67a2c6444c8', true, 'Foot Massage (90 min)',
   null, null,  78.00, 0, true, 2, 0, 0, 6, false),
  ('4af490ba-064b-4fd4-85fd-9edba196a62d', '00000000-0000-0000-0000-000000000002',
   '4af490ba-064b-4fd4-85fd-9edba196a62d', true, 'Traditional Body Massage (60 min)',
   null, null,  99.00, 0, true, 3, 0, 0, 6, false),
  ('c5c786c0-7a5b-4cd4-84ac-b8c7f83986dd', '00000000-0000-0000-0000-000000000002',
   'c5c786c0-7a5b-4cd4-84ac-b8c7f83986dd', true, 'Traditional Body Massage (80 min)',
   null, null, 129.00, 0, true, 4, 0, 0, 6, false)
on conflict (id) do update set
  outlet_id                   = excluded.outlet_id,
  service_id                  = excluded.service_id,
  enabled                     = excluded.enabled,
  public_name                 = excluded.public_name,
  short_description           = excluded.short_description,
  display_price               = excluded.display_price,
  deposit_amount              = excluded.deposit_amount,
  show_price                  = excluded.show_price,
  display_order               = excluded.display_order,
  buffer_before_minutes       = excluded.buffer_before_minutes,
  buffer_after_minutes        = excluded.buffer_after_minutes,
  maximum_concurrent_bookings = excluded.maximum_concurrent_bookings,
  use_custom_hours            = excluded.use_custom_hours;
  -- public_image_url deliberately NOT overwritten on re-run.

-- NOTE ON PUBLIC NAMING: public_name now matches the corrected internal name in
-- every case — the 'Traditonal' misspelling was fixed at source in SECTION 8, so
-- no divergence between internal and public naming remains.


-- ---------------------------------------------------------------------------
-- 13.2  Card -> room compatibility
-- ---------------------------------------------------------------------------
-- Each card is mapped to every ACTIVE Taman Wahyu room matching its service's
-- room_type. 'Ground Massage Room' is inactive and is deliberately not mapped.
--
-- Reflects the corrected room types from SECTION 8: all three Foot Massage
-- services are foot_chair, both Traditional Body Massage services are body_room.
--
--   3 foot_chair cards -> Ground Floor (7 chairs) + Upper Foot (5 chairs)
--   2 body_room  cards -> Upper Massage Room (8 rooms)
--
-- 8 mappings total (3x2 + 2x1).

insert into public.online_booking_service_rooms (online_booking_service_id, room_id, outlet_id) values
  -- Foot Massage 50 min -> both foot zones
  ('83893724-c584-4603-b208-1db6db0b2ab0', '94263d9a-14aa-47a1-a868-4b704951a993', '00000000-0000-0000-0000-000000000002'),
  ('83893724-c584-4603-b208-1db6db0b2ab0', '6a48a888-7dcc-47ff-a74b-4f84a959162d', '00000000-0000-0000-0000-000000000002'),
  -- Foot Massage 75 min -> both foot zones
  ('a5f9c703-9d80-42a6-9282-449fbdb29d65', '94263d9a-14aa-47a1-a868-4b704951a993', '00000000-0000-0000-0000-000000000002'),
  ('a5f9c703-9d80-42a6-9282-449fbdb29d65', '6a48a888-7dcc-47ff-a74b-4f84a959162d', '00000000-0000-0000-0000-000000000002'),
  -- Foot Massage 90 min -> both foot zones
  ('edd2553e-9d98-45d2-9b89-c67a2c6444c8', '94263d9a-14aa-47a1-a868-4b704951a993', '00000000-0000-0000-0000-000000000002'),
  ('edd2553e-9d98-45d2-9b89-c67a2c6444c8', '6a48a888-7dcc-47ff-a74b-4f84a959162d', '00000000-0000-0000-0000-000000000002'),
  -- Traditional Body Massage 60 / 80 min -> Upper Massage Room
  ('4af490ba-064b-4fd4-85fd-9edba196a62d', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002'),
  ('c5c786c0-7a5b-4cd4-84ac-b8c7f83986dd', '8df942f1-bf39-4372-8bfe-e578a703a5b2', '00000000-0000-0000-0000-000000000002')
on conflict (online_booking_service_id, room_id) do nothing;


-- ---------------------------------------------------------------------------
-- 13.3  online_booking_service_hours  [EMPTY]
-- ---------------------------------------------------------------------------
-- Zero rows, matching staging (which also has zero). All five cards use
-- use_custom_hours = false and therefore inherit the outlet's public window.


-- ============================================================================
-- SECTION 14 — online_booking_closures  [EMPTY BY INSTRUCTION]
-- ============================================================================
-- Zero rows. Staging's two full-day taman-wahyu closures (2026-08-01 and
-- 2026-08-02, both with an empty internal_reason) are NOT carried over and no
-- replacement dates are added, per decision 9.


commit;


-- ============================================================================
-- POST-APPLY VERIFICATION  (expected values in the right-hand column)
-- ============================================================================
--  select count(*) from public.outlets;                              -- 2
--  select count(*) from public.settings;                             -- 1
--  select count(*) from public.business_hours;                       -- 14
--  select count(*) from public.business_settings;                    -- 2
--  select count(*) from public.service_categories;                   -- 1
--  select count(*) from public.services;                             -- 5
--  select count(*) from public.rooms;                                -- 8  (4 TW + 4 PV128)
--  select count(*) from public.room_units;                           -- 14 (8 TW + 6 PV128)
--  select count(*) from public.online_booking_outlet_settings;       -- 2
--  select count(*) from public.online_booking_services;              -- 5
--  select count(*) from public.online_booking_service_rooms;         -- 8
--  select count(*) from public.online_booking_service_hours;         -- 0
--  select count(*) from public.online_booking_closures;              -- 0
--  select count(*) from public.therapists;                           -- 0
--  select count(*) from public.therapist_working_hours;              -- 0
--  select count(*) from public.therapist_unavailability;             -- 0
--
--  -- no operational data anywhere
--  select count(*) from public.customers;                            -- 0
--  select count(*) from public.appointments;                          -- 0
--  select count(*) from public.transactions;                          -- 0
--  select count(*) from public.booking_holds;                         -- 0
--  select count(*) from public.audit_log;                             -- 0
--  select count(*) from public.notifications;                          -- 0
--  select count(*) from public.therapist_queue;                        -- 0
--
--  -- capacity mode off on both outlets
--  select outlet_id, capacity_first_enabled from public.business_settings;
--                                                                     -- both false
--  -- SST not normalised
--  select o.code, b.sst_pricing_mode, b.sst_rounding_mode,
--         b.appointment_addon_sst_pricing_mode
--    from public.business_settings b join public.outlets o on o.id=b.outlet_id;
--   -- pv128       | inclusive | nearest_cent    | disabled
--   -- taman-wahyu | exclusive | nearest_10_sen  | exclusive
--
--  -- online booking: taman-wahyu only
--  select o.code, s.online_booking_enabled
--    from public.online_booking_outlet_settings s
--    join public.outlets o on o.id = s.outlet_id;   -- pv128 false, taman-wahyu true
--
--  -- every card maps 1:1 to a real service, prices agree
--  select ob.public_name, ob.display_price, s.name, s.price, s.duration
--    from public.online_booking_services ob
--    join public.services s on s.id = ob.service_id
--   order by ob.display_order;                      -- 5 rows, prices equal
--
--  -- no image URL points anywhere yet (populated after migration)
--  select count(*) from public.services where image_url is not null;            -- 0
--  select count(*) from public.online_booking_services
--   where public_image_url is not null;                                         -- 0
--
--  -- deprecated column untouched, no therapist overrides
--  select count(*) from public.therapists
--   where coalesce(service_commissions,'{}'::jsonb) <> '{}'::jsonb;             -- 0
--  select count(*) from public.therapists
--   where coalesce(commission_overrides,'{}'::jsonb) <> '{}'::jsonb;            -- 0
--
--  -- no test rows survived
--  select name from public.services where name ~* '^(test|testing|test2)$';     -- 0 rows
-- ============================================================================
