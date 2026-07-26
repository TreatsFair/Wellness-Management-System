-- 092_billplz_receipt_number_match_app.sql
--
-- The website's post-payment confirmation showed "reference B024DFB5" — the first
-- 8 characters of our own booking token, computed client-side in booking-page.js.
-- The app shows a completely different string for the same booking: 'BP-' plus
-- Billplz's own bill id, written into transactions.receipt_number by
-- record_online_booking_payment / record_online_booking_group_payment once the
-- Billplz webhook confirms payment. The two were never the same value.
--
-- Rather than invent a third format, expose the real receipt_number here so the
-- website can show the exact string staff will see in the app. It's null until
-- the transaction exists (i.e. before payment completes), which the Edge Function
-- and the website both already treat as "not confirmed yet".
--
-- Same return-type-change constraint as 090/091: drop and recreate, restore grants.

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
  notes text,
  receipt_number text
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
         h.notes,
         (
           select t.receipt_number from public.transactions t
           where t.appointment_id = h.appointment_id and t.source = 'online_booking'
           order by t.created_at limit 1
         )
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
  notes text,
  receipt_number text
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
           h.appointment_group_id,
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
           min(notes) as notes,
           (array_agg(appointment_group_id) filter (where appointment_group_id is not null))[1]
             as appointment_group_id
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
         booking.notes,
         (
           select t.receipt_number from public.transactions t
           where t.appointment_group_id = booking.appointment_group_id
             and t.source = 'online_booking'
           order by t.created_at limit 1
         )
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
