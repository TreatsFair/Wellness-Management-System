begin;

-- One automatic booking-confirmation job per logical Fiuu payment attempt.
-- A group booking has several booking_holds rows but one payment attempt, so
-- payment_attempt_id is the durable idempotency key for the automatic email.
create table public.booking_email_outbox (
  id uuid primary key default gen_random_uuid(),
  payment_attempt_id uuid not null
    references public.booking_payment_attempts(id) on delete restrict,
  hold_token uuid not null,
  provider_transaction_id text,
  email_type text not null default 'BOOKING_CONFIRMATION'
    check (email_type = 'BOOKING_CONFIRMATION'),
  idempotency_key uuid not null default gen_random_uuid() unique,
  recipient_email text,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'failed', 'disabled')),
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  manual_resend_count integer not null default 0
    check (manual_resend_count >= 0),
  resend_email_id text,
  last_attempt_at timestamptz,
  next_retry_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz
);

create unique index booking_email_outbox_attempt_type_uidx
  on public.booking_email_outbox (payment_attempt_id, email_type);

create index booking_email_outbox_retry_idx
  on public.booking_email_outbox (status, next_retry_at, created_at);

-- Manual resends are intentional new email requests. They have their own
-- idempotency identity and audit actor instead of reusing the automatic job.
create table public.booking_email_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  payment_attempt_id uuid not null
    references public.booking_payment_attempts(id) on delete restrict,
  hold_token uuid not null,
  email_type text not null default 'BOOKING_CONFIRMATION'
    check (email_type = 'BOOKING_CONFIRMATION'),
  delivery_kind text not null default 'manual'
    check (delivery_kind = 'manual'),
  idempotency_key uuid not null default gen_random_uuid() unique,
  recipient_email text,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'failed', 'disabled')),
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  resend_email_id text,
  last_attempt_at timestamptz,
  next_retry_at timestamptz,
  last_error text,
  initiated_by uuid,
  initiated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz
);

create index booking_email_delivery_attempts_payment_idx
  on public.booking_email_delivery_attempts (payment_attempt_id, created_at desc);

alter table public.booking_email_outbox enable row level security;
alter table public.booking_email_delivery_attempts enable row level security;
revoke all on public.booking_email_outbox from public, anon, authenticated;
revoke all on public.booking_email_delivery_attempts from public, anon, authenticated;
grant select, insert, update on public.booking_email_outbox to service_role;
grant select, insert, update on public.booking_email_delivery_attempts to service_role;

