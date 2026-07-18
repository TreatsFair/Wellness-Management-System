-- Appointment check-in add-ons.
--
-- Primary booking payments remain unique. A checked-in prepaid appointment may
-- additionally create one appointment_addon receipt containing only services
-- added at the counter. Both the service start and add-on receipt are written
-- atomically by the RPCs below.

drop index if exists public.transactions_one_bill_per_appointment_uidx;
drop index if exists public.transactions_one_bill_per_group_uidx;

create unique index transactions_one_primary_bill_per_appointment_uidx
  on public.transactions (appointment_id)
  where appointment_id is not null
    and coalesce(source, '') <> 'appointment_addon';

create unique index transactions_one_primary_bill_per_group_uidx
  on public.transactions (appointment_group_id)
  where appointment_group_id is not null
    and coalesce(source, '') <> 'appointment_addon';

create or replace function public.sync_appointment_payment_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- An add-on receipt is supplementary. Voiding it must not void the original
  -- booking or alter the appointment's primary paid/unpaid state.
  if new.source = 'appointment_addon' then
    return new;
  end if;

  if new.appointment_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where id = new.appointment_id
      and payment_status is distinct from new.payment_status;
  end if;

  if new.appointment_group_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where appointment_group_id = new.appointment_group_id
      and payment_status is distinct from new.payment_status;
  end if;

  return new;
end;
$$;

create or replace function public.check_in_paid_appointment_with_addon(
  p_appointment_id uuid,
  p_addon_service_items jsonb,
  p_end_time time default null,
  p_end_at timestamptz default null,
  p_allow_late_extension_overlap boolean default false,
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
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_first_item jsonb;
  v_service_id uuid;
  v_service_name text;
  v_therapist_name text := '';
  v_room_name text := '';
  v_transaction_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    return query select false, null::uuid, null::uuid, 'NOT_FOUND',
      'Appointment was not found.';
    return;
  end if;

  if v_appointment.payment_status <> 'paid' then
    return query select false, p_appointment_id, null::uuid, 'NOT_PAID',
      'The original appointment payment has not been recorded.';
    return;
  end if;

  if v_appointment.appointment_date <>
      (now() at time zone 'Asia/Kuala_Lumpur')::date then
    return query select false, p_appointment_id, null::uuid, 'WRONG_DATE',
      'Service can only be checked in on its appointment date.';
    return;
  end if;

  if v_appointment.status not in ('pending', 'confirmed')
      or v_appointment.actual_started_at is not null then
    return query select false, p_appointment_id, null::uuid, 'ALREADY_STARTED',
      'Only an unstarted pending or confirmed appointment can be checked in.';
    return;
  end if;

  if jsonb_array_length(coalesce(p_addon_service_items, '[]'::jsonb)) = 0
      or coalesce(p_total_amount, 0) <= 0 then
    return query select false, p_appointment_id, null::uuid, 'NO_ADDONS',
      'No payable add-on services were supplied.';
    return;
  end if;

  if p_allow_late_extension_overlap then
    perform set_config('app.allow_late_extension_overlap', 'on', true);
  end if;

  update public.appointments
  set actual_started_at = now(),
      status = 'in_progress',
      end_time = coalesce(p_end_time, end_time),
      end_at = coalesce(p_end_at, end_at),
      updated_at = now()
  where id = p_appointment_id
  returning * into v_appointment;

  select * into v_customer
  from public.customers where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_appointment.room_id;

  v_first_item := p_addon_service_items -> 0;
  v_service_id := nullif(coalesce(v_first_item ->> 'id', v_first_item ->> 'serviceId'), '')::uuid;
  v_service_name := coalesce(v_first_item ->> 'name', 'Service add-on');

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_appointment.outlet_id, p_appointment_id, v_appointment.customer_id,
    coalesce(v_customer.name, ''), coalesce(v_customer.phone, ''),
    v_service_id, v_service_name, p_addon_service_items,
    jsonb_array_length(p_addon_service_items),
    v_appointment.therapist_id, v_therapist_name,
    p_counter_staff_id, p_counter_staff_name,
    v_appointment.room_id, v_room_name,
    p_service_price, p_sst_amount, p_total_amount,
    public.csp_commission_for_items(p_addon_service_items, v_appointment.therapist_id, 'Therapist'),
    case when p_counter_staff_id is null then 0
      else public.csp_commission_for_items(p_addon_service_items, p_counter_staff_id, 'Counter') end,
    'appointment_addon',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    'Services added during appointment check-in'
  ) returning id into v_transaction_id;

  -- Online-booking commission is normally filled at completion. Freeze the
  -- original receipt's commission from its original item snapshot now so the
  -- newly appended appointment items cannot be counted twice later.
  update public.transactions original
  set therapist_commission_amount = public.csp_commission_for_items(
        original.service_items,
        v_appointment.therapist_id,
        'Therapist'
      ),
      updated_at = now()
  where original.appointment_id = p_appointment_id
    and original.source = 'online_booking'
    and original.payment_status = 'paid'
    and coalesce(original.therapist_commission_amount, 0) = 0;

  return query select true, p_appointment_id, v_transaction_id, null::text, null::text;
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
      select count(*)::integer from public.appointments a
      where a.appointment_group_id = p_appointment_group_id
    ) then
    return query select false, p_appointment_group_id, null::uuid,
      'INVALID_APPOINTMENTS', 'The complete appointment group is required.';
    return;
  end if;

  foreach v_id in array p_appointment_ids loop
    select * into v_appointment
    from public.appointments
    where id = v_id and appointment_group_id = p_appointment_group_id
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
      + public.csp_commission_for_items(v_items, v_appointment.therapist_id, 'Therapist');

    perform set_config(
      'app.allow_late_extension_overlap',
      case when coalesce((v_update ->> 'allow_late_extension_overlap')::boolean, false)
        then 'on' else 'off' end,
      true
    );

    update public.appointments
    set actual_started_at = now(),
        status = 'in_progress',
        end_time = coalesce((v_update ->> 'end_time')::time, end_time),
        end_at = coalesce((v_update ->> 'end_at')::timestamptz, end_at),
        updated_at = now()
    where id = v_id;
  end loop;

  select * into v_customer from public.customers where id = v_first.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_first.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_first.room_id;
  v_first_item := v_all_items -> 0;
  v_service_id := nullif(coalesce(v_first_item ->> 'id', v_first_item ->> 'serviceId'), '')::uuid;
  v_service_name := coalesce(v_first_item ->> 'name', 'Service add-on');

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
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
      else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end,
    'appointment_addon',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    'Services added during group appointment check-in'
  ) returning id into v_transaction_id;

  return query select true, p_appointment_group_id, v_transaction_id,
    null::text, null::text;
end;
$$;

revoke all on function public.check_in_paid_appointment_with_addon(
  uuid, jsonb, time, timestamptz, boolean, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.check_in_paid_appointment_with_addon(
  uuid, jsonb, time, timestamptz, boolean, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;

revoke all on function public.check_in_paid_appointment_group_with_addon(
  uuid, uuid[], jsonb, jsonb, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.check_in_paid_appointment_group_with_addon(
  uuid, uuid[], jsonb, jsonb, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;
