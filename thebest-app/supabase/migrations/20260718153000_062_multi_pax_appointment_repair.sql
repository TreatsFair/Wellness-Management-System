-- Preserve paid group appointment identity and support payment-only add-ons.

create or replace function public.update_appointment_group_with_csp(
  p_appointment_group_id uuid,
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_type text default 'appointment',
  p_status text default 'confirmed',
  p_notes text default '',
  p_updated_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allocation jsonb;
  v_existing_id uuid;
  v_saved_id uuid;
  v_check record;
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_start time;
  v_end time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_group_conflicts integer;
  v_group_room_slots integer;
  v_existing_count integer;
  v_group_paid boolean;
begin
  appointment_ids := array[]::uuid[];
  appointment_group_id := p_appointment_group_id;

  if not exists (
    select 1 from public.appointment_groups g
    where g.id = p_appointment_group_id
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'NOT_FOUND', 'Appointment group was not found.';
    return;
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
      or jsonb_array_length(p_allocations) = 0 then
    return query select false, p_appointment_group_id, appointment_ids,
      'INVALID_ALLOCATIONS', 'Group booking requires at least one pax allocation.';
    return;
  end if;

  select count(*) into v_existing_count
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;

  select exists (
    select 1 from public.transactions t
    where t.appointment_group_id = p_appointment_group_id
      and t.payment_status = 'paid'
      and coalesce(t.source, '') <> 'appointment_addon'
  ) or exists (
    select 1 from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and a.payment_status = 'paid'
  ) into v_group_paid;

  if (
    select count(*) <> count(distinct nullif(value ->> 'appointment_id', ''))
    from jsonb_array_elements(p_allocations)
    where nullif(value ->> 'appointment_id', '') is not null
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'DUPLICATE_APPOINTMENT', 'Each pax allocation must reference a different appointment.';
    return;
  end if;

  if v_group_paid and (
    jsonb_array_length(p_allocations) <> v_existing_count
    or exists (
      select 1 from jsonb_array_elements(p_allocations) item
      where nullif(item.value ->> 'appointment_id', '') is null
    )
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'PAID_GROUP_LOCKED', 'Paid group pax cannot be added or removed.';
    return;
  end if;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_existing_id is not null and not exists (
      select 1 from public.appointments a
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id
    ) then
      return query select false, p_appointment_group_id, appointment_ids,
        'INVALID_APPOINTMENT', 'A pax allocation does not belong to this group.';
      return;
    end if;

    if v_start is null or v_end is null or v_end = v_start then
      return query select false, p_appointment_group_id, appointment_ids,
        'INVALID_DURATION', 'One pax allocation has an invalid time range.';
      return;
    end if;

    v_start_at := public.csp_start_at(p_appointment_date, v_start);
    v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);

    select * into v_check
    from public.check_booking_availability(
      p_appointment_date, v_start, v_end, v_therapist_id, v_room_id,
      v_existing_id, p_appointment_group_id
    );

    if not coalesce(v_check.therapist_available, false) then
      return query select false, p_appointment_group_id, appointment_ids,
        'THERAPIST_UNAVAILABLE', 'One pax allocation has a staff conflict.';
      return;
    end if;

    select count(*) into v_group_conflicts
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'therapist_id')::uuid = v_therapist_id
      and public.csp_start_at(
        p_appointment_date, (other.value ->> 'start_time')::time
      ) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if v_group_conflicts > 1 then
      return query select false, p_appointment_group_id, appointment_ids,
        'THERAPIST_UNAVAILABLE',
        'The same staff cannot serve overlapping pax in one group.';
      return;
    end if;

    select count(*) into v_group_room_slots
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'room_id')::uuid = v_room_id
      and public.csp_start_at(
        p_appointment_date, (other.value ->> 'start_time')::time
      ) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots
        > coalesce(v_check.room_total_slots, 1) then
      return query select false, p_appointment_group_id, appointment_ids,
        'ROOM_FULL', 'A room or zone does not have enough slots for this group.';
      return;
    end if;
  end loop;

  update public.appointment_groups
  set customer_id = p_customer_id,
      group_name = coalesce(p_group_name, ''),
      pax_count = jsonb_array_length(p_allocations),
      appointment_date = p_appointment_date,
      status = coalesce(nullif(p_status, ''), 'confirmed'),
      notes = coalesce(p_notes, '')
  where id = p_appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_existing_id is not null then
      update public.appointments a
      set customer_id = p_customer_id,
          therapist_id = v_therapist_id,
          room_id = v_room_id,
          service_id = v_service_id,
          appointment_date = p_appointment_date,
          start_time = v_start,
          end_time = v_end,
          start_at = public.csp_start_at(p_appointment_date, v_start),
          end_at = public.csp_end_at(p_appointment_date, v_start, v_end),
          booked_date = case when a.actual_started_at is null
            then p_appointment_date else a.booked_date end,
          booked_start_time = case when a.actual_started_at is null
            then v_start else a.booked_start_time end,
          booked_end_time = case when a.actual_started_at is null
            then v_end else a.booked_end_time end,
          booked_start_at = case when a.actual_started_at is null
            then public.csp_start_at(p_appointment_date, v_start)
              at time zone 'Asia/Kuala_Lumpur'
            else a.booked_start_at end,
          booked_end_at = case when a.actual_started_at is null
            then public.csp_end_at(p_appointment_date, v_start, v_end)
              at time zone 'Asia/Kuala_Lumpur'
            else a.booked_end_at end,
          total_price = coalesce((v_allocation ->> 'total_price')::numeric, 0),
          type = coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
          service_name = coalesce(v_allocation ->> 'service_name', ''),
          service_items = coalesce(v_allocation -> 'service_items', '[]'::jsonb),
          item_count = greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
          notes = coalesce(v_allocation ->> 'notes', ''),
          updated_at = now(),
          updated_by = p_updated_by
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id
      returning a.id into v_saved_id;
    else
      insert into public.appointments (
        appointment_group_id, customer_id, therapist_id, room_id, service_id,
        appointment_date, start_time, end_time, start_at, end_at,
        booked_date, booked_start_time, booked_end_time,
        booked_start_at, booked_end_at,
        status, total_price, type, service_name, service_items, item_count,
        notes, created_at, created_by
      ) values (
        p_appointment_group_id, p_customer_id, v_therapist_id, v_room_id,
        v_service_id, p_appointment_date, v_start, v_end,
        public.csp_start_at(p_appointment_date, v_start),
        public.csp_end_at(p_appointment_date, v_start, v_end),
        p_appointment_date, v_start, v_end,
        public.csp_start_at(p_appointment_date, v_start)
          at time zone 'Asia/Kuala_Lumpur',
        public.csp_end_at(p_appointment_date, v_start, v_end)
          at time zone 'Asia/Kuala_Lumpur',
        'confirmed', coalesce((v_allocation ->> 'total_price')::numeric, 0),
        coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
        coalesce(v_allocation ->> 'service_name', ''),
        coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
        coalesce(v_allocation ->> 'notes', ''), now(), p_updated_by
      ) returning id into v_saved_id;
    end if;

    appointment_ids := array_append(appointment_ids, v_saved_id);
  end loop;

  if not v_group_paid then
    delete from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and not (a.id = any(appointment_ids));
  end if;

  return query select true, p_appointment_group_id, appointment_ids,
    null::text, null::text;
end;
$$;

create or replace function public.pay_appointment_addons(
  p_appointment_id uuid,
  p_addon_service_items jsonb,
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
  v_items jsonb;
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

  select * into v_appointment from public.appointments
  where id = p_appointment_id for update;

  if not found then
    return query select false, p_appointment_id, null::uuid,
      'NOT_FOUND', 'Appointment was not found.';
    return;
  end if;
  if v_appointment.payment_status <> 'paid' then
    return query select false, p_appointment_id, null::uuid,
      'NOT_PAID', 'The original appointment payment has not been recorded.';
    return;
  end if;
  if v_appointment.actual_started_at is not null
      or v_appointment.status not in ('pending', 'confirmed') then
    return query select false, p_appointment_id, null::uuid,
      'ALREADY_STARTED', 'Add-ons must be paid before the service starts.';
    return;
  end if;
  if jsonb_array_length(coalesce(p_addon_service_items, '[]'::jsonb)) = 0
      or coalesce(p_total_amount, 0) <= 0 then
    return query select false, p_appointment_id, null::uuid,
      'NO_ADDONS', 'No payable add-on services were supplied.';
    return;
  end if;

  if exists (
    select 1
    from public.transactions t
    cross join lateral jsonb_array_elements(coalesce(t.service_items, '[]'::jsonb)) paid
    join lateral jsonb_array_elements(p_addon_service_items) supplied on
      coalesce(paid ->> 'id', paid ->> 'serviceId', paid ->> 'service_id') =
      coalesce(supplied ->> 'id', supplied ->> 'serviceId', supplied ->> 'service_id')
    where t.appointment_id = p_appointment_id
      and t.source = 'appointment_addon'
      and t.payment_status = 'paid'
  ) then
    return query select false, p_appointment_id, null::uuid,
      'ALREADY_PAID', 'One or more add-on services have already been paid.';
    return;
  end if;

  select coalesce(jsonb_agg(
    item || jsonb_build_object('appointment_id', p_appointment_id)
  ), '[]'::jsonb) into v_items
  from jsonb_array_elements(p_addon_service_items) item;

  select * into v_customer from public.customers
  where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_appointment.room_id;

  v_first_item := v_items -> 0;
  v_service_id := nullif(coalesce(
    v_first_item ->> 'id', v_first_item ->> 'serviceId',
    v_first_item ->> 'service_id'
  ), '')::uuid;
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
    v_service_id, v_service_name, v_items, jsonb_array_length(v_items),
    v_appointment.therapist_id, v_therapist_name,
    p_counter_staff_id, p_counter_staff_name,
    v_appointment.room_id, v_room_name,
    p_service_price, p_sst_amount, p_total_amount,
    public.csp_commission_for_items(v_items, v_appointment.therapist_id, 'Therapist'),
    case when p_counter_staff_id is null then 0
      else public.csp_commission_for_items(v_items, p_counter_staff_id, 'Counter') end,
    'appointment_addon',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    'Appointment add-ons paid before check-in'
  ) returning id into v_transaction_id;

  return query select true, p_appointment_id, v_transaction_id,
    null::text, null::text;
end;
$$;

create or replace function public.pay_appointment_group_addons(
  p_appointment_group_id uuid,
  p_appointment_ids uuid[],
  p_addon_items_by_appointment jsonb,
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
  v_appointment public.appointments%rowtype;
  v_first public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_items jsonb;
  v_tagged_items jsonb;
  v_all_items jsonb := '[]'::jsonb;
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

  if p_appointment_ids is null or cardinality(p_appointment_ids) = 0
      or cardinality(p_appointment_ids) <> (
        select count(*)::integer from public.appointments a
        where a.appointment_group_id = p_appointment_group_id
      ) then
    return query select false, p_appointment_group_id, null::uuid,
      'INVALID_APPOINTMENTS', 'The complete appointment group is required.';
    return;
  end if;
  if coalesce(p_total_amount, 0) <= 0 or not exists (
    select 1 from jsonb_each(coalesce(p_addon_items_by_appointment, '{}'::jsonb)) item
    where jsonb_typeof(item.value) = 'array'
      and jsonb_array_length(item.value) > 0
  ) then
    return query select false, p_appointment_group_id, null::uuid,
      'NO_ADDONS', 'No payable add-on services were supplied.';
    return;
  end if;

  foreach v_id in array p_appointment_ids loop
    select * into v_appointment from public.appointments
    where id = v_id and appointment_group_id = p_appointment_group_id
    for update;
    if not found or v_appointment.payment_status <> 'paid' then
      return query select false, p_appointment_group_id, null::uuid,
        'NOT_PAID', 'Every group appointment must retain its original payment.';
      return;
    end if;
    if v_appointment.actual_started_at is not null
        or v_appointment.status not in ('pending', 'confirmed') then
      return query select false, p_appointment_group_id, null::uuid,
        'ALREADY_STARTED', 'Add-ons must be paid before the group service starts.';
      return;
    end if;
    if v_first.id is null then v_first := v_appointment; end if;

    v_items := coalesce(p_addon_items_by_appointment -> v_id::text, '[]'::jsonb);
    if jsonb_array_length(v_items) = 0 then continue; end if;

    if exists (
      select 1
      from public.transactions t
      cross join lateral jsonb_array_elements(coalesce(t.service_items, '[]'::jsonb)) paid
      join lateral jsonb_array_elements(v_items) supplied on
        coalesce(paid ->> 'id', paid ->> 'serviceId', paid ->> 'service_id') =
        coalesce(supplied ->> 'id', supplied ->> 'serviceId', supplied ->> 'service_id')
      where t.appointment_group_id = p_appointment_group_id
        and t.source = 'appointment_addon'
        and t.payment_status = 'paid'
        and coalesce(paid ->> 'appointmentId', paid ->> 'appointment_id') = v_id::text
    ) then
      return query select false, p_appointment_group_id, null::uuid,
        'ALREADY_PAID', 'One or more group add-on services have already been paid.';
      return;
    end if;

    select coalesce(jsonb_agg(
      item || jsonb_build_object('appointment_id', v_id)
    ), '[]'::jsonb) into v_tagged_items
    from jsonb_array_elements(v_items) item;
    v_all_items := v_all_items || v_tagged_items;
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_tagged_items, v_appointment.therapist_id, 'Therapist'
        );
  end loop;

  select * into v_customer from public.customers where id = v_first.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_first.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_first.room_id;
  v_first_item := v_all_items -> 0;
  v_service_id := nullif(coalesce(
    v_first_item ->> 'id', v_first_item ->> 'serviceId',
    v_first_item ->> 'service_id'
  ), '')::uuid;
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
    'Group appointment add-ons paid before check-in'
  ) returning id into v_transaction_id;

  return query select true, p_appointment_group_id, v_transaction_id,
    null::text, null::text;
