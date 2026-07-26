-- Phase 6B.1 business-flow correction: finalise payment and start atomically.
--
-- LOCAL ONLY. Not applied to staging. This is a pre-123 corrective migration;
-- it does not implement reserve/pay-later, online-hold conversion, or Cron.
--
-- The UI has one action, "Check In & Start Service". Its drawer submits all
-- customer, guest, service, therapist, room, numbered-room and payment choices
-- to the functions below. The functions lock, validate and commit those choices
-- together with the actual start. A retry after commit returns the existing
-- started result without another transaction or queue transition.

alter table public.appointments
  add column if not exists guest_name text not null default '',
  add column if not exists guest_phone text not null default '';

comment on column public.appointments.guest_name is
  'Per-pax display name used when the appointment is not represented by its own customer row.';
comment on column public.appointments.guest_phone is
  'Per-pax contact number used when the appointment is not represented by its own customer row.';

-- The historical numbered-room trigger used the scheduled clock even when the
-- UPDATE was the final start. At start, validate against NEW.start_at/end_at so
-- an early or late operational window cannot take an occupied numbered room.
create or replace function public.assign_appointment_room_unit()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare
  v_start timestamp;
  v_block_end timestamp;
  v_hold_id uuid;
begin
  if new.room_id is null then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;

  if (select allocation_mode from public.rooms where id = new.room_id)
       <> 'specific_room' then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;

  if new.actual_started_at is not null
     and lower(coalesce(new.status::text, '')) = 'in_progress' then
    v_start := new.actual_started_at at time zone 'Asia/Kuala_Lumpur';
    v_block_end := greatest(
      new.end_at,
      v_start + make_interval(mins => 1)
    ) + make_interval(
      mins => greatest(
        coalesce(new.buffer_after_minutes, 0),
        0
      )
    );
  else
    v_start := public.csp_start_at(new.appointment_date, new.start_time);
    v_block_end := public.csp_end_at(
      new.appointment_date,
      new.start_time,
      new.end_time
    ) + make_interval(
      mins => greatest(coalesce(new.buffer_after_minutes, 0), 0)
    );
  end if;

  if new.room_unit_id is null then
    select h.id, h.assigned_room_unit_id
    into v_hold_id, new.room_unit_id
    from public.booking_holds h
    where h.assigned_room_id = new.room_id
      and h.assigned_therapist_id = new.therapist_id
      and h.assigned_room_unit_id is not null
      and h.status not in ('expired', 'cancelled', 'failed')
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') = v_start
    order by h.updated_at desc nulls last, h.created_at desc
    limit 1;
  end if;

  new.room_unit_id := public.allocate_specific_room_unit(
    new.room_id,
    v_start,
    v_block_end,
    new.room_unit_id,
    new.id,
    v_hold_id
  );
  select u.name
  into new.room_unit_name
  from public.room_units u
  where u.id = new.room_unit_id;
  return new;
end;
$function$;

