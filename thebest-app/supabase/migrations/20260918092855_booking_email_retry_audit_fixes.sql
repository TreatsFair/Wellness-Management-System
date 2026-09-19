begin;

-- Keep the address supplied by the booking separate from the address that the
-- provider actually receives. In STAGING the latter is the configured test
-- recipient, so treating the two as one field makes the audit trail misleading.
alter table public.booking_email_outbox
  rename column recipient_email to intended_recipient_email;
alter table public.booking_email_outbox
  add column actual_delivery_recipient text;

alter table public.booking_email_delivery_attempts
  rename column recipient_email to intended_recipient_email;
alter table public.booking_email_delivery_attempts
  add column actual_delivery_recipient text;

-- Existing automatic rows stored the resolved delivery address. Preserve that
-- historical fact before restoring the intended address from the booking.
update public.booking_email_outbox
set actual_delivery_recipient = intended_recipient_email;

update public.booking_email_outbox outbox
set intended_recipient_email = (
  select nullif(left(coalesce(hold.customer_email, ''), 320), '')
  from public.booking_holds hold
  where hold.public_token = outbox.hold_token
     or hold.booking_group_token = outbox.hold_token
  order by hold.guest_index nulls first, hold.created_at
  limit 1
);

update public.booking_email_outbox outbox
set provider_transaction_id = attempt.gateway_transaction_id
from public.booking_payment_attempts attempt
where attempt.id = outbox.payment_attempt_id
  and outbox.provider_transaction_id is null
  and attempt.gateway_transaction_id is not null;

comment on column public.booking_email_outbox.intended_recipient_email is
  'Customer email recorded on the booking when the automatic delivery was queued.';
comment on column public.booking_email_outbox.actual_delivery_recipient is
  'Resolved recipient submitted to Resend; differs from intended recipient in STAGING.';
comment on column public.booking_email_delivery_attempts.intended_recipient_email is
  'Customer email shown to staff when an intentional resend is requested.';
comment on column public.booking_email_delivery_attempts.actual_delivery_recipient is
  'Resolved recipient submitted to Resend; differs from intended recipient in STAGING.';
comment on column public.booking_email_outbox.status is
  'sent means accepted by the Resend API, not confirmed delivered to the mailbox.';
comment on column public.booking_email_delivery_attempts.status is
  'sent means accepted by the Resend API, not confirmed delivered to the mailbox.';

drop index if exists public.booking_email_delivery_attempts_retry_idx;
create index booking_email_delivery_attempts_retry_idx
  on public.booking_email_delivery_attempts (status, next_retry_at, created_at)
  where status in ('pending', 'failed');

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
    intended_recipient_email
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
    intended_recipient_email,
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

-- Automatic retries of an intentional manual resend reclaim the same row and
-- therefore the same idempotency key. A new staff click still creates a new row.
create or replace function public.claim_next_manual_booking_email_delivery()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delivery public.booking_email_delivery_attempts%rowtype;
begin
  with candidate as (
    select id
    from public.booking_email_delivery_attempts
    where attempt_count < 5
      and (
        (status = 'pending' and created_at <= now() - interval '1 minute')
        or (status = 'failed' and next_retry_at is not null and next_retry_at <= now())
      )
    order by coalesce(next_retry_at, created_at), created_at
    for update skip locked
    limit 1
  )
  update public.booking_email_delivery_attempts delivery
  set status = 'sending',
      attempt_count = delivery.attempt_count + 1,
      last_attempt_at = now(),
      next_retry_at = null,
      updated_at = now()
  from candidate
  where delivery.id = candidate.id
  returning delivery.* into v_delivery;

  if not found then
    return null;
  end if;
  return to_jsonb(v_delivery);
end;
$$;

revoke all on function public.claim_next_manual_booking_email_delivery()
  from public, anon, authenticated;
grant execute on function public.claim_next_manual_booking_email_delivery()
  to service_role;

commit;
