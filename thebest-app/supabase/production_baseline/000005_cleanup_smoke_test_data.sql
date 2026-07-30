-- ============================================================================
-- 000005_cleanup_smoke_test_data.sql
-- ============================================================================
-- Target : erjttzhownsxohpvzjbs  (Treats PRODUCTION, ap-southeast-1 / Singapore)
-- Status : DRAFT — NOT APPLIED. Run before go-live, after real staff exist.
--
-- Removes ONLY the five controlled test therapists created by
-- 000005_controlled_smoke_test_data.sql, plus their temporary scheduling and
-- queue records. It touches nothing else.
--
-- SCOPE FENCE. Every statement is restricted by the reserved id range
--   ffffffff-0000-0000-0000-0000000000NN
-- and, where the table has no therapist reference, by outlet + the test
-- therapists' own rows. A real therapist can never match. The final assertion
-- verifies that only the intended rows were affected.
--
-- ACCOUNTING SAFETY. This script REFUSES to run while any appointment or
-- transaction still references a test therapist. Test bookings and test
-- receipts are accounting records: deleting a therapist with
-- `ON DELETE SET NULL` on transactions.counter_staff_id would silently strip
-- the cashier from a receipt rather than fail. If the guard trips, decide the
-- correct treatment for those records first — voiding or retaining them is a
-- business decision, not a cleanup detail.
--
-- Transactional and idempotent: re-running after a successful run is a no-op.
-- ============================================================================


-- NOTE: this file contains no BEGIN/COMMIT. The transaction boundary is
-- supplied externally by psql --single-transaction, together with
-- ON_ERROR_STOP=1, so any failure rolls the whole file back. An internal
-- COMMIT would end that wrapper transaction early and silently weaken the
-- protection.

-- ---------------------------------------------------------------------------
-- 1. Refuse if operational rows still reference the test therapists
-- ---------------------------------------------------------------------------
do $$
declare
  v_appts        bigint;
  v_txn_counter  bigint;
  v_txn_therapist bigint;
  v_allocations  bigint;
begin
  select count(*) into v_appts
    from public.appointments
   where therapist_id::text like 'ffffffff-0000-%'
      or requested_therapist_id::text like 'ffffffff-0000-%';

  select count(*) into v_txn_counter
    from public.transactions
   where counter_staff_id::text like 'ffffffff-0000-%';

  select count(*) into v_txn_therapist
    from public.transactions
   where therapist_id::text like 'ffffffff-0000-%';

  select count(*) into v_allocations
    from public.appointment_therapist_allocations
   where therapist_id::text like 'ffffffff-0000-%';

  if v_appts > 0 or v_txn_counter > 0 or v_txn_therapist > 0 or v_allocations > 0 then
    raise exception
      E'Refusing to delete controlled test therapists.\n'
      'Still referenced by: appointments=%, transactions.counter_staff_id=%, '
      'transactions.therapist_id=%, appointment_therapist_allocations=%.\n'
      'These are test bookings and test receipts. Decide and apply the correct '
      'accounting treatment for them BEFORE running this cleanup — deleting the '
      'therapist would null the cashier on a receipt instead of failing.',
      v_appts, v_txn_counter, v_txn_therapist, v_allocations;
  end if;
end
$$;


-- ---------------------------------------------------------------------------
-- 2. Temporary scheduling and queue records
-- ---------------------------------------------------------------------------
-- Deleted before the therapists themselves so nothing depends on cascade
-- behaviour or ordering luck.

delete from public.therapist_working_hours
 where therapist_id::text like 'ffffffff-0000-%';

delete from public.therapist_unavailability
 where therapist_id::text like 'ffffffff-0000-%';

delete from public.therapist_queue
 where therapist_id::text like 'ffffffff-0000-%';

-- therapist_queue_day has no therapist_id — it is a per-outlet, per-date queue
-- header. Only rows for the test outlet are removed, and only if no non-test
-- therapist has queue rows for that same day, so a real queue is never dropped.
delete from public.therapist_queue_day d
 where d.outlet_id = '00000000-0000-0000-0000-000000000002'
   and not exists (
     select 1
       from public.therapist_queue q
      where q.outlet_id = d.outlet_id
        and q.queue_date = d.queue_date
        and q.therapist_id::text not like 'ffffffff-0000-%'
   );


-- ---------------------------------------------------------------------------
-- 3. The test therapists
-- ---------------------------------------------------------------------------
delete from public.therapists
 where id in (
   'ffffffff-0000-0000-0000-000000000001',
   'ffffffff-0000-0000-0000-000000000002',
   'ffffffff-0000-0000-0000-000000000003',
   'ffffffff-0000-0000-0000-000000000004',
   'ffffffff-0000-0000-0000-000000000005'
 );


-- ---------------------------------------------------------------------------
-- 4. Assert the cleanup was complete and did not overreach
-- ---------------------------------------------------------------------------
do $$
declare
  v_left  bigint;
  v_hours bigint;
begin
  select count(*) into v_left
    from public.therapists
   where id::text like 'ffffffff-0000-%'
      or name like 'PRODUCTION TEST —%'
      or notes = 'CONTROLLED SMOKE TEST — remove before go-live';

  select count(*) into v_hours
    from public.therapist_working_hours
   where therapist_id::text like 'ffffffff-0000-%';

  if v_left > 0 or v_hours > 0 then
    raise exception
      'Cleanup incomplete: % test therapist row(s) and % working-hour row(s) '
      'remain. Rolling back.', v_left, v_hours;
  end if;
end
$$;



-- ============================================================================
-- Post-cleanup verification
-- ============================================================================
--   select count(*) from public.therapists
--    where name like 'PRODUCTION TEST —%';                      -- 0
--   select count(*) from public.therapists
--    where id::text like 'ffffffff-0000-%';                     -- 0
--   select count(*) from public.therapist_working_hours
--    where therapist_id::text like 'ffffffff-0000-%';           -- 0
--   select count(*) from public.therapist_queue
--    where therapist_id::text like 'ffffffff-0000-%';           -- 0
--
--   -- real staff untouched: this should equal the number entered by hand
--   select count(*) from public.therapists;
--
--   -- configuration untouched by this script
--   select count(*) from public.services;                       -- 5
--   select count(*) from public.rooms;                          -- 8
--   select count(*) from public.online_booking_services;         -- 5
-- ============================================================================
