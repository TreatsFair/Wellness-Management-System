-- ============================================================================
-- 000005_controlled_smoke_test_data.sql
-- ============================================================================
-- Target : erjttzhownsxohpvzjbs  (Treats PRODUCTION, ap-southeast-1 / Singapore)
-- Status : DRAFT — NOT APPLIED. Requires its own separate approval, distinct
--          from the baseline files 000001-000004.
--
-- ############################################################################
-- ##  CONTROLLED TEST DATA — NOT REAL STAFF.                                ##
-- ##  Every row's name begins with 'PRODUCTION TEST —'.                     ##
-- ##  Remove with 000005_cleanup_smoke_test_data.sql before go-live.        ##
-- ############################################################################
--
-- PURPOSE
-- Zero therapists blocks every functional smoke test, because availability,
-- queue and assignment all resolve against eligible therapists. This file
-- seeds the MINIMUM set of clearly-labelled temporary therapists needed to
-- exercise: queue rotation, walk-ins, counter appointments, online holds,
-- single-pax, multi-pax, therapist switching, check-in and start-service.
--
-- WHY FIVE ROWS IS THE MINIMUM
--   * queue rotation        needs >= 3 therapists for the rotation pointer to
--                           visibly advance and wrap
--   * therapist switching   needs a third therapist free while two are engaged
--   * multi-pax (2 pax)     needs 2 therapists simultaneously; combined with
--                           per-pax GENDER preference it needs two of each
--                           gender to be satisfiable concurrently -> 2M + 2F
--   * checkout              needs a Counter-role row, because
--                           transactions.counter_staff_id is a FK to
--                           therapists(id)
--   => 4 therapists (2 male, 2 female) + 1 counter = 5 rows.
--   Three therapists would block a concurrent mixed-gender two-pax booking, so
--   four is the floor, not a convenience.
--
-- SCOPE: Taman Wahyu only (outlet 00000000-0000-0000-0000-000000000002).
-- PV128 has no service catalogue, so therapists there would have nothing to be
-- booked against.
--
-- NO PERSONAL INFORMATION. No real names, no phone numbers, no addresses, no
-- images. `phone` is NULL, not junk like staging's 'a' / '-'.
--
-- NOTHING OPERATIONAL IS PRE-SEEDED. No customers, appointments, appointment
-- groups, transactions, booking holds, payments, notifications or queue rows.
-- Queue rows are created by the application when a test day is seeded.
--
-- COMMISSIONS
--   service_commissions  stays '{}' — never written here. A non-empty map is
--                        read by every scheduling path as an EXCLUSIVE
--                        eligibility whitelist, silently removing the therapist
--                        from all other services.
--   commission_overrides stays '{}' — never written here. Rates come from the
--                        service-level columns seeded by 000004.
--   Both rely on their NOT NULL DEFAULT '{}'::jsonb.
--
-- IDENTIFICATION — three independent handles, any one is sufficient:
--   1. id in the reserved range  ffffffff-0000-0000-0000-0000000000NN
--   2. name LIKE 'PRODUCTION TEST —%'
--   3. notes = 'CONTROLLED SMOKE TEST — remove before go-live'
--
-- PREREQUISITES: 000001 (schema) and 000004 (outlet + business_hours) applied.
-- Both are asserted below.
--
-- Transactional and idempotent: re-running changes nothing.
-- ============================================================================


begin;

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.outlets
                  where id = '00000000-0000-0000-0000-000000000002') then
    raise exception
      'Taman Wahyu outlet missing — apply 000004_seed_configuration.sql first.';
  end if;

  if not exists (select 1 from public.business_hours
                  where outlet_id = '00000000-0000-0000-0000-000000000002') then
    raise exception
      'Taman Wahyu business_hours missing — apply 000004 first, or every '
      'availability query will return empty.';
  end if;
end
$$;


-- ---------------------------------------------------------------------------
-- 1. Temporary staff — 1 counter + 4 therapists
-- ---------------------------------------------------------------------------
-- display_order is the rotation number and is unique per outlet (enforced by
-- the therapist_rotation_number_unique migration). Counter takes 0; therapists
-- take 1-4 in rotation order.
--
-- Gender is explicit on every row. The 2M/2F split is what makes mixed-gender
-- multi-pax preference testable.

insert into public.therapists (
  id, outlet_id, name, gender, role, phone, join_date,
  availability_status, display_order, notes
) values
  ('ffffffff-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002',
   'PRODUCTION TEST — Counter',     'Female', 'Counter',   null, '2026-07-30', true, 0,
   'CONTROLLED SMOKE TEST — remove before go-live'),
  ('ffffffff-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002',
   'PRODUCTION TEST — Therapist 1', 'Male',   'Therapist', null, '2026-07-30', true, 1,
   'CONTROLLED SMOKE TEST — remove before go-live'),
  ('ffffffff-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002',
   'PRODUCTION TEST — Therapist 2', 'Male',   'Therapist', null, '2026-07-30', true, 2,
   'CONTROLLED SMOKE TEST — remove before go-live'),
  ('ffffffff-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000002',
   'PRODUCTION TEST — Therapist 3', 'Female', 'Therapist', null, '2026-07-30', true, 3,
   'CONTROLLED SMOKE TEST — remove before go-live'),
  ('ffffffff-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000002',
   'PRODUCTION TEST — Therapist 4', 'Female', 'Therapist', null, '2026-07-30', true, 4,
   'CONTROLLED SMOKE TEST — remove before go-live')
