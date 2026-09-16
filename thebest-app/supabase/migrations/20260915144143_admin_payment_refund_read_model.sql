-- Admin-only, read-only projection for online payment and refund operations.
-- The underlying Fiuu ledgers remain service-role-only. This function exposes
-- no hold token, merchant credential, claim token, or signature material.

create function public.list_admin_booking_payments(
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
     or not (select public.is_admin())
     or not (select private.has_outlet_access(p_outlet_id)) then
    raise exception 'Admin access to this outlet is required'
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
    select
      event.channel,
      event.received_at
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
  from public, anon, authenticated;
grant execute on function public.list_admin_booking_payments(uuid, integer)
  to authenticated;
