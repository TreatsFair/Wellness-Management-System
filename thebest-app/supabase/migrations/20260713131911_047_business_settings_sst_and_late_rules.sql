-- Per-outlet financial and late-arrival settings.
--
-- PV128 prices are SST-inclusive. Taman Wahyu prices are SST-exclusive.
-- Payment rows store the actual transaction snapshot so receipt/history/report
-- screens can read one authoritative set of values.

alter table public.business_settings
  add column if not exists sst_enabled boolean not null default true,
  add column if not exists sst_pricing_mode text not null default 'exclusive',
  add column if not exists sst_rate_percent numeric(5,2) not null default 6.00,
  add column if not exists sst_rounding_mode text not null default 'nearest_cent',
  add column if not exists late_grace_minutes integer not null default 15,
  add column if not exists no_show_threshold_minutes integer not null default 30,
  add column if not exists auto_extend_late_arrivals boolean not null default true,
  add column if not exists delay_warning_minutes integer not null default 10;

update public.business_settings
set sst_enabled = true,
    sst_pricing_mode = 'inclusive',
    sst_rate_percent = 6.00,
    sst_rounding_mode = 'nearest_cent',
    late_grace_minutes = 15,
    no_show_threshold_minutes = 30,
    auto_extend_late_arrivals = true,
    delay_warning_minutes = 10
where outlet_id = '00000000-0000-0000-0000-000000000128';

update public.business_settings
set sst_enabled = true,
    sst_pricing_mode = 'exclusive',
    sst_rate_percent = 6.00,
    sst_rounding_mode = 'nearest_cent',
    late_grace_minutes = 15,
    no_show_threshold_minutes = 30,
    auto_extend_late_arrivals = true,
    delay_warning_minutes = 10
where outlet_id = '00000000-0000-0000-0000-000000000002';

create or replace function public.outlet_payment_breakdown(
  p_outlet_id uuid,
  p_display_price numeric
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
begin
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

  if not coalesce(v_settings.sst_enabled, false) or v_rate = 0 then
    service_price := v_price;
    sst_amount := 0;
    total_amount := v_price;
    return next;
    return;
  end if;

  if v_settings.sst_pricing_mode = 'inclusive' then
    total_amount := v_price;
    service_price := round(total_amount / (1 + v_rate), 2);
    sst_amount := round(total_amount - service_price, 2);
    return next;
    return;
  end if;

  service_price := v_price;
  sst_amount := round(service_price * v_rate, 2);
  total_amount := round(service_price + sst_amount, 2);

  if v_settings.sst_rounding_mode = 'nearest_5_sen' then
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

revoke all on function public.outlet_payment_breakdown(uuid, numeric)
  from public, anon;
grant execute on function public.outlet_payment_breakdown(uuid, numeric)
  to authenticated, service_role;

create or replace function public.mark_past_appointments_no_show(
  p_outlet_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  update public.appointments a
  set status = 'no_show'::public.appointment_status,
      updated_at = now()
  where lower(a.status::text) in ('pending', 'confirmed')
    and coalesce(a.type::text, 'appointment') = 'appointment'
    and a.actual_started_at is null
    and (p_outlet_id is null or a.outlet_id = p_outlet_id)
    and coalesce(
      a.booked_end_at,
      a.end_at,
      public.csp_end_at(
        a.appointment_date::date,
        a.start_time::time,
        a.end_time::time
      ) at time zone 'Asia/Kuala_Lumpur'
    ) + make_interval(
      mins => greatest(coalesce((
        select bs.no_show_threshold_minutes
        from public.business_settings bs
        where bs.outlet_id = a.outlet_id
        limit 1
      ), 0), 0)
    ) < now();

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.mark_past_appointments_no_show(uuid)
  from public, anon;
grant execute on function public.mark_past_appointments_no_show(uuid)
  to authenticated, service_role;

create or replace function public.prevent_appointment_resource_overlap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamp;
  v_block_end timestamp;
  v_room_total integer := 1;
  v_room_conflicts integer := 0;
begin
  if not public.csp_blocks_schedule(new.status::text) then
    return new;
  end if;

  if current_setting('app.allow_late_extension_overlap', true) = 'on' then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      coalesce(new.outlet_id::text, '') || ':' || new.appointment_date::text,
      0
    )
  );

  v_start := public.csp_appointment_start_at(new);
  v_block_end := public.csp_appointment_end_at(new)
    + make_interval(mins => greatest(coalesce(new.buffer_after_minutes, 0), 0));

  if new.therapist_id is not null and exists (
    select 1
    from public.appointments existing
    where existing.therapist_id = new.therapist_id
      and existing.id is distinct from new.id
      and public.csp_blocks_schedule(existing.status::text)
      and public.csp_appointment_start_at(existing) < v_block_end
      and public.csp_appointment_block_end_at(existing) > v_start
  ) then
    raise exception using
      errcode = '23P01',
      message = 'Therapist is already booked during this service or cleanup buffer.';
  end if;

  if new.therapist_id is not null and exists (
    select 1
    from public.booking_holds hold
    where hold.assigned_therapist_id = new.therapist_id
      and hold.status = 'pending_payment'
      and hold.expires_at > now()
      and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_block_end
      and ((hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))) at time zone 'Asia/Kuala_Lumpur') > v_start
  ) then
    raise exception using
      errcode = '23P01',
      message = 'Therapist is temporarily reserved by an online booking hold.';
  end if;

  if new.room_id is not null then
    select greatest(coalesce(total_slots, 1), 1)
    into v_room_total
    from public.rooms
    where id = new.room_id;

    select count(*)
    into v_room_conflicts
    from public.appointments existing
    where existing.room_id = new.room_id
      and existing.id is distinct from new.id
      and public.csp_blocks_schedule(existing.status::text)
      and public.csp_appointment_start_at(existing) < v_block_end
      and public.csp_appointment_block_end_at(existing) > v_start;

    v_room_conflicts := v_room_conflicts + (
      select count(*)
      from public.booking_holds hold
      where hold.assigned_room_id = new.room_id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
        and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_block_end
        and ((hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))) at time zone 'Asia/Kuala_Lumpur') > v_start
    );

    if v_room_conflicts >= coalesce(v_room_total, 1) then
      raise exception using
        errcode = '23P01',
        message = 'Room or bed capacity is already full during this service or cleanup buffer.';
    end if;
  end if;

  return new;
