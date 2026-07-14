-- Status/payment model, part 2: give appointments their own payment_status.
--
-- Problem: the app decided whether an appointment was "paid" purely by whether
-- a matching transactions row happened to exist (see appointment_screen.dart
-- hasPayment). That conflated two independent facts and made a paid online
-- booking and an unpaid app booking both look like "Payment Pending" whenever
-- the transaction join didn't line up. Money still lives in `transactions`
-- (the source of truth); this adds a reliable, directly-readable cached status
-- on the appointment for the UI.
--
-- Reuses the existing `payment_status` enum ({unpaid,paid,refunded,voided}) that
-- transactions already use, so appointment and transaction payment status speak
-- the same language. Default 'unpaid'.
--
-- Kept in sync by a trigger on `transactions` rather than by editing the four
-- atomic payment RPCs (037) + record_online_booking_payment (033): one trigger
-- covers every current and future path that writes a sale, and never risks a
-- typo inside financial function bodies. payment_status is not in the
-- resource-overlap trigger's UPDATE-OF column list, so syncing it never
-- re-runs conflict checks.

alter table public.appointments
  add column if not exists payment_status public.payment_status not null default 'unpaid';

-- Backfill from existing sales: mirror each appointment's transaction status.
-- Direct (single-appointment) links first, then group links.
update public.appointments a
set payment_status = t.payment_status
from public.transactions t
where t.appointment_id = a.id;

update public.appointments a
set payment_status = t.payment_status
from public.transactions t
where a.appointment_group_id is not null
  and t.appointment_group_id = a.appointment_group_id;

create or replace function public.sync_appointment_payment_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.appointment_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where id = new.appointment_id
      and payment_status is distinct from new.payment_status;
  end if;

  if new.appointment_group_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where appointment_group_id = new.appointment_group_id
      and payment_status is distinct from new.payment_status;
  end if;

  return new;
end;
$$;

drop trigger if exists transactions_sync_appointment_payment_status on public.transactions;
create trigger transactions_sync_appointment_payment_status
after insert or update of payment_status on public.transactions
for each row execute function public.sync_appointment_payment_status();
