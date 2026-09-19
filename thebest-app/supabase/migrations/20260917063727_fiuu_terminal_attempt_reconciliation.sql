-- Keep the Fiuu attempt ledger aligned with terminal unpaid booking holds.
-- A later signature-verified successful payment is still handled by
-- process_verified_fiuu_payment() and becomes refund_required.

alter table public.booking_payment_attempts
  drop constraint if exists booking_payment_attempts_status_check;

alter table public.booking_payment_attempts
  add constraint booking_payment_attempts_status_check
  check (status in (
    'created', 'pending', 'failed', 'expired', 'cancelled',
    'confirmed', 'refund_required', 'refunded'
  ));

create function public.sync_fiuu_attempt_terminal_hold_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_hold_token uuid;
  v_attempt_status text;
begin
  if new.status not in ('expired', 'cancelled', 'payment_failed')
     or new.status is not distinct from old.status then
    return new;
  end if;

  v_hold_token := coalesce(new.booking_group_token, new.public_token);
  v_attempt_status := case new.status
    when 'payment_failed' then 'failed'
    when 'cancelled' then 'cancelled'
    else 'expired'
  end;

  update public.booking_payment_attempts
  set status = v_attempt_status,
      updated_at = now(),
      resolved_at = coalesce(resolved_at, now())
  where hold_token = v_hold_token
    and status in ('created', 'pending');

  return new;
end;
$function$;

revoke all on function public.sync_fiuu_attempt_terminal_hold_status()
  from public, anon, authenticated;

create trigger booking_holds_sync_fiuu_terminal_attempt
after update of status on public.booking_holds
for each row
execute function public.sync_fiuu_attempt_terminal_hold_status();

-- Reconcile attempts whose holds reached a terminal state before this trigger
-- existed. A group is closed only after none of its rows still accepts payment.
with terminal_attempts as (
  select
    attempt.id,
    case
      when bool_or(hold.status = 'payment_failed') then 'failed'
      when bool_or(hold.status = 'cancelled') then 'cancelled'
      else 'expired'
    end as terminal_status
  from public.booking_payment_attempts attempt
  join public.booking_holds hold
    on hold.public_token = attempt.hold_token
    or hold.booking_group_token = attempt.hold_token
  where attempt.status in ('created', 'pending')
  group by attempt.id
  having not bool_or(
    hold.status = 'pending_payment' and hold.expires_at > now()
  )
)
update public.booking_payment_attempts attempt
set status = terminal.terminal_status,
    updated_at = now(),
    resolved_at = coalesce(attempt.resolved_at, now())
from terminal_attempts terminal
where attempt.id = terminal.id;

-- Preserve the existing verified conversion contract while preventing a late
-- signed pending response from reopening an expired or cancelled attempt.
create or replace function public.process_verified_fiuu_payment(
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
  v_accepting_payment boolean;
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

  v_group := exists (
    select 1 from public.booking_holds
    where booking_group_token = v_attempt.hold_token
  );
  select coalesce(bool_and(
    h.status = 'pending_payment'
    and h.expires_at > now()
    and h.billplz_bill_id is null
  ), false)
  into v_accepting_payment
  from public.booking_holds h
  where h.booking_group_token = v_attempt.hold_token
     or h.public_token = v_attempt.hold_token;

  if v_attempt.gateway_transaction_id is not null
     and v_attempt.gateway_transaction_id is distinct from p_transaction_id then
    v_outcome := 'review_different_transaction';
  elsif v_attempt.status = 'confirmed' then
    v_outcome := 'confirmed';
  elsif v_attempt.status = 'refund_required' then
    v_outcome := 'refund_required';
  elsif p_status = '22' then
    if not v_accepting_payment then
      update public.booking_payment_attempts
      set status = case
            when status in ('expired', 'cancelled') then status
            else 'expired'
          end,
          gateway_transaction_id = coalesce(gateway_transaction_id, p_transaction_id),
          updated_at = now(),
          resolved_at = coalesce(resolved_at, now())
      where id = v_attempt.id;
      v_outcome := case
        when v_attempt.status = 'cancelled' then 'cancelled'
        else 'expired'
      end;
    else
      update public.booking_payment_attempts
      set status = 'pending', gateway_transaction_id = p_transaction_id,
          updated_at = now(), resolved_at = null
      where id = v_attempt.id;
      v_outcome := 'pending';
    end if;
  elsif p_status = '11' then
    update public.booking_payment_attempts
    set status = 'failed', gateway_transaction_id = p_transaction_id,
        updated_at = now(), resolved_at = now()
    where id = v_attempt.id;
    v_outcome := 'failed';
  else
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
           and (h.status <> 'pending_payment' or h.expires_at <= now())
       ))
       or (not v_group and v_first.status <> 'pending_payment') then
      update public.booking_payment_attempts
      set status = 'refund_required',
          gateway_transaction_id = p_transaction_id,
          updated_at = now(), resolved_at = null
      where id = v_attempt.id;
      v_outcome := 'refund_required';
    else
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
            updated_at = now(), resolved_at = null
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
