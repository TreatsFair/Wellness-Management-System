-- Phase A guard: at most one bill (transactions row) per appointment / group.
--
-- The reported "RM120 online becomes RM127" was an online booking whose Billplz
-- payment was never recorded as a transaction, so it looked unpaid and the
-- counter checkout recomputed price x 1.06 into a fresh bill. Migration 043
-- already stops the UI from reaching checkout for a paid appointment (hasPayment
-- now reads the authoritative appointments.payment_status). This adds a
-- structural backstop so a SECOND transaction for the same appointment/group is
-- impossible regardless of any UI path -- a genuine double-bill fails loudly at
-- the database instead of silently double-charging.
--
-- Verified before creating: no appointment_id and no appointment_group_id
-- currently has more than one transaction, so these indexes create cleanly.
--
-- Note: the existing partial index transactions_online_booking_appointment_uidx
-- (033) and record_online_booking_payment's ON CONFLICT (appointment_id) WHERE
-- source='online_booking' keep working -- that clause resolves the idempotent
-- retry against its own row (an UPDATE, which satisfies the broader index too).
-- The broader index only ever raises on a genuinely new duplicate bill.
--
-- Transactions from the RPCs set exactly one of appointment_id /
-- appointment_group_id (singles vs groups), so the two partial uniques don't
-- overlap. Legacy rows with neither set are simply not covered (both WHERE
-- clauses exclude them).

create unique index if not exists transactions_one_bill_per_appointment_uidx
  on public.transactions (appointment_id)
  where appointment_id is not null;

create unique index if not exists transactions_one_bill_per_group_uidx
  on public.transactions (appointment_group_id)
  where appointment_group_id is not null;