-- Owner-only core. Public wrappers own payment and group atomicity.
create or replace function public.finalize_and_start_appointment_core(
  p_appointment_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_guest_name text,
  p_guest_phone text,
  p_service_items jsonb,
  p_therapist_id uuid,
  p_assignment_source text,
  p_requested_gender text,
  p_room_id uuid,
  p_room_unit_id uuid,
  p_started_at timestamptz,
  p_expected_end_at timestamptz default null
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_a public.appointments%rowtype;
  v_result public.appointments%rowtype;
  v_source text;
  v_items jsonb;
  v_therapist uuid;
  v_requested_gender text;
  v_start_local timestamp;
  v_end_local timestamp;
  v_duration_minutes integer;
  v_check record;
  v_queue record;
  v_room_mode text;
  v_unit uuid;
begin
  select *
  into v_a
  from public.appointments a
  where a.id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Appointment was not found.';
  end if;

  if v_a.actual_started_at is not null then
    return v_a;
  end if;
  if v_a.status::text not in ('pending', 'confirmed') then
    raise exception using errcode = 'P0001',
      message = 'Only a pending or confirmed appointment can be started.';
  end if;
  if v_a.appointment_date
       <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = 'P0001',
      message = 'Service can only be started on its appointment date.';
  end if;
  if v_a.payment_status::text <> 'paid' then
    raise exception using errcode = 'P0001',
      message = 'Payment must be confirmed before starting this service.';
  end if;

  v_items := case
    when jsonb_typeof(p_service_items) = 'array'
         and jsonb_array_length(p_service_items) > 0
      then p_service_items
    else coalesce(v_a.service_items, '[]'::jsonb)
  end;
  v_source := lower(coalesce(nullif(trim(p_assignment_source), ''), 'queue'));
  if v_source not in (
    'queue',
    'gender_preference',
    'specific_customer_request',
    'manual_override'
  ) then
    raise exception using errcode = '22023',
      message = 'Invalid therapist assignment source.';
  end if;

  v_requested_gender := case
    when v_source = 'gender_preference'
      then nullif(trim(p_requested_gender), '')
    else null
  end;
  if v_source = 'gender_preference' and v_requested_gender is null then
    raise exception using errcode = '22023',
      message = 'Choose a gender for the therapist preference.';
  end if;
  if v_source in ('specific_customer_request', 'manual_override')
     and p_therapist_id is null then
    raise exception using errcode = '22023',
      message = 'Choose the requested therapist.';
  end if;

  v_duration_minutes := (
    select coalesce(
      sum(greatest(
        coalesce(
          nullif(item ->> 'duration', '')::integer,
          service.duration,
          0
        ),
        0
      )),
      0
    )::integer
    from jsonb_array_elements(v_items) item
    left join public.services service
      on service.id = nullif(
        coalesce(item ->> 'id', item ->> 'serviceId'),
        ''
      )::uuid
  );
  if v_duration_minutes <= 0 then
    v_duration_minutes := greatest(
      ceil(extract(epoch from (
        coalesce(
          v_a.booked_end_at,
          public.csp_end_at(
            coalesce(v_a.booked_date, v_a.appointment_date),
            coalesce(v_a.booked_start_time, v_a.start_time),
            coalesce(v_a.booked_end_time, v_a.end_time)
          ) at time zone 'Asia/Kuala_Lumpur'
        )
        - coalesce(
          v_a.booked_start_at,
          public.csp_start_at(
            coalesce(v_a.booked_date, v_a.appointment_date),
            coalesce(v_a.booked_start_time, v_a.start_time)
          ) at time zone 'Asia/Kuala_Lumpur'
        )
      )) / 60.0)::integer,
      1
    );
  end if;

  v_start_local := p_started_at at time zone 'Asia/Kuala_Lumpur';
  v_end_local := coalesce(
    p_expected_end_at at time zone 'Asia/Kuala_Lumpur',
    v_start_local + make_interval(mins => v_duration_minutes)
  );
  if v_end_local <= v_start_local then
    raise exception using errcode = '22023',
      message = 'Expected end time must be after the actual start time.';
  end if;

  v_therapist := p_therapist_id;
  if v_therapist is null then
    for v_queue in
      select q.*
      from public.get_therapist_queue(
        v_a.outlet_id,
        v_start_local::date,
        v_start_local::time,
        v_duration_minutes
      ) q
      where v_requested_gender is null
         or lower(q.gender) = lower(v_requested_gender)
      order by q.rotation_rank
    loop
      select *
      into v_check
      from public.check_booking_availability(
        v_start_local::date,
        v_start_local::time,
        v_end_local::time,
        v_queue.therapist_id,
        p_room_id,
        p_appointment_id
      );
      if coalesce(v_check.therapist_available, false) then
        v_therapist := v_queue.therapist_id;
        exit;
      end if;
    end loop;
  end if;

  if v_therapist is null then
    raise exception using errcode = 'P0001',
      message = 'No eligible therapist is available to start this service.';
  end if;
  if not exists (
    select 1
    from public.therapists t
    where t.id = v_therapist
      and t.outlet_id = v_a.outlet_id
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
  ) then
    raise exception using errcode = 'P0001',
      message = 'The selected therapist is not active in this outlet.';
  end if;

  if p_room_id is null then
    raise exception using errcode = '22023',
      message = 'Choose a room or shared-capacity zone.';
  end if;
  select r.allocation_mode
  into v_room_mode
  from public.rooms r
  join public.services s on s.id = v_a.service_id
  where r.id = p_room_id
    and r.outlet_id = v_a.outlet_id
    and coalesce(r.is_active, true)
    and lower(coalesce(r.room_type::text, ''))
        = lower(coalesce(s.room_type::text, ''));
  if not found then
    raise exception using errcode = 'P0001',
      message = 'The selected room does not support this service.';
  end if;

  select *
  into v_check
  from public.check_booking_availability(
    v_start_local::date,
    v_start_local::time,
    v_end_local::time,
    v_therapist,
    p_room_id,
    p_appointment_id
  );
  if not coalesce(v_check.therapist_available, false) then
    raise exception using errcode = 'P0001',
      message = 'The selected therapist is no longer available.';
  end if;
  if coalesce(v_check.room_full, true) then
    raise exception using errcode = 'P0001',
      message = 'The selected room or zone is no longer available.';
  end if;

  if coalesce(v_room_mode, 'capacity') = 'specific_room' then
    v_unit := public.allocate_specific_room_unit(
      p_room_id,
      v_start_local,
      v_end_local + make_interval(
        mins => greatest(coalesce(v_a.buffer_after_minutes, 0), 0)
      ),
      p_room_unit_id,
      p_appointment_id,
      null
    );
  else
    v_unit := null;
  end if;

  if v_a.customer_id is not null then
    update public.customers c
    set name = coalesce(nullif(trim(p_customer_name), ''), c.name),
        phone = coalesce(nullif(trim(p_customer_phone), ''), c.phone)
    where c.id = v_a.customer_id;
  end if;

  perform set_config('app.therapist_switch_rpc', '1', true);
  update public.appointments a
  set guest_name = coalesce(
        nullif(trim(p_guest_name), ''),
        nullif(trim(p_customer_name), ''),
        a.guest_name
      ),
      guest_phone = coalesce(
        nullif(trim(p_guest_phone), ''),
        nullif(trim(p_customer_phone), ''),
        a.guest_phone
      ),
      service_items = v_items,
      item_count = greatest(jsonb_array_length(v_items), 1),
      therapist_id = v_therapist,
      requested_therapist_id = case
        when v_source = 'specific_customer_request' then v_therapist
        else null
      end,
      requested_gender = v_requested_gender,
      assignment_source = v_source,
      room_id = p_room_id,
      room_unit_id = v_unit,
      therapist_assignment_state = 'confirmed',
      room_assignment_state = 'confirmed',
      resources_confirmed_at = p_started_at,
      resources_confirmed_by = auth.uid(),
      booked_date = coalesce(booked_date, appointment_date),
      booked_start_time = coalesce(booked_start_time, start_time),
      booked_end_time = coalesce(booked_end_time, end_time),
      booked_start_at = coalesce(
        booked_start_at,
        public.csp_start_at(appointment_date, start_time)
          at time zone 'Asia/Kuala_Lumpur'
      ),
      booked_end_at = coalesce(
        booked_end_at,
        public.csp_end_at(appointment_date, start_time, end_time)
          at time zone 'Asia/Kuala_Lumpur'
      ),
      checked_in_at = p_started_at,
      checked_in_by = auth.uid(),
      actual_started_at = p_started_at,
      status = 'in_progress',
      start_at = v_start_local,
      end_at = v_end_local,
      assignment_last_attempted_at = now(),
      assignment_error_code = null,
      assignment_error_message = null,
      updated_at = now()
  where a.id = p_appointment_id
  returning * into v_result;

  return v_result;
end;
$function$;

revoke all on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

create or replace function public.finalize_and_start_appointment(
  p_appointment_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_guest_name text default '',
  p_guest_phone text default '',
  p_service_items jsonb default '[]'::jsonb,
  p_payment_items jsonb default '[]'::jsonb,
  p_therapist_id uuid default null,
  p_assignment_source text default 'queue',
  p_requested_gender text default null,
  p_room_id uuid default null,
  p_room_unit_id uuid default null,
  p_started_at timestamptz default now(),
  p_expected_end_at timestamptz default null,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default ''
)
returns table(
  success boolean,
  appointment_id uuid,
  transaction_id uuid,
  actual_started_at timestamptz,
  expected_end_at timestamp,
  therapist_id uuid,
  room_id uuid,
  room_unit_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_before public.appointments%rowtype;
  v_after public.appointments%rowtype;
  v_txn uuid;
  v_need_payment boolean;
  v_has_primary boolean;
  v_source text;
  v_tx_items jsonb;
  v_therapist_name text;
  v_room_name text;
  v_service_name text;
  v_detail text;
  v_state text;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select *
  into v_before
  from public.appointments a
  where a.id = p_appointment_id
  for update;
  if not found then
    return query select false, p_appointment_id, null::uuid, null::timestamptz,
      null::timestamp, null::uuid, null::uuid, null::uuid,
      'NOT_FOUND', 'Appointment was not found.';
    return;
  end if;

  if v_before.actual_started_at is not null then
    select t.id
    into v_txn
    from public.transactions t
    where t.appointment_id = p_appointment_id
    order by t.created_at desc
    limit 1;
    return query select true, v_before.id, v_txn, v_before.actual_started_at,
      v_before.end_at, v_before.therapist_id, v_before.room_id,
      v_before.room_unit_id, null::text, null::text;
    return;
  end if;

  begin
    v_need_payment := coalesce(p_total_amount, 0) > 0.005
      and jsonb_typeof(coalesce(p_payment_items, '[]'::jsonb)) = 'array'
      and jsonb_array_length(coalesce(p_payment_items, '[]'::jsonb)) > 0;
    select exists (
      select 1
      from public.transactions t
      where t.appointment_id = p_appointment_id
        and t.payment_status = 'paid'
        and coalesce(t.source, '') <> 'appointment_addon'
    ) into v_has_primary;

    if v_need_payment then
      update public.appointments a
      set payment_status = 'paid', updated_at = now()
      where a.id = p_appointment_id;
    elsif v_before.payment_status::text <> 'paid' then
      raise exception using errcode = 'P0001',
        message = 'Payment is required before starting this service.';
    end if;

    select *
    into v_after
    from public.finalize_and_start_appointment_core(
      p_appointment_id,
      p_customer_name,
      p_customer_phone,
      p_guest_name,
      p_guest_phone,
      p_service_items,
      p_therapist_id,
      p_assignment_source,
      p_requested_gender,
      p_room_id,
      p_room_unit_id,
      p_started_at,
      p_expected_end_at
    );

    if v_need_payment then
      v_source := case when v_has_primary
        then 'appointment_addon' else 'appointment' end;
      v_tx_items := case when v_has_primary
        then p_payment_items else v_after.service_items end;
      select t.name into v_therapist_name
      from public.therapists t where t.id = v_after.therapist_id;
      select r.name into v_room_name
      from public.rooms r where r.id = v_after.room_id;
      v_service_name := coalesce(
        nullif(v_tx_items -> 0 ->> 'name', ''),
        v_after.service_name,
        'Service'
      );

      insert into public.transactions (
        outlet_id, appointment_id, customer_id, customer_name, customer_phone,
        service_id, service_name, service_items, item_count,
        therapist_id, therapist_name, counter_staff_id, counter_staff_name,
        room_id, room_name, service_price, sst_amount, total_amount,
        therapist_commission_amount, counter_commission_amount,
        source, payment_method, payment_status, receipt_number, notes
      ) values (
        v_after.outlet_id, v_after.id, v_after.customer_id,
        coalesce(nullif(trim(p_guest_name), ''), p_customer_name, ''),
        coalesce(nullif(trim(p_guest_phone), ''), p_customer_phone, ''),
        v_after.service_id, v_service_name, v_tx_items,
        greatest(jsonb_array_length(v_tx_items), 1),
        v_after.therapist_id, coalesce(v_therapist_name, ''),
        p_counter_staff_id, p_counter_staff_name,
        v_after.room_id, coalesce(v_room_name, ''),
        coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
        coalesce(p_total_amount, 0),
        public.csp_commission_for_items(
          v_tx_items, v_after.therapist_id, 'Therapist'
        ),
        case when p_counter_staff_id is null then 0
          else public.csp_commission_for_items(
            v_tx_items, p_counter_staff_id, 'Counter'
          )
        end,
        v_source,
        coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
        'paid'::public.payment_status,
        p_receipt_number,
        'Finalised at service start'
      )
      returning id into v_txn;
    else
      select t.id
      into v_txn
      from public.transactions t
      where t.appointment_id = p_appointment_id
      order by t.created_at desc
      limit 1;
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, p_appointment_id, null::uuid, null::timestamptz,
      null::timestamp, null::uuid, null::uuid, null::uuid,
      coalesce(v_state, 'FINALIZE_FAILED'), coalesce(v_detail, 'Unable to start service.');
    return;
  end;

  return query select true, v_after.id, v_txn, v_after.actual_started_at,
    v_after.end_at, v_after.therapist_id, v_after.room_id,
    v_after.room_unit_id, null::text, null::text;
end;
$function$;

create or replace function public.finalize_and_start_appointment_group(
  p_appointment_group_id uuid,
  p_appointment_ids uuid[],
  p_customer_name text,
  p_customer_phone text,
  p_pax_updates jsonb default '{}'::jsonb,
  p_payment_items jsonb default '[]'::jsonb,
  p_started_at timestamptz default now(),
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default ''
)
returns table(
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  transaction_id uuid,
  actual_started_at timestamptz,
  started_count integer,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_group public.appointment_groups%rowtype;
  v_before public.appointments%rowtype;
  v_after public.appointments%rowtype;
  v_id uuid;
  v_update jsonb;
  v_ids uuid[] := array[]::uuid[];
  v_txn uuid;
  v_count integer := 0;
  v_started integer := 0;
  v_already_started integer := 0;
  v_need_payment boolean;
  v_has_primary boolean;
  v_source text;
  v_first public.appointments%rowtype;
  v_all_items jsonb := '[]'::jsonb;
  v_therapist_commission numeric := 0;
  v_therapist_name text;
  v_room_name text;
  v_detail text;
  v_state text;
  v_existing_started_at timestamptz;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select *
  into v_group
  from public.appointment_groups g
  where g.id = p_appointment_group_id
  for update;
  if not found then
    return query select false, p_appointment_group_id, v_ids, null::uuid,
      null::timestamptz, 0, 'NOT_FOUND', 'Group was not found.';
    return;
  end if;

  select count(*), count(*) filter (where a.actual_started_at is not null)
  into v_count, v_already_started
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id
    and a.id = any(p_appointment_ids);
  if v_count = 0 or v_count <> cardinality(p_appointment_ids)
     or v_count <> (
       select count(*) from public.appointments a
       where a.appointment_group_id = p_appointment_group_id
     ) then
    return query select false, p_appointment_group_id, v_ids, null::uuid,
      null::timestamptz, 0, 'INVALID_APPOINTMENTS',
      'The complete group appointment list is required.';
    return;
  end if;
  if v_already_started > 0 and v_already_started < v_count then
    return query select false, p_appointment_group_id, p_appointment_ids,
      null::uuid, null::timestamptz, 0, 'PARTIAL_START',
      'The group is already partially started and requires review.';
    return;
  end if;
  if v_already_started = v_count then
    select t.id into v_txn
    from public.transactions t
    where t.appointment_group_id = p_appointment_group_id
    order by t.created_at desc limit 1;
    select min(a.actual_started_at) into v_existing_started_at
    from public.appointments a
    where a.appointment_group_id = p_appointment_group_id;
    return query select true, p_appointment_group_id, p_appointment_ids,
      v_txn, v_existing_started_at, 0, null::text, null::text;
    return;
  end if;

  begin
    v_need_payment := coalesce(p_total_amount, 0) > 0.005
      and jsonb_typeof(coalesce(p_payment_items, '[]'::jsonb)) = 'array'
      and jsonb_array_length(coalesce(p_payment_items, '[]'::jsonb)) > 0;
    select exists (
      select 1 from public.transactions t
      where (
          t.appointment_group_id = p_appointment_group_id
          or t.appointment_id = any(p_appointment_ids)
        )
        and t.payment_status = 'paid'
        and coalesce(t.source, '') <> 'appointment_addon'
    ) into v_has_primary;

    if v_group.customer_id is not null then
      update public.customers c
      set name = coalesce(nullif(trim(p_customer_name), ''), c.name),
          phone = coalesce(nullif(trim(p_customer_phone), ''), c.phone)
      where c.id = v_group.customer_id;
    end if;
    update public.appointment_groups g
    set group_name = coalesce(nullif(trim(p_customer_name), ''), g.group_name),
        status = 'in_progress'
    where g.id = p_appointment_group_id;

    for v_id in
      select a.id
      from public.appointments a
      where a.appointment_group_id = p_appointment_group_id
      order by a.id
    loop
      select * into v_before
      from public.appointments a where a.id = v_id for update;
      v_ids := array_append(v_ids, v_id);
      v_update := coalesce(p_pax_updates -> v_id::text, '{}'::jsonb);
      if v_update = '{}'::jsonb then
        raise exception 'Final details are missing for one guest.';
      end if;

      if v_need_payment then
        update public.appointments a
        set payment_status = 'paid', updated_at = now()
        where a.id = v_id;
      elsif v_before.payment_status::text <> 'paid' then
        raise exception 'Payment is required for every guest before starting.';
      end if;

      select *
      into v_after
      from public.finalize_and_start_appointment_core(
        v_id,
        p_customer_name,
        p_customer_phone,
        coalesce(v_update ->> 'guest_name', p_customer_name),
        coalesce(v_update ->> 'guest_phone', p_customer_phone),
        coalesce(v_update -> 'service_items', v_before.service_items),
        nullif(v_update ->> 'therapist_id', '')::uuid,
        coalesce(v_update ->> 'assignment_source', 'queue'),
        nullif(v_update ->> 'requested_gender', ''),
        nullif(v_update ->> 'room_id', '')::uuid,
        nullif(v_update ->> 'room_unit_id', '')::uuid,
        p_started_at,
        nullif(v_update ->> 'expected_end_at', '')::timestamptz
      );
      v_started := v_started + 1;
      v_all_items := v_all_items || coalesce(v_after.service_items, '[]'::jsonb);
      v_therapist_commission := v_therapist_commission
        + public.csp_commission_for_items(
            v_after.service_items, v_after.therapist_id, 'Therapist'
          );
      if v_first.id is null then v_first := v_after; end if;
    end loop;

    if v_need_payment then
      v_source := case when v_has_primary
        then 'appointment_addon' else 'appointment' end;
      select t.name into v_therapist_name
      from public.therapists t where t.id = v_first.therapist_id;
      select r.name into v_room_name
      from public.rooms r where r.id = v_first.room_id;
      insert into public.transactions (
        outlet_id, appointment_group_id, customer_id,
        customer_name, customer_phone,
        service_id, service_name, service_items, item_count,
        therapist_id, therapist_name, counter_staff_id, counter_staff_name,
        room_id, room_name, service_price, sst_amount, total_amount,
        therapist_commission_amount, counter_commission_amount,
        source, payment_method, payment_status, receipt_number, notes
      ) values (
        v_first.outlet_id, p_appointment_group_id, v_group.customer_id,
        coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
        v_first.service_id, coalesce(v_first.service_name, 'Service'),
        case when v_has_primary then p_payment_items else v_all_items end,
        greatest(jsonb_array_length(
          case when v_has_primary then p_payment_items else v_all_items end
        ), 1),
        v_first.therapist_id, coalesce(v_therapist_name, ''),
        p_counter_staff_id, p_counter_staff_name,
        v_first.room_id, coalesce(v_room_name, ''),
        coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
        coalesce(p_total_amount, 0),
        v_therapist_commission,
        case when p_counter_staff_id is null then 0
          else public.csp_commission_for_items(
            case when v_has_primary then p_payment_items else v_all_items end,
            p_counter_staff_id,
            'Counter'
          )
        end,
        v_source,
        coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
        'paid'::public.payment_status,
        p_receipt_number,
        'Group finalised at service start'
      )
      returning id into v_txn;
    else
      select t.id into v_txn
      from public.transactions t
      where t.appointment_group_id = p_appointment_group_id
      order by t.created_at desc limit 1;
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, p_appointment_group_id, p_appointment_ids,
      null::uuid, null::timestamptz, 0,
      coalesce(v_state, 'FINALIZE_FAILED'),
      coalesce(v_detail, 'Unable to start group service.');
    return;
  end;

  return query select true, p_appointment_group_id, v_ids, v_txn,
    p_started_at, v_started, null::text, null::text;
end;
$function$;

revoke all on function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;

revoke all on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;

-- Staff walk-in adapters keep creation, payment and the final resource/start
-- transition in one database transaction. The established creation functions
-- are deliberately called with p_start_immediately = false; only the hardened
-- finalizer is allowed to write the operational start.
create or replace function public.create_staff_walkin_and_start_with_payment(
  p_customer_id uuid,
  p_therapist_id uuid,
  p_room_id uuid,
  p_room_unit_id uuid,
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
  p_draft_session_id text default null,
  p_assignment_source text default 'queue',
  p_requested_therapist_id uuid default null,
  p_requested_gender text default null,
  p_started_at timestamptz default now()
)
returns table (
  success boolean,
  appointment_id uuid,
  transaction_id uuid,
  actual_started_at timestamptz,
  expected_end_at timestamp,
  therapist_id uuid,
  room_id uuid,
  room_unit_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_created record;
  v_started record;
  v_detail text;
  v_state text;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  begin
    select *
    into v_created
    from public.create_staff_walkin_with_payment(
      p_customer_id => p_customer_id,
      p_therapist_id => p_therapist_id,
      p_room_id => p_room_id,
      p_service_id => p_service_id,
      p_date => p_date,
      p_start_time => p_start_time,
      p_end_time => p_end_time,
      p_service_price => p_service_price,
      p_service_name => p_service_name,
      p_service_items => p_service_items,
      p_item_count => p_item_count,
      p_notes => p_notes,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_sst_amount => p_sst_amount,
      p_total_amount => p_total_amount,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number,
      p_transaction_notes => p_transaction_notes,
      p_start_immediately => false,
      p_draft_session_id => p_draft_session_id,
      p_assignment_source => p_assignment_source,
      p_requested_therapist_id => p_requested_therapist_id,
      p_requested_gender => p_requested_gender
    );
    if not coalesce(v_created.success, false) then
      return query select false, null::uuid, null::uuid, null::timestamptz,
        null::timestamp, null::uuid, null::uuid, null::uuid,
        v_created.error_code, v_created.error_message;
      return;
    end if;

    -- The transaction inserted immediately above is the payment evidence.
    update public.appointments a
    set payment_status = 'paid',
        room_unit_id = p_room_unit_id,
        updated_at = now()
    where a.id = v_created.appointment_id;

    select *
    into v_started
    from public.finalize_and_start_appointment(
      p_appointment_id => v_created.appointment_id,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_guest_name => p_customer_name,
      p_guest_phone => p_customer_phone,
      p_service_items => p_service_items,
      p_payment_items => '[]'::jsonb,
      p_therapist_id => p_therapist_id,
      p_assignment_source => p_assignment_source,
      p_requested_gender => p_requested_gender,
      p_room_id => p_room_id,
      p_room_unit_id => p_room_unit_id,
      p_started_at => p_started_at,
      p_expected_end_at => null,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_service_price => 0,
      p_sst_amount => 0,
      p_total_amount => 0,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number
    );
    if not coalesce(v_started.success, false) then
      raise exception using errcode = 'P0001',
        message = coalesce(v_started.error_message, 'Unable to start service.');
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, null::uuid, null::uuid, null::timestamptz,
      null::timestamp, null::uuid, null::uuid, null::uuid,
      coalesce(v_state, 'WALKIN_START_FAILED'),
      coalesce(v_detail, 'Unable to create and start walk-in service.');
    return;
  end;

  return query select true, v_started.appointment_id,
    v_created.transaction_id, v_started.actual_started_at,
    v_started.expected_end_at, v_started.therapist_id, v_started.room_id,
    v_started.room_unit_id, null::text, null::text;
end;
$function$;

revoke all on function public.create_staff_walkin_and_start_with_payment(
  uuid, uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb,
  integer, text, text, text, uuid, text, numeric, numeric, text, text, text,
  text, text, uuid, text, timestamptz
) from public, anon;
grant execute on function public.create_staff_walkin_and_start_with_payment(
  uuid, uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb,
  integer, text, text, text, uuid, text, numeric, numeric, text, text, text,
  text, text, uuid, text, timestamptz
) to authenticated;

create or replace function public.create_staff_walkin_group_and_start_with_payment(
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
  p_draft_session_id text default null,
  p_started_at timestamptz default now()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  transaction_id uuid,
  actual_started_at timestamptz,
  started_count integer,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_created record;
  v_started record;
  v_alloc jsonb;
  v_id uuid;
  v_index integer := 0;
  v_updates jsonb := '{}'::jsonb;
  v_detail text;
  v_state text;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  begin
    select *
    into v_created
    from public.create_staff_walkin_group_with_payment(
      p_customer_id => p_customer_id,
      p_group_name => p_group_name,
      p_pax_count => p_pax_count,
      p_appointment_date => p_appointment_date,
      p_allocations => p_allocations,
      p_notes => p_notes,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_service_price => p_service_price,
      p_sst_amount => p_sst_amount,
      p_total_amount => p_total_amount,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number,
      p_transaction_notes => p_transaction_notes,
      p_start_immediately => false,
      p_draft_session_id => p_draft_session_id
    );
    if not coalesce(v_created.success, false) then
      return query select false, null::uuid, array[]::uuid[], null::uuid,
        null::timestamptz, 0, v_created.error_code, v_created.error_message;
      return;
    end if;

    if cardinality(v_created.appointment_ids)
         <> jsonb_array_length(p_allocations) then
      raise exception 'Created appointment count does not match the walk-in group.';
    end if;

    foreach v_id in array v_created.appointment_ids loop
      v_alloc := p_allocations -> v_index;
      v_updates := v_updates || jsonb_build_object(
        v_id::text,
        jsonb_build_object(
          'guest_name', coalesce(
            nullif(v_alloc ->> 'guest_name', ''),
            format('Guest %s', v_index + 1)
          ),
          'guest_phone', coalesce(v_alloc ->> 'guest_phone', ''),
          'service_items', coalesce(v_alloc -> 'service_items', '[]'::jsonb),
          'therapist_id', v_alloc ->> 'therapist_id',
          'assignment_source', coalesce(
            nullif(v_alloc ->> 'assignment_source', ''),
            'queue'
          ),
          'requested_gender', v_alloc ->> 'requested_gender',
          'room_id', v_alloc ->> 'room_id',
          'room_unit_id', v_alloc ->> 'room_unit_id'
        )
      );
      v_index := v_index + 1;
    end loop;

    update public.appointments a
    set payment_status = 'paid', updated_at = now()
    where a.id = any(v_created.appointment_ids);

    select *
    into v_started
    from public.finalize_and_start_appointment_group(
      p_appointment_group_id => v_created.appointment_group_id,
      p_appointment_ids => v_created.appointment_ids,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_pax_updates => v_updates,
      p_payment_items => '[]'::jsonb,
      p_started_at => p_started_at,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_service_price => 0,
      p_sst_amount => 0,
      p_total_amount => 0,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number
    );
    if not coalesce(v_started.success, false) then
      raise exception using errcode = 'P0001',
        message = coalesce(
          v_started.error_message,
          'Unable to start every guest in the group.'
        );
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, null::uuid, array[]::uuid[], null::uuid,
      null::timestamptz, 0,
      coalesce(v_state, 'WALKIN_GROUP_START_FAILED'),
      coalesce(v_detail, 'Unable to create and start walk-in group.');
    return;
  end;

  return query select true, v_started.appointment_group_id,
    v_started.appointment_ids, v_created.transaction_id,
    v_started.actual_started_at, v_started.started_count,
    null::text, null::text;
end;
$function$;

revoke all on function public.create_staff_walkin_group_and_start_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text,
  numeric, numeric, numeric, text, text, text, text, timestamptz
) from public, anon;
grant execute on function public.create_staff_walkin_group_and_start_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text,
  numeric, numeric, numeric, text, text, text, text, timestamptz
) to authenticated;
