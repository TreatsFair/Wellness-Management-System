create or replace function public.csp_commission_for_items(
  p_service_items jsonb,
  p_staff_id uuid,
  p_role text
)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v_overrides jsonb;
  v_is_counter boolean := position('counter' in lower(coalesce(p_role, ''))) > 0
    or position('cashier' in lower(coalesce(p_role, ''))) > 0;
  v_item jsonb;
  v_service_id uuid;
  v_total numeric := 0;
  v_default numeric;
begin
  if p_staff_id is null or p_service_items is null then
    return 0;
  end if;

  select coalesce(service_commissions, '{}'::jsonb)
  into v_overrides
  from public.therapists
  where id = p_staff_id;

  for v_item in select value from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb)) loop
    v_service_id := nullif(coalesce(v_item ->> 'id', v_item ->> 'serviceId'), '')::uuid;
    if v_service_id is null then
      continue;
    end if;

    if v_overrides is not null and v_overrides ? v_service_id::text then
      v_total := v_total + coalesce((v_overrides ->> v_service_id::text)::numeric, 0);
      continue;
    end if;

    select case when v_is_counter then counter_commission else therapist_commission end
    into v_default
    from public.services
    where id = v_service_id;

    v_total := v_total + coalesce(v_default, 0);
  end loop;

  return v_total;
end;
$$;

