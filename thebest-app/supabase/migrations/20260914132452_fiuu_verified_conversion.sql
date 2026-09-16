-- Apply only after the separate fiuu_payment_method enum migration has committed.
-- This RPC is service-role-only. The Edge Function must verify Fiuu's skey,
-- merchant ID, order ID, amount and currency before invoking it.

create table public.booking_payment_events (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.booking_payment_attempts(id),
  gateway_transaction_id text not null,
  gateway_status text not null check (gateway_status in ('00', '11', '22')),
  channel text,
  outcome text not null,
  received_at timestamptz not null default now(),
  unique (attempt_id, gateway_transaction_id, gateway_status, outcome)
);
create index booking_payment_events_attempt_id_idx
  on public.booking_payment_events (attempt_id, received_at);
alter table public.booking_payment_events enable row level security;
revoke all on public.booking_payment_events from public, anon, authenticated;
grant select, insert on public.booking_payment_events to service_role;

create function public.process_verified_fiuu_payment(
  p_order_id text,
  p_merchant_id text,
  p_amount numeric,
  p_transaction_id text,
  p_status text,
  p_channel text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_attempt public.booking_payment_attempts%rowtype;
  v_first public.booking_holds%rowtype;
  v_group boolean;
  v_transaction_id uuid;
  v_outcome text;
begin
  if p_status not in ('00', '11', '22')
     or p_transaction_id !~ '^[0-9]{1,20}$'
     or p_channel is not null and length(p_channel) > 64 then
    raise exception 'Invalid Fiuu notification';
  end if;

  select * into v_attempt from public.booking_payment_attempts
  where order_id = p_order_id for update;
  if not found then
    raise exception 'Fiuu order was not found';
  end if;
  if v_attempt.merchant_id is distinct from p_merchant_id
     or v_attempt.amount is distinct from round(p_amount, 2) then
    raise exception 'Fiuu notification does not match its payment attempt';
  end if;

  if v_attempt.gateway_transaction_id is not null
     and v_attempt.gateway_transaction_id is distinct from p_transaction_id then
    v_outcome := 'review_different_transaction';
  elsif v_attempt.status = 'confirmed' then
    v_outcome := 'confirmed';
  elsif v_attempt.status = 'refund_required' then
    v_outcome := 'refund_required';
  elsif p_status = '22' then
    update public.booking_payment_attempts
    set status = 'pending', gateway_transaction_id = p_transaction_id,
        updated_at = now()
    where id = v_attempt.id;
    v_outcome := 'pending';
  elsif p_status = '11' then
    update public.booking_payment_attempts
    set status = 'failed', gateway_transaction_id = p_transaction_id,
        updated_at = now(), resolved_at = now()
    where id = v_attempt.id;
    v_outcome := 'failed';
  else
    v_group := exists (
      select 1 from public.booking_holds
      where booking_group_token = v_attempt.hold_token
    );
    if v_group then
      perform 1 from public.booking_holds h
      where h.booking_group_token = v_attempt.hold_token
      order by h.guest_index, h.id for update;
      select * into v_first from public.booking_holds h
      where h.booking_group_token = v_attempt.hold_token
      order by h.guest_index, h.id limit 1;
    else
      select * into v_first from public.booking_holds h
      where h.public_token = v_attempt.hold_token for update;
    end if;

    if v_first.id is null
       or v_first.outlet_id is distinct from v_attempt.outlet_id
       or v_first.billplz_bill_id is not null
       or v_attempt.expires_at <= now()
       or (v_group and exists (
         select 1 from public.booking_holds h
         where h.booking_group_token = v_attempt.hold_token
           and (h.status <> 'pending_payment'
                or h.expires_at <= now())
       ))
       or (not v_group and v_first.status <> 'pending_payment') then
      update public.booking_payment_attempts
      set status = 'refund_required',
          gateway_transaction_id = p_transaction_id,
          updated_at = now()
      where id = v_attempt.id;
      v_outcome := 'refund_required';
    else
      -- An exception block rolls back only the partial booking conversion.
      -- Paid but unfulfillable attempts remain visible for refund review.
      begin
        if v_group then
          perform public.confirm_public_booking_group_v1(v_attempt.hold_token);
          v_transaction_id := public.record_online_booking_group_payment(
            v_attempt.hold_token
          );
        else
          perform public.confirm_public_booking_hold(v_attempt.hold_token);
          v_transaction_id := public.record_online_booking_payment(
            v_attempt.hold_token
          );
        end if;
        update public.transactions
        set payment_method = 'fiuu'::public.payment_method,
            receipt_number = 'FIUU-' || upper(v_attempt.order_id)
        where id = v_transaction_id;
        if not found then
          raise exception 'Fiuu transaction could not be recorded';
        end if;
        update public.booking_payment_attempts
        set status = 'confirmed', gateway_transaction_id = p_transaction_id,
            updated_at = now(), resolved_at = now()
        where id = v_attempt.id;
        v_outcome := 'confirmed';
      exception when others then
        update public.booking_payment_attempts
        set status = 'refund_required',
            gateway_transaction_id = p_transaction_id,
            updated_at = now()
        where id = v_attempt.id;
        v_outcome := 'refund_required';
      end;
    end if;
  end if;

  insert into public.booking_payment_events (
    attempt_id, gateway_transaction_id, gateway_status, channel, outcome
  ) values (
    v_attempt.id, p_transaction_id, p_status, p_channel, v_outcome
  ) on conflict (attempt_id, gateway_transaction_id, gateway_status, outcome)
    do nothing;
  return v_outcome;
end;
$function$;

revoke all on function public.process_verified_fiuu_payment(
  text, text, numeric, text, text, text
) from public, anon, authenticated;
grant execute on function public.process_verified_fiuu_payment(
  text, text, numeric, text, text, text
) to service_role;
