-- Keep the payment-attempt claim boundary valid for both Fiuu sandbox and live
-- merchant IDs. The Edge Function selects the correct credential set from the
-- exact Supabase project; the database only validates the merchant-ID format.

create or replace function public.claim_fiuu_payment_attempt(
  p_token uuid,
  p_order_id text,
  p_merchant_id text,
  p_amount numeric,
  p_expires_at timestamptz
)
returns public.booking_payment_attempts
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_first public.booking_holds%rowtype;
  v_count integer := 0;
  v_amount numeric;
  v_expiry timestamptz;
  v_outlet_id uuid;
  v_existing public.booking_payment_attempts%rowtype;
  v_result public.booking_payment_attempts%rowtype;
begin
  if p_token is null or p_order_id !~ '^W[A-Za-z0-9]{32}$'
     or p_merchant_id !~ '^[A-Za-z0-9_-]{1,32}$' then
    raise exception 'Invalid Fiuu payment attempt';
  end if;

  for v_first in
    select h.* from public.booking_holds h
    where h.booking_group_token = p_token or h.public_token = p_token
    order by h.guest_index nulls first, h.id
    for update
  loop
    v_count := v_count + 1;
    if v_count = 1 then
      v_expiry := v_first.expires_at;
      v_outlet_id := v_first.outlet_id;
      v_amount := 0;
    end if;
    if v_first.status <> 'pending_payment' or v_first.expires_at <= now()
       or v_first.billplz_bill_id is not null then
      raise exception 'This booking hold cannot start Fiuu payment';
    end if;
    if v_first.expires_at is distinct from v_expiry then
      raise exception 'Booking group deadline is inconsistent';
    end if;
    if v_first.outlet_id is distinct from v_outlet_id then
      raise exception 'Booking group outlet is inconsistent';
    end if;
    v_amount := v_amount + v_first.total_amount;
  end loop;
  if v_count = 0 or round(v_amount, 2) is distinct from round(p_amount, 2)
     or v_expiry is distinct from p_expires_at then
    raise exception 'Fiuu payment quote does not match the held booking';
  end if;

  select * into v_existing from public.booking_payment_attempts
  where hold_token = p_token for update;
  if found then
    if v_existing.amount is distinct from round(p_amount, 2)
       or v_existing.expires_at is distinct from p_expires_at
       or v_existing.merchant_id is distinct from p_merchant_id then
      raise exception 'Existing Fiuu payment attempt has different terms';
    end if;
    return v_existing;
  end if;

  insert into public.booking_payment_attempts (
    hold_token, outlet_id, merchant_id, order_id, amount, expires_at
  ) values (
    p_token, v_outlet_id, p_merchant_id, p_order_id,
    round(p_amount, 2), p_expires_at
  ) returning * into v_result;
  return v_result;
end;
$function$;

revoke all on function public.claim_fiuu_payment_attempt(
  uuid, text, text, numeric, timestamptz
) from public, anon, authenticated;
grant execute on function public.claim_fiuu_payment_attempt(
  uuid, text, text, numeric, timestamptz
) to service_role;
