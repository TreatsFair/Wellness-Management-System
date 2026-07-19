-- In-app notifications for appointments and transactions.
--
-- A `notifications` row is created by database triggers (never by the app)
-- whenever something staff should know about happens:
--   new_online_appointment   - a paid online booking confirmed into an appointment
--   online_payment_received  - an online payment landed as a paid transaction
--   payment_failed           - a Billplz payment failed while the hold was pending
--   payment_expired          - a hold expired after the customer reached payment
--   appointment_cancelled    - an appointment was cancelled
--   appointment_voided       - an appointment's payment was voided
--   refund_completed         - a paid transaction was refunded
--   transaction_review       - a paid transaction changed in a way that needs a look
-- "Appointment starting soon" is intentionally NOT stored here - the app
-- derives it live from today's appointments so it never goes stale.
--
-- The app reads the feed (Realtime-subscribed) and links each row to its
-- appointment / transaction. Staff can mark rows read; only admin can delete.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  type text not null check (type in (
    'new_online_appointment',
    'online_payment_received',
    'payment_failed',
    'payment_expired',
    'appointment_cancelled',
    'appointment_voided',
    'refund_completed',
    'transaction_review'
  )),
  title text not null,
  body text not null default '',
  appointment_id uuid references public.appointments(id) on delete set null,
  appointment_group_id uuid references public.appointment_groups(id) on delete set null,
  transaction_id uuid references public.transactions(id) on delete set null,
  booking_hold_id uuid references public.booking_holds(id) on delete set null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists notifications_feed_idx
  on public.notifications(outlet_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications(outlet_id) where read_at is null;
create index if not exists notifications_hold_idx
  on public.notifications(booking_hold_id) where booking_hold_id is not null;

alter table public.notifications enable row level security;

drop policy if exists notifications_staff_admin_select on public.notifications;
create policy notifications_staff_admin_select
on public.notifications for select
to authenticated
using (public.is_staff_or_admin());

-- Staff may only flip read_at; inserts come exclusively from the
-- security-definer trigger functions below.
drop policy if exists notifications_staff_admin_update on public.notifications;
create policy notifications_staff_admin_update
on public.notifications for update
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());

drop policy if exists notifications_admin_delete on public.notifications;
create policy notifications_admin_delete
on public.notifications for delete
to authenticated
using (public.is_admin());

grant select, delete on table public.notifications to authenticated;
revoke update on table public.notifications from authenticated;
grant update (read_at) on table public.notifications to authenticated;
revoke insert on table public.notifications from authenticated;

-- ── Online booking lifecycle (booking_holds) ───────────────────────────────
create or replace function public.notify_booking_hold_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_service_name text := '';
  v_when text := '';
  v_event_type text;
  v_already boolean := false;
