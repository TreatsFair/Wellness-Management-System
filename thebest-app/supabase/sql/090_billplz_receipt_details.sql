-- 090_billplz_receipt_details.sql
--
-- The Billplz bill description was just "The Best Wellness online booking ABC12345",
-- so the payment page and Billplz's own receipt showed the customer nothing about
-- what they were paying for. The booking-api Edge Function can only put on the bill
-- what these two RPCs hand back, and neither returned the outlet, the service, the
-- duration, or the appointment time.
--
-- Both functions gain the same five trailing columns so the Edge Function can treat
-- single and group payments identically. Existing columns keep their names, types
-- and order, so the current deployed function keeps working if it is rolled back
-- independently of this migration.
--
-- These must be dropped rather than replaced: adding columns to RETURNS TABLE changes
-- the return type, which CREATE OR REPLACE FUNCTION rejects. Dropping also discards
-- the grants, so they are restored explicitly at the bottom of this file. Only
-- postgres and service_role may execute these — the booking-api Edge Function calls
-- them server-side with the service key. Granting anon here would re-open the hole
-- that 034_restrict_public_booking_rpc_exec.sql closed.

drop function if exists public.get_booking_hold_for_payment(uuid);
drop function if exists public.get_booking_group_for_payment(uuid);

create function public.get_booking_hold_for_payment(p_token uuid)
returns table(
  hold_id uuid,
  customer_name text,
  customer_phone text,
  customer_email text,
  total_amount numeric,
  status text,
  expires_at timestamptz,
  outlet_name text,
  service_summary text,
  duration_minutes integer,
  start_at timestamptz,
  pax_count integer
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select h.id,
         h.customer_name,
         h.customer_phone,
         h.customer_email,
         price.total_amount,
         h.status,
         h.expires_at,
         coalesce(o.name, 'The Best Wellness'),
         coalesce(nullif(c.public_name, ''), s.name, 'Service'),
         greatest(round(extract(epoch from (h.end_at - h.start_at)) / 60.0)::integer, 1),
         h.start_at,
         1
  from public.booking_holds h
  left join public.outlets o on o.id = h.outlet_id
  left join public.online_booking_services c on c.id = h.online_booking_service_id
  left join public.services s on s.id = c.service_id
  cross join lateral public.outlet_payment_breakdown(
    h.outlet_id, h.total_amount, 'billplz'
  ) price
  where h.public_token = p_token;
$function$;

create function public.get_booking_group_for_payment(p_token uuid)
returns table(
  customer_name text,
  customer_phone text,
  customer_email text,
  total_amount numeric,
  status text,
  expires_at timestamptz,
  outlet_name text,
  service_summary text,
  duration_minutes integer,
  start_at timestamptz,
  pax_count integer
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with holds as (
    select h.outlet_id,
           h.customer_name,
           h.customer_phone,
           h.customer_email,
           h.total_amount,
           h.status,
           h.expires_at,
           h.start_at,
           h.guest_index,
           coalesce(nullif(c.public_name, ''), s.name, 'Service') as service_name,
           greatest(
             round(extract(epoch from (h.end_at - h.start_at)) / 60.0)::integer, 1
           ) as minutes
    from public.booking_holds h
    left join public.online_booking_services c on c.id = h.online_booking_service_id
    left join public.services s on s.id = c.service_id
    where h.booking_group_token = p_token
  ),
  -- One line per distinct service+duration, e.g. "Body Massage 60min x2".
  summary as (
    select string_agg(label, ' + ' order by label) as service_summary
    from (
      select service_name || ' ' || minutes || 'min'
             || case when count(*) > 1 then ' x' || count(*)::text else '' end as label
      from holds
      group by service_name, minutes
    ) labelled
  ),
  booking as (
    select min(customer_name) as customer_name,
           min(customer_phone) as customer_phone,
           min(customer_email) as customer_email,
           (array_agg(outlet_id order by guest_index))[1] as outlet_id,
           sum(total_amount) as display_total,
           case
             when bool_and(status = 'pending_payment') then 'pending_payment'
             when bool_and(status = 'confirmed') then 'confirmed'
             else 'mixed'
           end as status,
           min(expires_at) as expires_at,
           min(start_at) as start_at,
           max(minutes) as minutes,
           count(*)::integer as pax_count
    from holds
    having count(*) > 0
  )
  select booking.customer_name,
         booking.customer_phone,
         booking.customer_email,
         price.total_amount,
         booking.status,
         booking.expires_at,
         coalesce(o.name, 'The Best Wellness'),
         summary.service_summary,
         booking.minutes,
         booking.start_at,
         booking.pax_count
  from booking
  cross join summary
  left join public.outlets o on o.id = booking.outlet_id
  cross join lateral public.outlet_payment_breakdown(
    booking.outlet_id, booking.display_total, 'billplz'
  ) price;
$function$;

-- Restore the grants the drops removed, and keep the public/anon lockdown from 034.
revoke all on function public.get_booking_hold_for_payment(uuid) from public;
revoke all on function public.get_booking_group_for_payment(uuid) from public;
revoke all on function public.get_booking_hold_for_payment(uuid) from anon, authenticated;
revoke all on function public.get_booking_group_for_payment(uuid) from anon, authenticated;
grant execute on function public.get_booking_hold_for_payment(uuid) to service_role;
grant execute on function public.get_booking_group_for_payment(uuid) to service_role;
