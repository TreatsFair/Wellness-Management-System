-- 091_billplz_receipt_notes.sql
--
-- Adds the customer's booking notes as a 13th column on the two payment RPCs
-- (090_billplz_receipt_details.sql), so booking-api can put them on the Billplz
-- receipt alongside outlet/service/time. For a group booking every guest row
-- carries the same notes text (create_public_booking_group_hold_v1 passes p_notes
-- unchanged into every create_public_booking_hold_v2 call), so min(notes) is safe.
--
-- Same constraint as 090: adding a column to RETURNS TABLE is a return-type
-- change, so this must drop and recreate rather than CREATE OR REPLACE, and the
-- service_role-only grants must be restored afterward.

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
  pax_count integer,
  notes text
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
         1,
         h.notes
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
  pax_count integer,
  notes text
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
           h.notes,
           coalesce(nullif(c.public_name, ''), s.name, 'Service') as service_name,
           greatest(
             round(extract(epoch from (h.end_at - h.start_at)) / 60.0)::integer, 1
           ) as minutes
    from public.booking_holds h
    left join public.online_booking_services c on c.id = h.online_booking_service_id
    left join public.services s on s.id = c.service_id
    where h.booking_group_token = p_token
  ),
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
           count(*)::integer as pax_count,
           min(notes) as notes
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
         booking.pax_count,
         booking.notes
  from booking
  cross join summary
  left join public.outlets o on o.id = booking.outlet_id
  cross join lateral public.outlet_payment_breakdown(
    booking.outlet_id, booking.display_total, 'billplz'
  ) price;
$function$;

revoke all on function public.get_booking_hold_for_payment(uuid) from public;
revoke all on function public.get_booking_group_for_payment(uuid) from public;
revoke all on function public.get_booking_hold_for_payment(uuid) from anon, authenticated;
revoke all on function public.get_booking_group_for_payment(uuid) from anon, authenticated;
grant execute on function public.get_booking_hold_for_payment(uuid) to service_role;
grant execute on function public.get_booking_group_for_payment(uuid) to service_role;
