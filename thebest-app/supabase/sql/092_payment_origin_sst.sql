-- Price SST by payment origin. PV128 is always inclusive; Taman Wahyu is
-- inclusive only for Billplz and exclusive for every counter payment.

alter table public.business_settings
  add column if not exists billplz_sst_pricing_mode text not null default 'inclusive',
  add column if not exists counter_sst_pricing_mode text not null default 'exclusive';

alter table public.business_settings
  drop constraint if exists business_settings_billplz_sst_pricing_mode_check,
  drop constraint if exists business_settings_counter_sst_pricing_mode_check,
  drop constraint if exists business_settings_sst_rounding_mode_check;

alter table public.business_settings
  add constraint business_settings_billplz_sst_pricing_mode_check
    check (billplz_sst_pricing_mode in ('inclusive', 'exclusive')),
  add constraint business_settings_counter_sst_pricing_mode_check
    check (counter_sst_pricing_mode in ('inclusive', 'exclusive')),
  add constraint business_settings_sst_rounding_mode_check
    check (sst_rounding_mode in (
      'nearest_cent', 'nearest_5_sen', 'nearest_10_sen',
      'floor_cent', 'ceil_cent'
    ));

update public.business_settings
set billplz_sst_pricing_mode = 'inclusive',
    counter_sst_pricing_mode = 'inclusive',
    sst_pricing_mode = 'inclusive',
    sst_rate_percent = 6.00,
    sst_rounding_mode = 'nearest_cent'
where outlet_id = '00000000-0000-0000-0000-000000000128';

update public.business_settings
set billplz_sst_pricing_mode = 'inclusive',
    counter_sst_pricing_mode = 'exclusive',
    sst_pricing_mode = 'exclusive',
    sst_rate_percent = 6.00,
    sst_rounding_mode = 'nearest_10_sen'
where outlet_id = '00000000-0000-0000-0000-000000000002';

