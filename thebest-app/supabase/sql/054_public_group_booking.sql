-- Atomic public bookings for 1-6 guests. Each guest keeps an ordinary hold and
-- appointment, while the group has one public reference and one Billplz bill.

alter table public.booking_holds
  add column if not exists booking_group_token uuid,
  add column if not exists guest_index integer,
  add column if not exists guest_name text not null default '',
  add column if not exists appointment_group_id uuid
    references public.appointment_groups(id) on delete set null;

create index if not exists booking_holds_group_token_idx
  on public.booking_holds(booking_group_token, guest_index);

create or replace function public.create_public_booking_group_hold_v1(
  p_allocations jsonb,
  p_start_at timestamptz,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_notes text default '',
  p_request_fingerprint text default ''
)
returns table (
  group_token uuid,
  hold_expires_at timestamptz,
  total_price numeric,
  guest_count integer
)
language plpgsql security definer set search_path = public as $$
declare
  v_group_token uuid := gen_random_uuid();
  v_item jsonb;
  v_hold record;
  v_index integer := 0;
  v_total numeric := 0;
  v_expiry timestamptz;
  v_count integer := jsonb_array_length(coalesce(p_allocations, '[]'::jsonb));
begin
  if jsonb_typeof(p_allocations) <> 'array' or v_count < 1 or v_count > 6 then
    raise exception 'A group must contain between 1 and 6 guests';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    v_index := v_index + 1;
    select * into v_hold
    from public.create_public_booking_hold_v2(
      (v_item->>'catalogue_id')::uuid,
      p_start_at,
      coalesce(v_item->>'therapist_preference', 'none'),
      p_customer_name,
      p_customer_phone,
      p_customer_email,
      coalesce(v_item->>'therapist_request', ''),
      p_notes,
      p_request_fingerprint
    );

    update public.booking_holds
    set booking_group_token = v_group_token,
        guest_index = v_index,
        guest_name = left(coalesce(nullif(trim(v_item->>'guest_name'), ''), 'Guest ' || v_index), 80),
        updated_at = now()
    where id = v_hold.hold_id;

    v_total := v_total + v_hold.total_price;
    v_expiry := case when v_expiry is null then v_hold.hold_expires_at
      else least(v_expiry, v_hold.hold_expires_at) end;
  end loop;

  group_token := v_group_token;
  hold_expires_at := v_expiry;
  total_price := v_total;
  guest_count := v_count;
  return next;
end;
$$;

create or replace function public.get_booking_group_for_payment(p_token uuid)
returns table (
  customer_name text, customer_phone text, customer_email text,
  total_amount numeric, status text, expires_at timestamptz
)
language sql security definer set search_path = public stable as $$
  select min(h.customer_name), min(h.customer_phone), min(h.customer_email),
         sum(h.total_amount),
         case when bool_and(h.status = 'pending_payment') then 'pending_payment'
              when bool_and(h.status = 'confirmed') then 'confirmed'
              else 'mixed' end,
         min(h.expires_at)
  from public.booking_holds h
  where h.booking_group_token = p_token
  having count(*) > 0;
$$;

create or replace function public.record_billplz_group_bill(p_token uuid, p_bill_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.booking_holds h
    where h.booking_group_token = p_token
      and h.status = 'pending_payment' and h.expires_at > now()
  ) then raise exception 'This booking hold can no longer accept payment'; end if;

  update public.booking_holds
  set billplz_bill_id = case when guest_index = 1 then p_bill_id else null end,
      updated_at = now()
  where booking_group_token = p_token;
end;
$$;

create or replace function public.get_booking_group_token_by_bill(p_bill_id text)
returns uuid language sql security definer set search_path = public stable as $$
  select booking_group_token from public.booking_holds
  where billplz_bill_id = p_bill_id limit 1;
$$;

create or replace function public.mark_booking_group_payment_failed(p_token uuid)
returns void language sql security definer set search_path = public as $$
  update public.booking_holds set status = 'payment_failed', updated_at = now()
  where booking_group_token = p_token and status = 'pending_payment';
$$;

