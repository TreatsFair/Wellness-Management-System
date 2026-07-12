-- Billplz payment support for the public booking flow. Service-role only
-- (called from the booking-api Edge Function), same pattern as 022.

create or replace function public.get_booking_hold_for_payment(p_token uuid)
returns table (
  hold_id uuid,
  customer_name text,
  customer_phone text,
  customer_email text,
  total_amount numeric,
  status text,
  expires_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select h.id, h.customer_name, h.customer_phone, h.customer_email,
         h.total_amount, h.status, h.expires_at
  from public.booking_holds h
  where h.public_token = p_token;
$$;

create or replace function public.record_billplz_bill(p_token uuid, p_bill_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hold public.booking_holds%rowtype;
begin
  select * into v_hold from public.booking_holds where public_token = p_token for update;
  if not found then
    raise exception 'Booking reference not found';
  end if;
  if v_hold.status <> 'pending_payment' or v_hold.expires_at <= now() then
    raise exception 'This booking hold can no longer accept payment';
  end if;

  update public.booking_holds
  set billplz_bill_id = p_bill_id,
      updated_at = now()
  where id = v_hold.id;
end;
$$;

-- Resolves a Billplz bill id back to our hold token. The callback only gives
-- us the bill id, not the booking reference the customer was given.
create or replace function public.get_booking_hold_token_by_bill(p_bill_id text)
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select public_token from public.booking_holds where billplz_bill_id = p_bill_id limit 1;
$$;

-- Only flips a hold to payment_failed while it's still pending. A hold that
-- has already been confirmed (or already marked failed) is left untouched,
-- so a late/duplicate failure callback can never clobber a real success.
create or replace function public.mark_booking_hold_payment_failed(p_token uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.booking_holds
  set status = 'payment_failed',
      updated_at = now()
  where public_token = p_token
    and status = 'pending_payment';
end;
$$;

do $$ declare f text; begin
  foreach f in array array[
    'get_booking_hold_for_payment(uuid)',
    'record_billplz_bill(uuid,text)',
    'get_booking_hold_token_by_bill(text)',
    'mark_booking_hold_payment_failed(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