create or replace function public.outlet_payment_breakdown(
  p_outlet_id uuid,
  p_display_price numeric,
  p_payment_origin text
)
returns table (
  service_price numeric,
  sst_amount numeric,
  total_amount numeric
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_settings public.business_settings%rowtype;
  v_price numeric := round(greatest(coalesce(p_display_price, 0), 0), 2);
  v_rate numeric := 0;
  v_mode text := 'exclusive';
begin
  if lower(coalesce(p_payment_origin, 'counter')) not in ('billplz', 'counter') then
    raise exception 'Unsupported payment origin: %', p_payment_origin;
  end if;

  select * into v_settings
  from public.business_settings
  where outlet_id = p_outlet_id
  limit 1;

  if not found then
    service_price := v_price;
    sst_amount := 0;
    total_amount := v_price;
    return next;
    return;
  end if;

  v_rate := greatest(coalesce(v_settings.sst_rate_percent, 0), 0) / 100;
  v_mode := case lower(coalesce(p_payment_origin, 'counter'))
    when 'billplz' then v_settings.billplz_sst_pricing_mode
    else v_settings.counter_sst_pricing_mode
  end;

  if not coalesce(v_settings.sst_enabled, false) or v_rate = 0 then
    service_price := v_price;
    sst_amount := 0;
    total_amount := v_price;
    return next;
    return;
  end if;

  if v_mode = 'inclusive' then
    total_amount := v_price;
    service_price := round(total_amount / (1 + v_rate), 2);
    sst_amount := round(total_amount - service_price, 2);
    return next;
    return;
  end if;

  service_price := v_price;
  total_amount := round(service_price + round(service_price * v_rate, 2), 2);
  if v_settings.sst_rounding_mode = 'nearest_10_sen' then
    total_amount := round(total_amount * 10) / 10;
  elsif v_settings.sst_rounding_mode = 'nearest_5_sen' then
    total_amount := round(total_amount * 20) / 20;
  elsif v_settings.sst_rounding_mode = 'floor_cent' then
    total_amount := floor(total_amount * 100) / 100;
  elsif v_settings.sst_rounding_mode = 'ceil_cent' then
    total_amount := ceil(total_amount * 100) / 100;
  end if;
  sst_amount := round(total_amount - service_price, 2);
  return next;
end;
$$;

create or replace function public.outlet_payment_breakdown(
  p_outlet_id uuid,
  p_display_price numeric
)
returns table (service_price numeric, sst_amount numeric, total_amount numeric)
language sql
stable
set search_path = public
as $$
  select *
  from public.outlet_payment_breakdown(
    p_outlet_id,
    p_display_price,
    'counter'
  );
$$;

revoke all on function public.outlet_payment_breakdown(uuid, numeric, text)
  from public, anon;
grant execute on function public.outlet_payment_breakdown(uuid, numeric, text)
  to authenticated, service_role;

create or replace function public.get_booking_hold_for_payment(p_token uuid)
returns table (
  hold_id uuid, customer_name text, customer_phone text, customer_email text,
  total_amount numeric, status text, expires_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select h.id, h.customer_name, h.customer_phone, h.customer_email,
         price.total_amount, h.status, h.expires_at
  from public.booking_holds h
  cross join lateral public.outlet_payment_breakdown(
    h.outlet_id, h.total_amount, 'billplz'
  ) price
  where h.public_token = p_token;
$$;

create or replace function public.get_booking_group_for_payment(p_token uuid)
returns table (
  customer_name text, customer_phone text, customer_email text,
  total_amount numeric, status text, expires_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  with booking as (
    select min(h.customer_name) as customer_name,
           min(h.customer_phone) as customer_phone,
           min(h.customer_email) as customer_email,
           (array_agg(h.outlet_id order by h.guest_index))[1] as outlet_id,
           sum(h.total_amount) as display_total,
           case
             when bool_and(h.status = 'pending_payment') then 'pending_payment'
             when bool_and(h.status = 'confirmed') then 'confirmed'
             else 'mixed'
           end as status,
           min(h.expires_at) as expires_at
    from public.booking_holds h
    where h.booking_group_token = p_token
    having count(*) > 0
  )
  select booking.customer_name, booking.customer_phone, booking.customer_email,
         price.total_amount, booking.status, booking.expires_at
  from booking
  cross join lateral public.outlet_payment_breakdown(
    booking.outlet_id, booking.display_total, 'billplz'
  ) price;
$$;

create or replace function public.record_online_booking_payment(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hold public.booking_holds%rowtype;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_therapist_name text := '';
  v_room_name text := '';
  v_service_price numeric := 0;
  v_sst_amount numeric := 0;
  v_total_amount numeric := 0;
  v_transaction_id uuid;
begin
  select * into v_hold from public.booking_holds
  where public_token = p_token for update;
  if not found or v_hold.status <> 'confirmed' or v_hold.appointment_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  select * into v_appointment from public.appointments
  where id = v_hold.appointment_id;
  select * into v_customer from public.customers where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name from public.therapists
  where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name from public.rooms
  where id = v_appointment.room_id;
  select b.service_price, b.sst_amount, b.total_amount
  into v_service_price, v_sst_amount, v_total_amount
  from public.outlet_payment_breakdown(
    v_hold.outlet_id, v_hold.total_amount, 'billplz'
  ) b;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, room_id, room_name,
    service_price, sst_amount, total_amount,
    payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_hold.outlet_id, v_appointment.id, v_appointment.customer_id,
    coalesce(v_customer.name, v_hold.customer_name),
    coalesce(v_customer.phone, v_hold.customer_phone),
    v_appointment.service_id, v_appointment.service_name,
    v_appointment.service_items, v_appointment.item_count,
    v_appointment.therapist_id, v_therapist_name,
    v_appointment.room_id, v_room_name,
    v_service_price, v_sst_amount, v_total_amount,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_hold.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_id)
    where source = 'online_booking' and appointment_id is not null
  do update set payment_status = 'paid',
                service_price = excluded.service_price,
                sst_amount = excluded.sst_amount,
                total_amount = excluded.total_amount,
                receipt_number = excluded.receipt_number
  returning id into v_transaction_id;
  return v_transaction_id;
end;
$$;

create or replace function public.record_online_booking_group_payment(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_first public.booking_holds%rowtype;
  v_customer public.customers%rowtype;
  v_service_price numeric := 0;
  v_sst numeric := 0;
  v_display_total numeric := 0;
  v_total numeric := 0;
  v_items jsonb;
  v_count integer;
  v_transaction_id uuid;
begin
  select * into v_first from public.booking_holds h
  where h.booking_group_token = p_token order by h.guest_index limit 1 for update;
  if not found or v_first.appointment_group_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  v_group_id := v_first.appointment_group_id;

  select sum(h.total_amount), count(*),
         jsonb_agg(
           coalesce(h.service_items -> 0, '{}'::jsonb)
           || jsonb_strip_nulls(jsonb_build_object(
             'id', a.service_id,
             'name', coalesce(nullif(a.service_name, ''),
               nullif(h.service_items -> 0 ->> 'public_name', ''), s.name, 'Service'),
             'appointmentId', h.appointment_id,
             'guestName', h.guest_name,
             'price', h.total_amount,
             'lineType', 'booked',
             'assignedTherapistId', a.therapist_id,
             'assignedTherapistName', therapist.name,
             'assignedRoomId', a.room_id,
             'assignedRoomName', room.name
           )) order by h.guest_index
         )
  into v_display_total, v_count, v_items
  from public.booking_holds h
  join public.appointments a on a.id = h.appointment_id
  left join public.services s on s.id = a.service_id
  left join public.therapists therapist on therapist.id = a.therapist_id
  left join public.rooms room on room.id = a.room_id
  where h.booking_group_token = p_token;

  select b.service_price, b.sst_amount, b.total_amount
  into v_service_price, v_sst, v_total
  from public.outlet_payment_breakdown(
    v_first.outlet_id, v_display_total, 'billplz'
  ) b;
  select * into v_customer from public.customers c where c.id = v_first.customer_id;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_name, service_items, item_count, service_price, sst_amount,
    total_amount, payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_first.outlet_id, v_group_id, v_first.customer_id,
    coalesce(v_customer.name, v_first.customer_name),
    coalesce(v_customer.phone, v_first.customer_phone),
    'Online group booking', v_items, v_count, v_service_price, v_sst, v_total,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_first.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_group_id)
    where appointment_group_id is not null
      and coalesce(source, '') <> 'appointment_addon'
  do update set payment_status = 'paid', service_name = excluded.service_name,
                service_items = excluded.service_items, item_count = excluded.item_count,
                service_price = excluded.service_price, sst_amount = excluded.sst_amount,
                total_amount = excluded.total_amount,
                receipt_number = excluded.receipt_number
  returning id into v_transaction_id;
  return v_transaction_id;
end;
$$;

-- Dummy-data repair authorised for every existing non-Billplz Taman Wahyu
-- receipt. Item snapshot prices are the pre-tax source; service_price is the
-- fallback. Receipt identity, links, payment state and commissions are untouched.
with item_totals as (
  select t.id,
         sum(
           case
             when coalesce(item.value ->> 'price', item.value ->> 'displayPrice',
                           item.value ->> 'display_price', '')
                    ~ '^[0-9]+([.][0-9]+)?$'
             then coalesce(item.value ->> 'price', item.value ->> 'displayPrice',
                           item.value ->> 'display_price')::numeric
             else 0
           end
           * case
               when coalesce(item.value ->> 'quantity', '1') ~ '^[0-9]+$'
               then greatest((coalesce(item.value ->> 'quantity', '1'))::integer, 1)
               else 1
             end
         ) as item_total
  from public.transactions t
  left join lateral jsonb_array_elements(
    case when jsonb_typeof(t.service_items) = 'array'
         then t.service_items else '[]'::jsonb end
  ) item(value) on true
  where t.outlet_id = '00000000-0000-0000-0000-000000000002'
    and lower(coalesce(t.payment_method::text, 'counter')) <> 'billplz'
  group by t.id
), repair as (
  select t.id,
         round(greatest(coalesce(nullif(i.item_total, 0),
           nullif(t.service_price, 0), t.total_amount, 0), 0), 2) as base
  from public.transactions t
  join item_totals i on i.id = t.id
)
update public.transactions t
set service_price = repair.base,
    total_amount = round(round(repair.base * 1.06, 2) * 10) / 10,
    sst_amount = round((round(round(repair.base * 1.06, 2) * 10) / 10) - repair.base, 2),
    updated_at = now()
from repair
where t.id = repair.id;

revoke all on function public.get_booking_hold_for_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.get_booking_hold_for_payment(uuid) to service_role;
revoke all on function public.get_booking_group_for_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.get_booking_group_for_payment(uuid) to service_role;
revoke all on function public.record_online_booking_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.record_online_booking_payment(uuid) to service_role;
revoke all on function public.record_online_booking_group_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.record_online_booking_group_payment(uuid) to service_role;