begin
  -- confirm_public_booking_hold flips status to 'confirmed' BEFORE the
  -- appointment exists and backfills appointment_id in a later update, so
  -- the trigger listens to both columns and only notifies once the
  -- appointment link is in place.
  if new.status = 'confirmed' then
    if new.appointment_id is null then return new; end if;
    v_event_type := 'new_online_appointment';
  elsif new.status = 'payment_failed' and old.status = 'pending_payment' then
    v_event_type := 'payment_failed';
  elsif new.status = 'expired'
     and old.status is distinct from 'expired'
     and new.billplz_bill_id is not null then
    v_event_type := 'payment_expired';
  else
    return new;
  end if;

  -- Never notify twice for the same hold, and for group bookings (several
  -- holds flipped one after another) notify once per group per event type.
  select exists (
    select 1
    from public.notifications n
    join public.booking_holds h on h.id = n.booking_hold_id
    where n.type = v_event_type
      and (
        h.id = new.id
        or (
          new.booking_group_token is not null
          and h.booking_group_token = new.booking_group_token
        )
      )
  ) into v_already;
  if v_already then
    -- Group confirmation creates the individual appointments before it creates
    -- the appointment_group row. When that later link arrives, enrich the one
    -- deduplicated notification instead of leaving it attached to Pax 1 only.
    if v_event_type = 'new_online_appointment'
       and new.appointment_group_id is not null then
      update public.notifications n
      set appointment_group_id = new.appointment_group_id
      from public.booking_holds h
      where h.id = n.booking_hold_id
        and n.type = v_event_type
        and (
          h.id = new.id
          or (
            new.booking_group_token is not null
            and h.booking_group_token = new.booking_group_token
          )
        );
    end if;
    return new;
  end if;

  select coalesce(s.name, c.public_name, 'Online booking')
  into v_service_name
  from public.online_booking_services c
  left join public.services s on s.id = c.service_id
  where c.id = new.online_booking_service_id;
  v_service_name := coalesce(v_service_name, 'Online booking');

  v_when := to_char(new.start_at at time zone 'Asia/Kuala_Lumpur', 'DD Mon, HH24:MI');

  if new.status = 'confirmed' then
    insert into public.notifications (
      outlet_id, type, title, body,
      appointment_id, appointment_group_id, booking_hold_id
    ) values (
      new.outlet_id,
      'new_online_appointment',
      case when new.booking_group_token is not null
        then format('New online group booking - %s', coalesce(new.customer_name, 'Customer'))
        else format('New online booking - %s', coalesce(new.customer_name, 'Customer'))
      end,
      format('%s on %s', v_service_name, v_when),
      new.appointment_id, new.appointment_group_id, new.id
    );
  elsif new.status = 'payment_failed' then
    insert into public.notifications (
      outlet_id, type, title, body, booking_hold_id, appointment_group_id
    ) values (
      new.outlet_id,
      'payment_failed',
      format('Online payment failed - %s', coalesce(new.customer_name, 'Customer')),
      format('%s on %s (RM %s)', v_service_name, v_when,
             to_char(coalesce(new.total_amount, 0), 'FM999G999D00')),
      new.id, new.appointment_group_id
    );
  elsif new.status = 'expired' then
    -- Only holds where the customer actually reached the payment page
    -- (billplz_bill_id set); silently abandoned carts would just be noise.
    insert into public.notifications (
      outlet_id, type, title, body, booking_hold_id, appointment_group_id
    ) values (
      new.outlet_id,
      'payment_expired',
      format('Online booking expired unpaid - %s', coalesce(new.customer_name, 'Customer')),
      format('%s on %s was not paid in time', v_service_name, v_when),
      new.id, new.appointment_group_id
    );
  end if;

  return new;
end;
$$;

drop trigger if exists booking_holds_notify_event on public.booking_holds;
create trigger booking_holds_notify_event
after update of status, appointment_id, appointment_group_id on public.booking_holds
for each row execute function public.notify_booking_hold_event();

-- ── Appointment status changes ─────────────────────────────────────────────
create or replace function public.notify_appointment_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer text;
  v_when text;
  v_type text;
  v_title text;
begin
  -- The app's void action sets status=cancelled and payment_status=voided in
  -- the same update. Check void first so that action is not mislabeled as a
  -- plain cancellation.
  if new.payment_status::text = 'voided' and old.payment_status::text <> 'voided' then
    v_type := 'appointment_voided';
    v_title := 'Appointment voided';
  elsif new.status::text = 'cancelled' and old.status::text <> 'cancelled' then
    v_type := 'appointment_cancelled';
    v_title := 'Appointment cancelled';
  else
    return new;
  end if;

  -- One notification per group action, not one per pax.
  if new.appointment_group_id is not null and exists (
    select 1 from public.notifications n
    where n.appointment_group_id = new.appointment_group_id
      and n.type = v_type
      and n.created_at > now() - interval '1 minute'
  ) then
    return new;
  end if;

  select coalesce(c.name, 'Guest') into v_customer
  from public.customers c where c.id = new.customer_id;
  v_customer := coalesce(v_customer, 'Guest');

  v_when := format(
    '%s %s',
    to_char(new.appointment_date::date, 'DD Mon'),
    left(new.start_time::text, 5)
  );

  insert into public.notifications (
    outlet_id, type, title, body, appointment_id, appointment_group_id
  ) values (
    new.outlet_id,
    v_type,
    format('%s - %s', v_title, v_customer),
    format('%s on %s', coalesce(nullif(new.service_name, ''), 'Appointment'), v_when),
    new.id,
    new.appointment_group_id
  );

  return new;
