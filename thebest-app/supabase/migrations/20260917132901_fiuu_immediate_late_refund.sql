-- Automatically submit a refund for a verified Fiuu payment that arrived
-- after the booking hold expired. The gateway still determines completion;
-- the refund ledger remains requested until a signed terminal status is seen.

create or replace function public.queue_fiuu_refund_reconciliation(
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

  insert into public.booking_payment_refunds as target (
    attempt_id, gateway_transaction_id, amount, status, next_action_at
  ) values (
    v_attempt.id, p_transaction_id, v_attempt.amount, 'queued', now()
  ) on conflict (attempt_id) do update
  set status = case
        when target.status = 'awaiting_gateway'
          then 'queued'
        else target.status
      end,
      next_action_at = case
        when target.status = 'awaiting_gateway'
          then now()
        else target.next_action_at
      end,
      updated_at = case
        when target.status = 'awaiting_gateway'
          then now()
        else target.updated_at
      end;

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