end;
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
  select * into v_hold
  from public.booking_holds
  where public_token = p_token
  for update;

  if not found or v_hold.status <> 'confirmed' or v_hold.appointment_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_hold.appointment_id;

  select * into v_customer from public.customers where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_appointment.room_id;

  select b.service_price, b.sst_amount, b.total_amount
  into v_service_price, v_sst_amount, v_total_amount
  from public.outlet_payment_breakdown(v_hold.outlet_id, v_hold.total_amount) b;

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
  on conflict (appointment_id) where source = 'online_booking' and appointment_id is not null
  do update set
    payment_status = 'paid',
    service_price = excluded.service_price,
    sst_amount = excluded.sst_amount,
    total_amount = excluded.total_amount,
    receipt_number = excluded.receipt_number
  returning id into v_transaction_id;

  return v_transaction_id;
end;
$$;

revoke all on function public.record_online_booking_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.record_online_booking_payment(uuid)
  to service_role;

create or replace function public.checkout_appointment_with_payment(
  p_appointment_id uuid,
  p_customer_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_booked_date date default null,
  p_booked_start_time time default null,
  p_booked_end_time time default null,
  p_booked_start_at timestamptz default null,
  p_booked_end_at timestamptz default null,
  p_end_time time default null,
  p_end_at timestamptz default null,
  p_allow_late_extension_overlap boolean default false,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default '',
  p_transaction_notes text default ''
)
returns table (
  success boolean,
  appointment_id uuid,
  transaction_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_therapist_name text;
  v_room_name text;
  v_therapist_commission numeric;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  if p_allow_late_extension_overlap then
    perform set_config('app.allow_late_extension_overlap', 'on', true);
  else
    perform set_config('app.allow_late_extension_overlap', 'off', true);
  end if;

  if not exists (select 1 from public.appointments where id = p_appointment_id) then
    success := false;
    appointment_id := null;
    transaction_id := null;
    error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.';
    return next;
    return;
  end if;

  update public.appointments
  set customer_id = p_customer_id,
      booked_date = coalesce(p_booked_date, booked_date),
      booked_start_time = coalesce(p_booked_start_time, booked_start_time),
      booked_end_time = coalesce(p_booked_end_time, booked_end_time),
      booked_start_at = coalesce(p_booked_start_at, booked_start_at),
      booked_end_at = coalesce(p_booked_end_at, booked_end_at),
      end_time = coalesce(p_end_time, end_time),
      end_at = coalesce(p_end_at, end_at),
      actual_started_at = now(),
      status = 'in_progress',
      updated_at = now()
  where id = p_appointment_id
  returning therapist_id, room_id, service_id, service_name, service_items, item_count, outlet_id
  into v_row;

  select name into v_therapist_name from public.therapists where id = v_row.therapist_id;
  select name into v_room_name from public.rooms where id = v_row.room_id;

  v_therapist_commission := public.csp_commission_for_items(v_row.service_items, v_row.therapist_id, 'Therapist');
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_row.service_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name,
    counter_staff_id, counter_staff_name,
    room_id, room_name,
    service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  )
  values (
    v_row.outlet_id, p_appointment_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_row.service_id, coalesce(v_row.service_name, ''), coalesce(v_row.service_items, '[]'::jsonb), greatest(coalesce(v_row.item_count, 1), 1),
    v_row.therapist_id, coalesce(v_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    v_row.room_id, coalesce(v_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'appointment', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method, 'paid'::public.payment_status,
    p_receipt_number, coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  success := true;
  appointment_id := p_appointment_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

create or replace function public.checkout_appointment_group_with_payment(
  p_appointment_group_id uuid,
  p_appointment_ids uuid[],
  p_customer_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_per_appointment_updates jsonb default '{}'::jsonb,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default '',
  p_transaction_notes text default ''
)
returns table (
  success boolean,
  appointment_group_id uuid,
  transaction_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_update jsonb;
  v_row record;
  v_idx integer := 0;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_outlet_id uuid;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  if p_appointment_ids is null or array_length(p_appointment_ids, 1) is null then
    success := false;
    appointment_group_id := p_appointment_group_id;
    transaction_id := null;
    error_code := 'INVALID_ALLOCATIONS';
    error_message := 'No appointments supplied for checkout.';
    return next;
    return;
  end if;

  foreach v_id in array p_appointment_ids loop
    v_idx := v_idx + 1;
    v_update := coalesce(p_per_appointment_updates -> v_id::text, '{}'::jsonb);

    perform set_config(
      'app.allow_late_extension_overlap',
      case
        when coalesce((v_update ->> 'allow_late_extension_overlap')::boolean, false)
        then 'on'
        else 'off'
      end,
      true
    );

    update public.appointments
    set customer_id = p_customer_id,
        booked_date = coalesce((v_update ->> 'booked_date')::date, booked_date),
        booked_start_time = coalesce((v_update ->> 'booked_start_time')::time, booked_start_time),
        booked_end_time = coalesce((v_update ->> 'booked_end_time')::time, booked_end_time),
        booked_start_at = coalesce((v_update ->> 'booked_start_at')::timestamptz, booked_start_at),
        booked_end_at = coalesce((v_update ->> 'booked_end_at')::timestamptz, booked_end_at),
        end_time = coalesce((v_update ->> 'end_time')::time, end_time),
        end_at = coalesce((v_update ->> 'end_at')::timestamptz, end_at),
        actual_started_at = now(),
        status = 'in_progress',
        updated_at = now()
    where id = v_id
    returning therapist_id, room_id, service_id, service_name, service_items, outlet_id
    into v_row;

    if not found then
      raise exception 'Appointment % was not found for group checkout', v_id;
    end if;

    v_all_items := v_all_items || coalesce(v_row.service_items, '[]'::jsonb);
    v_item_count := v_item_count + jsonb_array_length(coalesce(v_row.service_items, '[]'::jsonb));
    v_outlet_id := coalesce(v_outlet_id, v_row.outlet_id);
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(v_row.service_items, v_row.therapist_id, 'Therapist');

    if v_idx = 1 then
      v_first_therapist_id := v_row.therapist_id;
      v_first_room_id := v_row.room_id;
      v_first_service_id := v_row.service_id;
      v_first_service_name := v_row.service_name;
      select name into v_first_therapist_name from public.therapists where id = v_row.therapist_id;
      select name into v_first_room_name from public.rooms where id = v_row.room_id;
    end if;
  end loop;

  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name,
    counter_staff_id, counter_staff_name,
    room_id, room_name,
    service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  )
  values (
    v_outlet_id, p_appointment_group_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items, greatest(v_item_count, 1),
    v_first_therapist_id, coalesce(v_first_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    v_first_room_id, coalesce(v_first_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'appointment', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method, 'paid'::public.payment_status,
    p_receipt_number, coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  success := true;
  appointment_group_id := p_appointment_group_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

revoke execute on function public.checkout_appointment_with_payment(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  time, timestamptz, boolean, uuid, text, numeric, numeric, numeric, text, text, text
) from public, anon;
grant execute on function public.checkout_appointment_with_payment(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  time, timestamptz, boolean, uuid, text, numeric, numeric, numeric, text, text, text
) to authenticated;

revoke execute on function public.checkout_appointment_group_with_payment(
  uuid, uuid[], uuid, text, text, jsonb, uuid, text,
  numeric, numeric, numeric, text, text, text
) from public, anon;
grant execute on function public.checkout_appointment_group_with_payment(
  uuid, uuid[], uuid, text, text, jsonb, uuid, text,
  numeric, numeric, numeric, text, text, text
) to authenticated;
;
