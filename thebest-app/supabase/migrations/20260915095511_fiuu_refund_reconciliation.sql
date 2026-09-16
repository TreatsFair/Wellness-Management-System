-- Durable, at-most-once Fiuu refund submission and signed status reconciliation.
-- The Edge Function queues a refund only after process_verified_fiuu_payment()
-- has classified a verified successful payment as refund_required.

create table public.booking_payment_refunds (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null unique
    references public.booking_payment_attempts(id) on delete restrict,
  gateway_transaction_id text not null unique,
  amount numeric(12, 2) not null check (amount > 0),
  status text not null default 'awaiting_gateway'
    check (status in (
      'awaiting_gateway', 'queued', 'submitting', 'requested', 'checking',
      'succeeded', 'needs_review'
    )),
  claim_token uuid,
  claim_expires_at timestamptz,
  submission_attempts integer not null default 0
    check (submission_attempts >= 0),
  status_checks integer not null default 0 check (status_checks >= 0),
  gateway_refund_id text,
  gateway_status text,
  last_error_code text,
  last_error text,
  next_action_at timestamptz not null default now(),
  requested_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index booking_payment_refunds_action_idx
  on public.booking_payment_refunds (status, next_action_at)
  where status in ('awaiting_gateway', 'queued', 'requested');

alter table public.booking_payment_refunds enable row level security;
revoke all on public.booking_payment_refunds
  from public, anon, authenticated;
grant select, insert, update on public.booking_payment_refunds to service_role;

create function public.queue_fiuu_refund_reconciliation(
  p_order_id text,
  p_transaction_id text
)
returns public.booking_payment_refunds
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_attempt public.booking_payment_attempts%rowtype;
  v_refund public.booking_payment_refunds%rowtype;
begin
  if p_order_id !~ '^W[A-Za-z0-9]{32}$'
     or p_transaction_id !~ '^[0-9]{1,20}$' then
    raise exception 'Invalid Fiuu refund reconciliation request';
  end if;

  select * into v_attempt
  from public.booking_payment_attempts a
  where a.order_id = p_order_id
  for update;

  if not found or v_attempt.status <> 'refund_required'
     or v_attempt.gateway_transaction_id is distinct from p_transaction_id then
    raise exception 'Fiuu payment is not eligible for refund submission';
  end if;

  insert into public.booking_payment_refunds (
    attempt_id, gateway_transaction_id, amount
  ) values (
    v_attempt.id, p_transaction_id, v_attempt.amount
  ) on conflict (attempt_id) do nothing;

  select * into v_refund
  from public.booking_payment_refunds r
  where r.attempt_id = v_attempt.id
  for update;

  return v_refund;
end;
$function$;

revoke all on function public.queue_fiuu_refund_reconciliation(text, text)
  from public, anon, authenticated;
grant execute on function public.queue_fiuu_refund_reconciliation(text, text)
  to service_role;

create function public.claim_fiuu_refund_submission()
returns public.booking_payment_refunds
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_refund public.booking_payment_refunds%rowtype;
begin
  -- A row reaches queued only after a signed status query still shows the late
  -- payment captured. This lets Fiuu's own expiry/refund process run first.
  select * into v_refund
  from public.booking_payment_refunds r
  where r.status = 'queued' and r.next_action_at <= now()
  order by r.next_action_at, r.created_at
  for update skip locked
  limit 1;
  if not found then
    return null;
  end if;

  update public.booking_payment_refunds
  set status = 'submitting',
      claim_token = gen_random_uuid(),
      claim_expires_at = now() + interval '10 minutes',
      submission_attempts = submission_attempts + 1,
      updated_at = now()
  where id = v_refund.id
  returning * into v_refund;
  return v_refund;
end;
$function$;

revoke all on function public.claim_fiuu_refund_submission()
  from public, anon, authenticated;
grant execute on function public.claim_fiuu_refund_submission()
  to service_role;

create function public.complete_fiuu_refund_submission(
  p_claim_token uuid,
  p_gateway_refund_id text,
  p_gateway_status text,
  p_accepted boolean,
  p_error_code text default null,
  p_error text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_refund public.booking_payment_refunds%rowtype;
begin
  select * into v_refund
  from public.booking_payment_refunds r
  where r.claim_token = p_claim_token and r.status = 'submitting'
  for update;
  if not found then
    raise exception 'Fiuu refund submission claim is no longer current';
  end if;

  update public.booking_payment_refunds
  set status = case when p_accepted then 'requested' else 'needs_review' end,
      gateway_refund_id = nullif(p_gateway_refund_id, ''),
      gateway_status = nullif(p_gateway_status, ''),
      last_error_code = nullif(p_error_code, ''),
      last_error = nullif(left(p_error, 500), ''),
      next_action_at = case
        when p_accepted then now() + interval '10 minutes'
        else next_action_at
      end,
      requested_at = case when p_accepted then now() else requested_at end,
      claim_token = null,
      claim_expires_at = null,
      updated_at = now()
  where id = v_refund.id;

  return case when p_accepted then 'requested' else 'needs_review' end;
end;
$function$;

revoke all on function public.complete_fiuu_refund_submission(
  uuid, text, text, boolean, text, text
) from public, anon, authenticated;
grant execute on function public.complete_fiuu_refund_submission(
  uuid, text, text, boolean, text, text
) to service_role;

create function public.fail_fiuu_refund_submission(
  p_claim_token uuid,
  p_error text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_updated integer;
begin
  -- A transport failure can happen after Fiuu accepted the request. Retrying
  -- could create a duplicate refund, so ambiguous submissions need review.
  update public.booking_payment_refunds
  set status = 'needs_review',
      last_error = nullif(left(p_error, 500), ''),
      claim_token = null,
      claim_expires_at = null,
      updated_at = now()
  where claim_token = p_claim_token and status = 'submitting';
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$function$;

revoke all on function public.fail_fiuu_refund_submission(uuid, text)
  from public, anon, authenticated;
grant execute on function public.fail_fiuu_refund_submission(uuid, text)
  to service_role;

create function public.mark_stale_fiuu_refund_submissions_for_review()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_updated integer;
begin
  update public.booking_payment_refunds
  set status = 'needs_review',
      last_error = coalesce(last_error, 'Refund submission outcome is unknown'),
      claim_token = null,
      claim_expires_at = null,
      updated_at = now()
  where status = 'submitting' and claim_expires_at <= now();
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$function$;

revoke all on function public.mark_stale_fiuu_refund_submissions_for_review()
  from public, anon, authenticated;
grant execute on function public.mark_stale_fiuu_refund_submissions_for_review()
  to service_role;

create function public.claim_fiuu_refund_status_check()
returns public.booking_payment_refunds
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_refund public.booking_payment_refunds%rowtype;
begin
  select * into v_refund
  from public.booking_payment_refunds r
  where r.status in ('awaiting_gateway', 'requested')
    and r.next_action_at <= now()
  order by r.next_action_at, r.created_at
  for update skip locked
  limit 1;
  if not found then
    return null;
  end if;

  update public.booking_payment_refunds
  set status = 'checking',
      claim_token = gen_random_uuid(),
      claim_expires_at = now() + interval '5 minutes',
      status_checks = status_checks + 1,
      updated_at = now()
  where id = v_refund.id
  returning * into v_refund;
  return v_refund;
end;
$function$;

revoke all on function public.claim_fiuu_refund_status_check()
  from public, anon, authenticated;
grant execute on function public.claim_fiuu_refund_status_check()
  to service_role;

create function public.complete_fiuu_refund_status_check(
  p_claim_token uuid,
  p_gateway_status text,
  p_status_name text,
  p_error_code text,
  p_error text
)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_refund public.booking_payment_refunds%rowtype;
  v_completed boolean;
  v_status_name text;
  v_next_status text;
begin
  select * into v_refund
  from public.booking_payment_refunds r
  where r.claim_token = p_claim_token and r.status = 'checking'
  for update;
  if not found then
    raise exception 'Fiuu refund status claim is no longer current';
  end if;

  v_completed := p_error_code = '34'
    or lower(coalesce(p_status_name, '')) in (
      'cancelled', 'refunded', 'refund', 'voided', 'void'
    );
  v_status_name := lower(coalesce(p_status_name, ''));
  v_next_status := case
    when v_completed then 'succeeded'
    when v_refund.requested_at is not null then 'requested'
    when v_status_name in ('captured', 'settled', 'authorized') then 'queued'
    when v_status_name in ('pending', 'unknown') then 'awaiting_gateway'
    else 'needs_review'
  end;

  update public.booking_payment_refunds
  set status = v_next_status,
      gateway_status = nullif(p_gateway_status, ''),
      last_error_code = nullif(p_error_code, ''),
      last_error = nullif(left(p_error, 500), ''),
      next_action_at = case v_next_status
        when 'queued' then now()
        when 'awaiting_gateway' then now() + interval '10 minutes'
        when 'requested' then now() + interval '30 minutes'
        else next_action_at
      end,
      completed_at = case when v_completed then now() else completed_at end,
      claim_token = null,
      claim_expires_at = null,
      updated_at = now()
  where id = v_refund.id;

  if v_completed then
    update public.booking_payment_attempts
    set status = 'refunded', resolved_at = now(), updated_at = now()
    where id = v_refund.attempt_id and status = 'refund_required';
  end if;

  return v_next_status;
end;
$function$;

revoke all on function public.complete_fiuu_refund_status_check(
  uuid, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.complete_fiuu_refund_status_check(
  uuid, text, text, text, text
) to service_role;

create function public.fail_fiuu_refund_status_check(
  p_claim_token uuid,
  p_error text,
  p_needs_review boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_updated integer;
begin
  update public.booking_payment_refunds
  set status = case
        when p_needs_review then 'needs_review'
        when requested_at is null then 'awaiting_gateway'
        else 'requested'
      end,
      last_error = nullif(left(p_error, 500), ''),
      next_action_at = case
        when p_needs_review then next_action_at
        else now() + interval '30 minutes'
      end,
      claim_token = null,
      claim_expires_at = null,
      updated_at = now()
  where claim_token = p_claim_token and status = 'checking';
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$function$;

revoke all on function public.fail_fiuu_refund_status_check(
  uuid, text, boolean
) from public, anon, authenticated;
grant execute on function public.fail_fiuu_refund_status_check(
  uuid, text, boolean
) to service_role;