end;
$$;

revoke all on function public.pay_appointment_addons(
  uuid, jsonb, uuid, text, numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.pay_appointment_addons(
  uuid, jsonb, uuid, text, numeric, numeric, numeric, text, text
) to authenticated;

revoke all on function public.pay_appointment_group_addons(
  uuid, uuid[], jsonb, uuid, text, numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.pay_appointment_group_addons(
  uuid, uuid[], jsonb, uuid, text, numeric, numeric, numeric, text, text
) to authenticated;

-- Guarded repair for the one group damaged by the former delete/recreate RPC.
do $$
declare
  v_group_id constant uuid := '3f254ed0-5be1-48a7-a580-f28ed087c7a0';
  v_pax_1 constant uuid := '2ffa797b-c3bd-4f0d-90b0-186773aeb270';
  v_pax_2 constant uuid := '54a1958c-2b02-40a5-86b2-ee2824517daa';
  v_foot constant uuid := 'f3e88593-11f1-462e-95cb-349d49a4a6e8';
  v_head constant uuid := '05243d05-75f4-4cd5-9686-46ac661b563a';
begin
  if (select count(*) from public.appointments a
      where a.appointment_group_id = v_group_id) = 2
    and exists (select 1 from public.appointments where id = v_pax_1)
    and exists (select 1 from public.appointments where id = v_pax_2)
    and exists (
      select 1 from public.transactions t
      where t.appointment_group_id = v_group_id
        and t.source = 'online_booking' and t.payment_status = 'paid'
    ) then

    update public.appointments a
    set service_id = v_foot,
        service_name = 'Foot Massage',
        service_items = (
          select coalesce(jsonb_agg(
            (item - 'lineType') || jsonb_build_object('lineType', 'booked')
          ), '[]'::jsonb)
          from jsonb_array_elements(a.service_items) item
          where coalesce(item ->> 'id', item ->> 'serviceId') = v_foot::text
        ),
        item_count = 1,
        total_price = 120,
        end_time = (start_time + interval '60 minutes')::time,
        end_at = public.csp_end_at(
          appointment_date, start_time,
          (start_time + interval '60 minutes')::time
        ),
        booked_end_time = (start_time + interval '60 minutes')::time,
        booked_end_at = public.csp_end_at(
          appointment_date, start_time,
          (start_time + interval '60 minutes')::time
        ) at time zone 'Asia/Kuala_Lumpur',
        payment_status = 'paid', updated_at = now()
    where a.id = v_pax_1;

    update public.appointments a
    set service_id = v_head,
        service_name = 'Head Massage, Foot Massage',
        service_items = (
          select coalesce(jsonb_agg(
            (item - 'lineType') || jsonb_build_object(
              'lineType', case
                when coalesce(item ->> 'id', item ->> 'serviceId') = v_head::text
                  then 'booked' else 'add_on' end
            ) order by ordinality
          ), '[]'::jsonb)
          from jsonb_array_elements(a.service_items) with ordinality items(item, ordinality)
          where coalesce(item ->> 'id', item ->> 'serviceId') in (
            v_head::text, v_foot::text
          )
        ),
        item_count = 2,
        total_price = 132,
        end_time = (start_time + interval '81 minutes')::time,
        end_at = public.csp_end_at(
          appointment_date, start_time,
          (start_time + interval '81 minutes')::time
        ),
        booked_end_time = (start_time + interval '81 minutes')::time,
        booked_end_at = public.csp_end_at(
          appointment_date, start_time,
          (start_time + interval '81 minutes')::time
        ) at time zone 'Asia/Kuala_Lumpur',
        payment_status = 'paid', updated_at = now()
    where a.id = v_pax_2;

    update public.transactions t
    set service_items = (
      select jsonb_agg(
        item || jsonb_build_object(
          'appointment_id', case
            when coalesce(item ->> 'service_id', item ->> 'id') = v_foot::text
              then v_pax_1 else v_pax_2 end
        ) order by ordinality
      )
      from jsonb_array_elements(t.service_items) with ordinality items(item, ordinality)
    ), updated_at = now()
    where t.appointment_group_id = v_group_id
      and t.source = 'online_booking' and t.payment_status = 'paid';

    update public.booking_holds
    set appointment_id = case guest_index when 1 then v_pax_1 else v_pax_2 end,
        updated_at = now()
    where appointment_group_id = v_group_id and guest_index in (1, 2);
  end if;
end;
$$;