end;
$$;

drop trigger if exists appointments_notify_event on public.appointments;
create trigger appointments_notify_event
after update of status, payment_status on public.appointments
for each row execute function public.notify_appointment_event();

-- ── Transaction events ─────────────────────────────────────────────────────
create or replace function public.notify_transaction_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount text;
begin
  v_amount := to_char(coalesce(new.total_amount, 0), 'FM999G999D00');

  -- Online payment landed as a paid transaction.
  if new.source::text = 'online_booking'
     and new.payment_status::text = 'paid'
     and (tg_op = 'INSERT' or old.payment_status::text <> 'paid') then
    if not exists (
      select 1 from public.notifications n
      where n.transaction_id = new.id and n.type = 'online_payment_received'
    ) then
      insert into public.notifications (
        outlet_id, type, title, body,
        transaction_id, appointment_id, appointment_group_id
      ) values (
        new.outlet_id,
        'online_payment_received',
        format('Online payment received - RM %s', v_amount),
        format('%s (%s)',
               coalesce(nullif(new.customer_name, ''), 'Customer'),
               coalesce(nullif(new.service_name, ''), 'Online booking')),
        new.id, new.appointment_id, new.appointment_group_id
      );
    end if;
  end if;

  if tg_op = 'UPDATE' then
    -- Refund completed.
    if new.payment_status::text = 'refunded' and old.payment_status::text <> 'refunded' then
      insert into public.notifications (
        outlet_id, type, title, body,
        transaction_id, appointment_id, appointment_group_id
      ) values (
        new.outlet_id,
        'refund_completed',
        format('Refund completed - RM %s', v_amount),
        format('%s (%s)',
               coalesce(nullif(new.customer_name, ''), 'Customer'),
               coalesce(nullif(new.receipt_number, ''), 'transaction')),
        new.id, new.appointment_id, new.appointment_group_id
      );
    end if;

    -- A paid transaction that changed amount, or slipped back to unpaid,
    -- deserves a human look.
    if (old.payment_status::text = 'paid' and new.payment_status::text = 'unpaid')
       or (old.payment_status::text = 'paid' and new.payment_status::text = 'paid'
           and new.total_amount is distinct from old.total_amount) then
      insert into public.notifications (
        outlet_id, type, title, body,
        transaction_id, appointment_id, appointment_group_id
      ) values (
        new.outlet_id,
        'transaction_review',
        'Transaction needs review',
        format('%s changed after payment (RM %s -> RM %s)',
               coalesce(nullif(new.receipt_number, ''), 'Transaction'),
               to_char(coalesce(old.total_amount, 0), 'FM999G999D00'),
               v_amount),
        new.id, new.appointment_id, new.appointment_group_id
      );
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists transactions_notify_event on public.transactions;
create trigger transactions_notify_event
after insert or update of payment_status, total_amount on public.transactions
for each row execute function public.notify_transaction_event();

-- Trigger functions are never called directly.
revoke all on function public.notify_booking_hold_event() from public, anon, authenticated;
revoke all on function public.notify_appointment_event() from public, anon, authenticated;
revoke all on function public.notify_transaction_event() from public, anon, authenticated;

-- Realtime feed for the app's popup + badge.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'notifications'
     ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end
$$;
