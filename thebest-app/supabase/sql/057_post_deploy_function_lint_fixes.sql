-- Fix function-body errors surfaced by the linked production linter after the
-- appointment add-on and public group-booking migrations were applied.

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
  v_total numeric := 0;
  v_items jsonb;
  v_count integer;
  v_transaction_id uuid;
begin
  select * into v_first
  from public.booking_holds h
  where h.booking_group_token = p_token
  order by h.guest_index
  limit 1
  for update;
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
  from public.booking_holds h
  where h.booking_group_token = p_token;

  select b.service_price, b.sst_amount into v_service_price, v_sst
  from public.outlet_payment_breakdown(v_first.outlet_id, v_total) b;
  select * into v_customer
  from public.customers c where c.id = v_first.customer_id;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_name, service_items, item_count, service_price, sst_amount,
    total_amount, payment_method, payment_status, receipt_number, source,
    is_addon, created_at
  ) values (
    v_first.outlet_id, v_group_id, v_first.customer_id,
    coalesce(v_customer.name, v_first.customer_name),
    coalesce(v_customer.phone, v_first.customer_phone),
    'Online group booking', v_items, v_count, v_service_price, v_sst, v_total,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_first.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', false, now()
  )
  on conflict (appointment_group_id)
    where appointment_group_id is not null and coalesce(is_addon, false) = false
  do update set payment_status = 'paid',
    service_price = excluded.service_price,
    sst_amount = excluded.sst_amount,
    total_amount = excluded.total_amount,
    receipt_number = excluded.receipt_number
  returning id into v_transaction_id;
  return v_transaction_id;
end;
$$;

create or replace function public.check_in_paid_appointment_group_with_addon(
  p_appointment_group_id uuid,
  p_appointment_ids uuid[],
  p_addon_items_by_appointment jsonb,
  p_per_appointment_updates jsonb default '{}'::jsonb,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default ''
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
  v_items jsonb;
  v_all_items jsonb := '[]'::jsonb;
  v_appointment public.appointments%rowtype;
  v_first public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_first_item jsonb;
  v_service_id uuid;
  v_service_name text;
  v_therapist_name text := '';
  v_room_name text := '';
  v_therapist_commission numeric := 0;
  v_transaction_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  if p_appointment_ids is null or array_length(p_appointment_ids, 1) is null then
    return query select false, p_appointment_group_id, null::uuid,
      'INVALID_APPOINTMENTS', 'No appointments were supplied.';
    return;
  end if;

  if coalesce(p_total_amount, 0) <= 0 or not exists (
    select 1
    from jsonb_each(coalesce(p_addon_items_by_appointment, '{}'::jsonb)) item
    where jsonb_typeof(item.value) = 'array'
      and jsonb_array_length(item.value) > 0
  ) then
    return query select false, p_appointment_group_id, null::uuid, 'NO_ADDONS',
      'No payable add-on services were supplied.';
    return;
  end if;

  if cardinality(p_appointment_ids) <> (
      select count(distinct supplied.id)::integer
      from unnest(p_appointment_ids) supplied(id)
    ) or cardinality(p_appointment_ids) <> (
      select count(*)::integer
      from public.appointments a
      where a.appointment_group_id = p_appointment_group_id
    ) then
    return query select false, p_appointment_group_id, null::uuid,
      'INVALID_APPOINTMENTS', 'The complete appointment group is required.';
    return;
  end if;

  foreach v_id in array p_appointment_ids loop
    select * into v_appointment
    from public.appointments a
    where a.id = v_id
      and a.appointment_group_id = p_appointment_group_id
    for update;

    if not found or v_appointment.payment_status <> 'paid' then
      raise exception 'A group appointment is missing or not paid: %', v_id;
    end if;
    if v_appointment.appointment_date <>
        (now() at time zone 'Asia/Kuala_Lumpur')::date then
      raise exception 'A group service is not scheduled for today: %', v_id;
    end if;
    if v_appointment.status not in ('pending', 'confirmed')
        or v_appointment.actual_started_at is not null then
      raise exception 'A group service has already started: %', v_id;
    end if;

    if v_first.id is null then v_first := v_appointment; end if;
    v_update := coalesce(p_per_appointment_updates -> v_id::text, '{}'::jsonb);
    v_items := coalesce(p_addon_items_by_appointment -> v_id::text, '[]'::jsonb);
    v_all_items := v_all_items || v_items;
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_items, v_appointment.therapist_id, 'Therapist'
        );

    perform set_config(
      'app.allow_late_extension_overlap',
      case when coalesce(
        (v_update ->> 'allow_late_extension_overlap')::boolean, false
      ) then 'on' else 'off' end,
      true
    );

    update public.appointments a
    set actual_started_at = now(),
        status = 'in_progress',
        end_time = coalesce((v_update ->> 'end_time')::time, a.end_time),
        end_at = coalesce((v_update ->> 'end_at')::timestamptz, a.end_at),
        updated_at = now()
    where a.id = v_id;
  end loop;

  select * into v_customer
  from public.customers c where c.id = v_first.customer_id;
  select coalesce(t.name, '') into v_therapist_name
  from public.therapists t where t.id = v_first.therapist_id;
  select coalesce(r.name, '') into v_room_name
  from public.rooms r where r.id = v_first.room_id;
  v_first_item := v_all_items -> 0;
  v_service_id := nullif(
    coalesce(v_first_item ->> 'id', v_first_item ->> 'serviceId'), ''
  )::uuid;
  v_service_name := coalesce(v_first_item ->> 'name', 'Service add-on');

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes, is_addon
  ) values (
    v_first.outlet_id, p_appointment_group_id, v_first.customer_id,
    coalesce(v_customer.name, ''), coalesce(v_customer.phone, ''),
    v_service_id, v_service_name, v_all_items, jsonb_array_length(v_all_items),
    v_first.therapist_id, v_therapist_name,
    p_counter_staff_id, p_counter_staff_name,
    v_first.room_id, v_room_name,
    p_service_price, p_sst_amount, p_total_amount,
    v_therapist_commission,
    case when p_counter_staff_id is null then 0
      else public.csp_commission_for_items(
        v_all_items, p_counter_staff_id, 'Counter'
      ) end,
    'appointment_addon',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    'Services added during group appointment check-in', true
  ) returning id into v_transaction_id;

  return query select true, p_appointment_group_id, v_transaction_id,
    null::text, null::text;
end;
$$;

revoke all on function public.record_online_booking_group_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.record_online_booking_group_payment(uuid)
  to service_role;

revoke all on function public.check_in_paid_appointment_group_with_addon(
  uuid, uuid[], jsonb, jsonb, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.check_in_paid_appointment_group_with_addon(
  uuid, uuid[], jsonb, jsonb, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;