-- Inserts the automatic job and reports whether this caller won the
-- idempotency race. It is callable only by trusted server code.
create or replace function public.queue_booking_confirmation_email(
  p_payment_attempt_id uuid,
  p_hold_token uuid,
  p_provider_transaction_id text,
  p_recipient_email text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job_id uuid;
  v_created boolean := false;
begin
  if not exists (
    select 1
    from public.booking_payment_attempts a
    where a.id = p_payment_attempt_id
      and a.gateway = 'fiuu'
      and a.hold_token = p_hold_token
      and a.status = 'confirmed'
  ) then
    raise exception 'Only a confirmed Fiuu payment attempt can queue a booking email';
  end if;

  insert into public.booking_email_outbox (
    payment_attempt_id,
    hold_token,
    provider_transaction_id,
    recipient_email
  ) values (
    p_payment_attempt_id,
    p_hold_token,
    nullif(left(coalesce(p_provider_transaction_id, ''), 100), ''),
    nullif(left(coalesce(p_recipient_email, ''), 320), '')
  )
  on conflict (payment_attempt_id, email_type) do nothing
  returning id into v_job_id;

  if v_job_id is not null then
    v_created := true;
  else
    select id into v_job_id
    from public.booking_email_outbox
    where payment_attempt_id = p_payment_attempt_id
      and email_type = 'BOOKING_CONFIRMATION';
  end if;

  return jsonb_build_object('job_id', v_job_id, 'created', v_created);
end;
$$;

revoke all on function public.queue_booking_confirmation_email(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.queue_booking_confirmation_email(uuid, uuid, text, text)
  to service_role;

-- Claims the automatic job atomically. Failed jobs can only be claimed when
-- their bounded backoff has elapsed. A SENDING job is deliberately not
-- replayed automatically because an interrupted request may already have been
-- accepted by Resend; the stable idempotency key remains recorded for review.
create or replace function public.claim_booking_email_delivery(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.booking_email_outbox%rowtype;
begin
  update public.booking_email_outbox
  set status = 'sending',
      attempt_count = attempt_count + 1,
      last_attempt_at = now(),
      next_retry_at = null,
      updated_at = now()
  where id = p_job_id
    and attempt_count < 5
    and (
      status = 'pending'
      or (status = 'failed' and next_retry_at is not null and next_retry_at <= now())
    )
  returning * into v_job;

  if not found then
    return null;
  end if;
  return to_jsonb(v_job);
end;
$$;

revoke all on function public.claim_booking_email_delivery(uuid)
  from public, anon, authenticated;
grant execute on function public.claim_booking_email_delivery(uuid)
  to service_role;

create or replace function public.claim_next_booking_email_delivery()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.booking_email_outbox%rowtype;
begin
  with candidate as (
    select id
    from public.booking_email_outbox
    where attempt_count < 5
      and (
        status = 'pending'
        or (status = 'failed' and next_retry_at is not null and next_retry_at <= now())
      )
    order by coalesce(next_retry_at, created_at), created_at
    for update skip locked
    limit 1
  )
  update public.booking_email_outbox job
  set status = 'sending',
      attempt_count = job.attempt_count + 1,
      last_attempt_at = now(),
      next_retry_at = null,
      updated_at = now()
  from candidate
  where job.id = candidate.id
  returning job.* into v_job;

  if not found then
    return null;
  end if;
  return to_jsonb(v_job);
end;
$$;

revoke all on function public.claim_next_booking_email_delivery()
  from public, anon, authenticated;
grant execute on function public.claim_next_booking_email_delivery()
  to service_role;

-- Staff/admin-only entry point for an intentional manual resend. It reads the
-- current email from the booking, records the authenticated actor and creates
-- a new idempotency key for every accepted manual request.
create or replace function public.request_manual_booking_email(
  p_payment_attempt_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.booking_payment_attempts%rowtype;
  v_email text;
  v_delivery_id uuid;
  v_idempotency_key uuid;
begin
  if (select auth.uid()) is null or not (select public.is_staff_or_admin()) then
    raise exception 'Staff access is required' using errcode = '42501';
  end if;

  select * into v_attempt
  from public.booking_payment_attempts a
  where a.id = p_payment_attempt_id
    and a.gateway = 'fiuu'
  for update;
  if not found then
    raise exception 'Payment attempt was not found' using errcode = 'P0002';
  end if;
  if v_attempt.status <> 'confirmed' then
    raise exception 'A confirmation email is available only for a confirmed booking'
      using errcode = '22023';
  end if;
  if not (select private.has_outlet_access(v_attempt.outlet_id)) then
    raise exception 'Staff access to this outlet is required' using errcode = '42501';
  end if;

  select h.customer_email into v_email
  from public.booking_holds h
  where h.public_token = v_attempt.hold_token
     or h.booking_group_token = v_attempt.hold_token
  order by h.guest_index nulls first, h.created_at
  limit 1;
  if not found then
    raise exception 'Confirmed booking details were not found' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.booking_email_delivery_attempts d
    where d.payment_attempt_id = v_attempt.id
      and d.created_at >= now() - interval '60 seconds'
  ) then
    raise exception 'A confirmation email resend was just requested. Try again shortly.'
      using errcode = '55P03';
  end if;

  insert into public.booking_email_delivery_attempts (
    payment_attempt_id,
    hold_token,
    recipient_email,
    initiated_by
  ) values (
    v_attempt.id,
    v_attempt.hold_token,
    nullif(left(coalesce(v_email, ''), 320), ''),
    (select auth.uid())
  )
  returning id, idempotency_key into v_delivery_id, v_idempotency_key;

  update public.booking_email_outbox
  set manual_resend_count = manual_resend_count + 1,
      updated_at = now()
  where payment_attempt_id = v_attempt.id
    and email_type = 'BOOKING_CONFIRMATION';

  return jsonb_build_object(
    'delivery_id', v_delivery_id,
    'payment_attempt_id', v_attempt.id,
    'idempotency_key', v_idempotency_key
  );
end;
$$;

revoke all on function public.request_manual_booking_email(uuid)
  from public, anon;
grant execute on function public.request_manual_booking_email(uuid)
  to authenticated;

create or replace function public.claim_manual_booking_email_delivery(
  p_delivery_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delivery public.booking_email_delivery_attempts%rowtype;
begin
  update public.booking_email_delivery_attempts
  set status = 'sending',
      attempt_count = attempt_count + 1,
      last_attempt_at = now(),
      next_retry_at = null,
      updated_at = now()
  where id = p_delivery_id
    and status = 'pending'
  returning * into v_delivery;

  if not found then
    return null;
  end if;
  return to_jsonb(v_delivery);
end;
$$;

revoke all on function public.claim_manual_booking_email_delivery(uuid)
  from public, anon, authenticated;
grant execute on function public.claim_manual_booking_email_delivery(uuid)
  to service_role;

-- The existing Payments & Refunds screen is the read-only operational surface
-- for both staff and admins. The sensitive Fiuu ledgers remain hidden behind
-- this projection and the manual resend RPC above.
create or replace function public.list_admin_booking_payments(
  p_outlet_id uuid,
  p_limit integer default 200
)
returns table (
  attempt_id uuid,
  order_id text,
  amount numeric,
  currency text,
  payment_status text,
  gateway_transaction_id text,
  payment_channel text,
  payment_received_at timestamptz,
  payment_created_at timestamptz,
  payment_updated_at timestamptz,
  payment_expires_at timestamptz,
  customer_name text,
  customer_phone text,
  customer_email text,
  booking_start_at timestamptz,
  appointment_id uuid,
  appointment_group_id uuid,
  refund_status text,
  gateway_refund_id text,
  refund_requested_at timestamptz,
  refund_completed_at timestamptz,
  refund_updated_at timestamptz,
  refund_error_code text,
  refund_error text,
  refund_status_checks integer
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if (select auth.uid()) is null
     or not (select public.is_staff_or_admin())
     or not (select private.has_outlet_access(p_outlet_id)) then
    raise exception 'Staff access to this outlet is required'
      using errcode = '42501';
  end if;

  if p_outlet_id is null then
    raise exception 'Outlet is required';
  end if;

  return query
  select
    attempt.id,
    attempt.order_id,
    attempt.amount,
    attempt.currency,
    attempt.status,
    attempt.gateway_transaction_id,
    latest_event.channel,
    latest_event.received_at,
    attempt.created_at,
    attempt.updated_at,
    attempt.expires_at,
    hold.customer_name,
    hold.customer_phone,
    hold.customer_email,
    hold.start_at,
    hold.appointment_id,
    hold.appointment_group_id,
    refund.status,
    refund.gateway_refund_id,
    refund.requested_at,
    refund.completed_at,
    refund.updated_at,
    refund.last_error_code,
    refund.last_error,
    refund.status_checks
  from public.booking_payment_attempts attempt
  left join public.booking_payment_refunds refund
    on refund.attempt_id = attempt.id
  left join lateral (
    select event.channel, event.received_at
    from public.booking_payment_events event
    where event.attempt_id = attempt.id
    order by event.received_at desc, event.id desc
    limit 1
  ) latest_event on true
  left join lateral (
    select
      booking_hold.customer_name,
      booking_hold.customer_phone,
      booking_hold.customer_email,
      booking_hold.start_at,
      booking_hold.appointment_id,
      booking_hold.appointment_group_id
    from public.booking_holds booking_hold
    where booking_hold.public_token = attempt.hold_token
       or booking_hold.booking_group_token = attempt.hold_token
    order by booking_hold.guest_index nulls first, booking_hold.created_at
    limit 1
  ) hold on true
  where attempt.gateway = 'fiuu'
    and attempt.outlet_id = p_outlet_id
  order by coalesce(refund.updated_at, attempt.updated_at) desc,
    attempt.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 500);
end;
$function$;

revoke all on function public.list_admin_booking_payments(uuid, integer)
  from public, anon;
grant execute on function public.list_admin_booking_payments(uuid, integer)
  to authenticated;

commit;