on conflict (id) do update set
  outlet_id           = excluded.outlet_id,
  name                = excluded.name,
  gender              = excluded.gender,
  role                = excluded.role,
  join_date           = excluded.join_date,
  availability_status = excluded.availability_status,
  display_order       = excluded.display_order,
  notes               = excluded.notes;


-- ---------------------------------------------------------------------------
-- 2. Working hours — explicit, one row per therapist per open day
-- ---------------------------------------------------------------------------
-- NOTE: the trigger `therapists_seed_default_working_hours` already fires on
-- INSERT above and copies every non-closed business_hours row for the outlet
-- into therapist_working_hours. This block is therefore usually a no-op.
--
-- It is written out anyway, deliberately, for two reasons: the hours this file
-- depends on are then visible in the file itself rather than implied by a
-- trigger, and coverage is guaranteed even if the trigger is later changed or
-- the rows are partially removed. The unique key
-- (therapist_id, day_of_week, start_time) makes it idempotent.
--
-- Hours mirror Taman Wahyu's confirmed trading hours (000004 SECTION 5):
--   day_of_week 0 Sun  11:00-23:30
--               1 Mon  11:00-23:00
--               2 Tue  11:00-23:00
--               3 Wed  11:00-23:00
--               4 Thu  11:00-23:00
--               5 Fri  11:00-23:30
--               6 Sat  11:00-23:30
-- These are the FULL trading hours, not the 19:30 online-booking window — staff
-- work the whole day; only the public booking page closes early.

insert into public.therapist_working_hours (
  outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
)
select '00000000-0000-0000-0000-000000000002',
       t.id,
       d.day_of_week,
       d.start_time,
       d.end_time,
       false
from (values
        ('ffffffff-0000-0000-0000-000000000001'::uuid),
        ('ffffffff-0000-0000-0000-000000000002'::uuid),
        ('ffffffff-0000-0000-0000-000000000003'::uuid),
        ('ffffffff-0000-0000-0000-000000000004'::uuid),
        ('ffffffff-0000-0000-0000-000000000005'::uuid)
     ) as t(id)
cross join (values
        (0, '11:00'::time, '23:30'::time),
        (1, '11:00'::time, '23:00'::time),
        (2, '11:00'::time, '23:00'::time),
        (3, '11:00'::time, '23:00'::time),
        (4, '11:00'::time, '23:00'::time),
        (5, '11:00'::time, '23:30'::time),
        (6, '11:00'::time, '23:30'::time)
     ) as d(day_of_week, start_time, end_time)
on conflict (therapist_id, day_of_week, start_time) do nothing;


commit;


-- ============================================================================
-- Row-count forecast
-- ============================================================================
--   public.therapists                +5   (1 Counter, 4 Therapist)
--   public.therapist_working_hours   +35  (5 x 7 open days)
--   everything else                  +0
--   TOTAL                            40 rows, 2 tables
-- ============================================================================


-- ============================================================================
-- What this enables
-- ============================================================================
--   queue rotation      4 therapists in rotation order 1-4
--   walk-ins            immediate-start path with a live queue
--   counter appointments future-dated concrete booking
--   online holds        public availability resolves; 10-minute hold lifecycle
--   single-pax          any one therapist
--   multi-pax           2-pax concurrently, including mixed gender preference
--   switching           reassign between therapists mid-appointment
--   check-in / start    check-in then atomic start-service
--   checkout            Counter row satisfies transactions.counter_staff_id
--
-- STILL NOT POSSIBLE
--   anything at PV128 — no service catalogue
--   commission-override behaviour — no overrides seeded, by decision
--   staff login — needs auth.users + profiles, created separately
-- ============================================================================


-- ============================================================================
-- Verification after applying
-- ============================================================================
--   select name, gender, role, display_order from public.therapists
--    order by display_order;
--   -- 0 PRODUCTION TEST — Counter     Female Counter
--   -- 1 PRODUCTION TEST — Therapist 1 Male   Therapist
--   -- 2 PRODUCTION TEST — Therapist 2 Male   Therapist
--   -- 3 PRODUCTION TEST — Therapist 3 Female Therapist
--   -- 4 PRODUCTION TEST — Therapist 4 Female Therapist
--
--   select count(*) from public.therapist_working_hours;                  -- 35
--
--   select t.display_order, count(*) as days,
--          min(w.start_time) as opens, max(w.end_time) as closes
--     from public.therapists t
--     join public.therapist_working_hours w on w.therapist_id = t.id
--    group by t.display_order order by t.display_order;
--   -- each: 7 days, 11:00, 23:30
--
--   -- commission columns untouched
--   select count(*) from public.therapists
--    where coalesce(service_commissions,'{}'::jsonb)  <> '{}'::jsonb;      -- 0
--   select count(*) from public.therapists
--    where coalesce(commission_overrides,'{}'::jsonb) <> '{}'::jsonb;      -- 0
--
--   -- all labelled, findable three ways
--   select count(*) from public.therapists where name like 'PRODUCTION TEST —%';   -- 5
--   select count(*) from public.therapists where id::text like 'ffffffff-0000-%';  -- 5
--   select count(*) from public.therapists
--    where notes = 'CONTROLLED SMOKE TEST — remove before go-live';                -- 5
--
--   -- nothing operational was created
--   select count(*) from public.customers;      -- 0
--   select count(*) from public.appointments;   -- 0
--   select count(*) from public.transactions;   -- 0
--   select count(*) from public.booking_holds;  -- 0
-- ============================================================================
