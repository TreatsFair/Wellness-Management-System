-- Status/payment model, part 1: add the 'no_show' appointment outcome.
--
-- Agreed model separates the appointment lifecycle from payment:
--   appointment_status: confirmed -> in_progress -> completed, with cancelled
--                       and no_show as exits (legacy 'pending' kept, unused).
--   payment_status (added in 043): unpaid / paid / refunded (/ voided).
--
-- 'no_show' is a distinct operational outcome ("customer never arrived"),
-- deliberately NOT just another late record. Like cancelled/completed it does
-- not block a resource slot -- csp_blocks_schedule() only counts
-- confirmed/in_progress, so a no-show naturally frees the therapist/room with
-- no extra change needed.
--
-- Kept in its own migration: ALTER TYPE ... ADD VALUE adds an enum label that
-- cannot be USED until its transaction commits, so nothing here references
-- 'no_show'; the column/backfill work that follows lives in 043.

alter type public.appointment_status add value if not exists 'no_show';