create or replace function public.confirm_public_booking_group_v1(p_token uuid)
returns table (
  appointment_group_id uuid, appointment_ids uuid[], status text,
  start_at timestamptz, end_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_group_id uuid;
  v_hold record;
  v_confirmed record;
  v_ids uuid[] := '{}'::uuid[];
  v_first public.booking_holds%rowtype;
  v_count integer;
begin
  select * into v_first from public.booking_holds
  where booking_group_token = p_token order by guest_index limit 1 for update;
  if not found then raise exception 'Booking reference not found'; end if;

  if v_first.appointment_group_id is not null then
    select array_agg(h.appointment_id order by h.guest_index), min(h.start_at), max(h.end_at)
    into v_ids, start_at, end_at from public.booking_holds h
    where h.booking_group_token = p_token;
    appointment_group_id := v_first.appointment_group_id;
    appointment_ids := v_ids;
    status := 'confirmed';
    return next; return;
  end if;

  for v_hold in select * from public.booking_holds
    where booking_group_token = p_token order by guest_index for update
  loop
    select * into v_confirmed from public.confirm_public_booking_hold(v_hold.public_token);
    v_ids := array_append(v_ids, v_confirmed.appointment_id);
  end loop;

  select * into v_first from public.booking_holds
  where booking_group_token = p_token order by guest_index limit 1;

  v_count := cardinality(v_ids);
  insert into public.appointment_groups (
    outlet_id, customer_id, group_name, pax_count, appointment_date, status, notes
  ) values (
    v_first.outlet_id, v_first.customer_id,
    coalesce(nullif(v_first.customer_name, ''), 'Online') || ' group',
    v_count, (v_first.start_at at time zone 'Asia/Kuala_Lumpur')::date,
    'confirmed', v_first.notes
  ) returning id into v_group_id;

  update public.appointments set appointment_group_id = v_group_id, updated_at = now()
  where id = any(v_ids);
  update public.booking_holds set appointment_group_id = v_group_id, updated_at = now()
  where booking_group_token = p_token;

  appointment_group_id := v_group_id;
  appointment_ids := v_ids;
  status := 'confirmed';
  select min(h.start_at), max(h.end_at) into start_at, end_at
  from public.booking_holds h where h.booking_group_token = p_token;
  return next;
end;
$$;

create or replace function public.record_online_booking_group_payment(p_token uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_group_id uuid;
  v_first public.booking_holds%rowtype;
  v_customer public.customers%rowtype;
  v_service_price numeric := 0;
  v_sst numeric := 0;
  v_total numeric := 0;
  v_items jsonb;
  v_count integer;
  v_transaction_id uuid;
begin
  select * into v_first from public.booking_holds
  where booking_group_token = p_token order by guest_index limit 1 for update;
  if not found or v_first.appointment_group_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  v_group_id := v_first.appointment_group_id;

  select sum(h.total_amount), count(*),
    jsonb_agg(coalesce(h.service_items->0, '{}'::jsonb) || jsonb_build_object(
      'appointment_id', h.appointment_id,
      'guest_name', h.guest_name,
      'price', h.total_amount
    ) order by h.guest_index)
  into v_total, v_count, v_items
  from public.booking_holds h where h.booking_group_token = p_token;

  select b.service_price, b.sst_amount into v_service_price, v_sst
  from public.outlet_payment_breakdown(v_first.outlet_id, v_total) b;
  select * into v_customer from public.customers where id = v_first.customer_id;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_name, service_items, item_count, service_price, sst_amount, total_amount,
    payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_first.outlet_id, v_group_id, v_first.customer_id,
    coalesce(v_customer.name, v_first.customer_name), coalesce(v_customer.phone, v_first.customer_phone),
    'Online group booking', v_items, v_count, v_service_price, v_sst, v_total,
    'billplz', 'paid', 'BP-' || upper(coalesce(v_first.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_group_id) where appointment_group_id is not null
  do update set payment_status = 'paid', service_price = excluded.service_price,
    sst_amount = excluded.sst_amount, total_amount = excluded.total_amount,
    receipt_number = excluded.receipt_number
  returning id into v_transaction_id;
  return v_transaction_id;
end;
$$;

create or replace function public.get_public_booking_group_status_v1(p_token uuid)
returns table (
  token uuid, status text, expires_at timestamptz, total_price numeric,
  start_at timestamptz, end_at timestamptz, guest_count integer
)
language sql security definer set search_path = public as $$
  select p_token,
    case when bool_and(h.status = 'confirmed') then 'confirmed'
         when bool_or(h.status = 'payment_failed') then 'payment_failed'
         when bool_or(h.status = 'expired') then 'expired'
         when bool_or(h.status = 'cancelled') then 'cancelled'
         else 'pending_payment' end,
    min(h.expires_at), sum(h.total_amount), min(h.start_at), max(h.end_at), count(*)::integer
  from public.booking_holds h where h.booking_group_token = p_token
  having count(*) > 0;
$$;

do $$ declare f text; begin
  foreach f in array array[
    'create_public_booking_group_hold_v1(jsonb,timestamptz,text,text,text,text,text)',
    'get_booking_group_for_payment(uuid)',
    'record_billplz_group_bill(uuid,text)',
    'get_booking_group_token_by_bill(text)',
    'mark_booking_group_payment_failed(uuid)',
    'confirm_public_booking_group_v1(uuid)',
    'record_online_booking_group_payment(uuid)',
    'get_public_booking_group_status_v1(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