create or replace function public.create_walkin_appointment_with_payment(
  p_customer_id uuid,
  p_therapist_id uuid,
  p_room_id uuid,
  p_service_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_service_price numeric,
  p_service_name text,
  p_service_items jsonb,
  p_item_count integer,
  p_notes text,
  p_customer_name text,
  p_customer_phone text,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default '',
  p_transaction_notes text default '',
  p_created_by uuid default auth.uid()
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
  v_create record;
  v_outlet_id uuid;
  v_therapist_name text;
  v_room_name text;
  v_therapist_commission numeric;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  select *
  into v_create
  from public.create_appointment_with_csp(
    p_customer_id => p_customer_id,
    p_therapist_id => p_therapist_id,
    p_room_id => p_room_id,
    p_service_id => p_service_id,
    p_date => p_date,
    p_start_time => p_start_time,
    p_end_time => p_end_time,
    p_total_price => p_service_price,
    p_type => 'walkin',
    p_created_by => p_created_by,
    p_service_name => p_service_name,
    p_service_items => p_service_items,
    p_item_count => p_item_count,
    p_notes => p_notes
  );

  if not coalesce(v_create.success, false) then
    success := false;
    appointment_id := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  update public.appointments
  set status = 'in_progress',
      actual_started_at = now(),
      updated_at = now()
  where id = v_create.appointment_id
  returning outlet_id into v_outlet_id;

  select name into v_therapist_name from public.therapists where id = p_therapist_id;
  select name into v_room_name from public.rooms where id = p_room_id;

  v_therapist_commission := public.csp_commission_for_items(p_service_items, p_therapist_id, 'Therapist');
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(p_service_items, p_counter_staff_id, 'Counter') end;

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
    v_outlet_id, v_create.appointment_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    p_service_id, coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb), greatest(coalesce(p_item_count, 1), 1),
    p_therapist_id, coalesce(v_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    p_room_id, coalesce(v_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method, 'paid'::public.payment_status,
    p_receipt_number, coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  success := true;
  appointment_id := v_create.appointment_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

create or replace function public.create_walkin_appointment_group_with_payment(
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_notes text,
  p_customer_name text,
  p_customer_phone text,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default '',
  p_transaction_notes text default '',
  p_created_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  transaction_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_create record;
  v_alloc jsonb;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_outlet_id uuid;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_transaction_id uuid;
  v_idx integer := 0;
begin
  select *
  into v_create
  from public.create_appointment_group_with_csp(
    p_customer_id => p_customer_id,
    p_group_name => p_group_name,
    p_pax_count => p_pax_count,
    p_appointment_date => p_appointment_date,
    p_allocations => p_allocations,
    p_type => 'walkin',
    p_status => 'in_progress',
    p_notes => p_notes,
    p_created_by => p_created_by
  );

  if not coalesce(v_create.success, false) then
    success := false;
    appointment_group_id := null;
    appointment_ids := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  update public.appointments
  set actual_started_at = now(),
      updated_at = now()
  where appointment_group_id = v_create.appointment_group_id;

  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    v_idx := v_idx + 1;
    v_all_items := v_all_items || coalesce(v_alloc -> 'service_items', '[]'::jsonb);
    v_item_count := v_item_count + jsonb_array_length(coalesce(v_alloc -> 'service_items', '[]'::jsonb));
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_alloc -> 'service_items',
          nullif(v_alloc ->> 'therapist_id', '')::uuid,
          'Therapist'
        );

    if v_idx = 1 then
      v_first_therapist_id := nullif(v_alloc ->> 'therapist_id', '')::uuid;
      v_first_room_id := nullif(v_alloc ->> 'room_id', '')::uuid;
      v_first_service_id := nullif(v_alloc ->> 'service_id', '')::uuid;
      v_first_service_name := v_alloc ->> 'service_name';
    end if;
  end loop;

  select name into v_first_therapist_name from public.therapists where id = v_first_therapist_id;
  select name into v_first_room_name from public.rooms where id = v_first_room_id;
  select outlet_id into v_outlet_id
  from public.appointments
  where appointment_group_id = v_create.appointment_group_id
  limit 1;

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
    v_outlet_id, v_create.appointment_group_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items, greatest(v_item_count, 1),
    v_first_therapist_id, coalesce(v_first_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    v_first_room_id, coalesce(v_first_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method, 'paid'::public.payment_status,
    p_receipt_number, coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  success := true;
  appointment_group_id := v_create.appointment_group_id;
  appointment_ids := v_create.appointment_ids;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

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

    update public.appointments
    set customer_id = p_customer_id,
        booked_date = coalesce((v_update ->> 'booked_date')::date, booked_date),
        booked_start_time = coalesce((v_update ->> 'booked_start_time')::time, booked_start_time),
        booked_end_time = coalesce((v_update ->> 'booked_end_time')::time, booked_end_time),
        booked_start_at = coalesce((v_update ->> 'booked_start_at')::timestamptz, booked_start_at),
        booked_end_at = coalesce((v_update ->> 'booked_end_at')::timestamptz, booked_end_at),
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

revoke execute on function public.csp_commission_for_items(jsonb, uuid, text) from public, anon;
revoke execute on function public.create_walkin_appointment_with_payment(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer, text,
  text, text, uuid, text, numeric, numeric, text, text, text, uuid
) from public, anon;
grant execute on function public.create_walkin_appointment_with_payment(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer, text,
  text, text, uuid, text, numeric, numeric, text, text, text, uuid
) to authenticated;
revoke execute on function public.create_walkin_appointment_group_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text, numeric, numeric, numeric, text, text, text, uuid
) from public, anon;
grant execute on function public.create_walkin_appointment_group_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text, numeric, numeric, numeric, text, text, text, uuid
) to authenticated;
revoke execute on function public.checkout_appointment_with_payment(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz, uuid, text, numeric, numeric, numeric, text, text, text
) from public, anon;
grant execute on function public.checkout_appointment_with_payment(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz, uuid, text, numeric, numeric, numeric, text, text, text
) to authenticated;
revoke execute on function public.checkout_appointment_group_with_payment(
  uuid, uuid[], uuid, text, text, jsonb, uuid, text, numeric, numeric, numeric, text, text, text
) from public, anon;
grant execute on function public.checkout_appointment_group_with_payment(
  uuid, uuid[], uuid, text, text, jsonb, uuid, text, numeric, numeric, numeric, text, text, text
) to authenticated;;
