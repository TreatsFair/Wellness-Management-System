-- Consume the live therapist queue from the authoritative service-start
-- boundary. Immediate paid walk-ins are inserted with actual_started_at
-- already populated, while appointment check-in sets it later. Both paths
-- must rotate only the therapist who actually starts the service.

begin;

create or replace function public.consume_therapist_queue_turn_for_start(
  p_outlet_id uuid,
  p_queue_date date,
  p_therapist_id uuid,
  p_started_at timestamptz,
  p_appointment_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_this_position integer;
  v_last_consumed_at timestamptz;
  v_assignment_source text := 'queue';
  v_front_therapist_id uuid;
begin
  if p_outlet_id is null
     or p_queue_date is null
     or p_therapist_id is null
     or p_started_at is null then
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_queue_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_queue_date);

  select queue_row.queue_position, queue_row.turn_consumed_at
  into v_this_position, v_last_consumed_at
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_queue_date
    and queue_row.therapist_id = p_therapist_id
  for update;

  if v_this_position is null
     or (
       v_last_consumed_at is not null
       and p_started_at <= v_last_consumed_at
     ) then
    return;
  end if;

  if p_appointment_id is not null then
    select coalesce(nullif(appointment.assignment_source, ''), 'queue')
    into v_assignment_source
    from public.appointments appointment
    where appointment.id = p_appointment_id;
  end if;

  -- A customer request only uses the therapist's normal turn when that
  -- therapist is already at the effective front of the live rotation. An
  -- out-of-turn request leaves queue_position and any protected turn intact.
  if v_assignment_source = 'specific_customer_request' then
    select queue_row.therapist_id
    into v_front_therapist_id
    from public.therapist_queue queue_row
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_queue_date
    order by
      queue_row.protected_turn_owed desc,
      queue_row.queue_position,
      queue_row.therapist_id
    limit 1;

    if v_front_therapist_id is distinct from p_therapist_id then
      return;
    end if;
  end if;

  -- A therapist ahead of the selected therapist is skipped only for this
  -- assignment. Their persisted queue_position is untouched. A protected
  -- turn is retained only when their current service was customer-requested.
  update public.therapist_queue queue_row
  set protected_turn_owed = true,
      protected_turn_reason = 'busy_specific_request'
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_queue_date
    and queue_row.queue_position < v_this_position
    and exists (
      select 1
      from public.appointments busy
      where busy.therapist_id = queue_row.therapist_id
        and busy.outlet_id = p_outlet_id
        and busy.appointment_date = p_queue_date
        and busy.status::text = 'in_progress'
        and busy.assignment_source = 'specific_customer_request'
        and busy.id is distinct from p_appointment_id
    );

  -- Migration 107's queue-row trigger performs the actual move to the bottom
  -- and records therapist_queue_day.first_turn_consumed_at atomically.
  update public.therapist_queue
  set turn_consumed_at = p_started_at,
      protected_turn_owed = false,
      protected_turn_reason = null
  where outlet_id = p_outlet_id
    and queue_date = p_queue_date
    and therapist_id = p_therapist_id;
end;
$$;

revoke all on function public.consume_therapist_queue_turn_for_start(
  uuid, date, uuid, timestamptz, uuid
) from public, anon, authenticated;

create or replace function public.consume_queue_on_appointment_start()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.actual_started_at is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.actual_started_at is not null then
    return new;
  end if;

  if lower(coalesce(new.status::text, '')) in (
       'cancelled', 'canceled', 'no_show', 'no-show', 'noshow'
     )
     or lower(coalesce(new.payment_status::text, '')) = 'voided' then
    return new;
  end if;

  perform public.consume_therapist_queue_turn_for_start(
    new.outlet_id,
    new.appointment_date,
    new.therapist_id,
    new.actual_started_at,
    new.id
  );

  return new;
end;
$$;

revoke all on function public.consume_queue_on_appointment_start()
  from public, anon, authenticated;

drop trigger if exists appointment_actual_start_consumes_queue
  on public.appointments;
create trigger appointment_actual_start_consumes_queue
after insert or update of actual_started_at on public.appointments
for each row execute function public.consume_queue_on_appointment_start();

-- Keep the public RPC contract unchanged. Queue consumption is no longer
-- duplicated here; the actual_started_at trigger above is the single source
-- for appointment check-in and immediate walk-in starts.
create or replace function public.start_appointment_service(
  p_appointment_id uuid,
  p_started_at timestamptz default now(),
  p_expected_end_at timestamptz default null,
  p_allow_late_extension_overlap boolean default false
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_duration interval;
  v_expected_end timestamptz;
  v_updated public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  if v_appointment.appointment_date <>
      (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service can only be started on its appointment date.';
  end if;
  if v_appointment.status not in ('pending', 'confirmed') then
    raise exception 'Only a pending or confirmed service can be started.';
  end if;
  if v_appointment.payment_status <> 'paid' then
    raise exception 'Payment must be confirmed before starting this service.';
  end if;
  if v_appointment.actual_started_at is not null then
    raise exception 'This service has already started.';
  end if;

  v_duration := coalesce(
    v_appointment.booked_end_at - v_appointment.booked_start_at,
    public.csp_end_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time),
      coalesce(v_appointment.booked_end_time, v_appointment.end_time)
    ) - public.csp_start_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time)
    ),
    v_appointment.end_at - v_appointment.start_at
  );
  if v_duration is null or v_duration <= interval '0 seconds' then
    raise exception 'Service duration must be greater than zero.';
  end if;

  v_expected_end := coalesce(p_expected_end_at, p_started_at + v_duration);
  if v_expected_end <= p_started_at then
    raise exception 'Expected end time must be after the actual start time.';
  end if;
  perform set_config(
    'app.allow_late_extension_overlap',
    case when p_allow_late_extension_overlap then 'on' else 'off' end,
    true
  );

  update public.appointments
  set booked_date = coalesce(booked_date, appointment_date),
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
      status = 'in_progress',
      actual_started_at = p_started_at,
      end_at = v_expected_end at time zone 'Asia/Kuala_Lumpur',
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  return v_updated;
end;
$$;

revoke all on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) from public, anon;
grant execute on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) to authenticated;

-- Single-pax staff walk-ins must persist assignment provenance before an
-- immediate actual_started_at write. Appending optional parameters preserves
-- the existing positional and named-call contract for already deployed clients.
drop function if exists public.create_staff_walkin_with_payment(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer,
  text, text, text, uuid, text, numeric, numeric, text, text, text, boolean,
  text, uuid
);

create or replace function public.create_staff_walkin_with_payment(
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
  p_start_immediately boolean default true,
  p_draft_session_id text default null,
  p_created_by uuid default auth.uid(),
  p_assignment_source text default 'queue',
  p_requested_therapist_id uuid default null,
  p_requested_gender text default null
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
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_therapist_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('room:' || p_room_id::text, 0));

  if p_draft_session_id is not null then
    update public.booking_holds
    set status = 'cancelled', updated_at = now()
    where hold_kind = 'staff_walkin_draft'
      and draft_session_id = p_draft_session_id
      and status = 'pending_payment';
  end if;

  perform set_config('app.ignore_cleanup_buffer', 'on', true);
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  select * into v_create
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
    p_notes => p_notes,
    p_assignment_source => coalesce(
      nullif(p_assignment_source, ''),
      'queue'
    ),
    p_requested_therapist_id => p_requested_therapist_id,
    p_requested_gender => p_requested_gender,
    p_is_provisional => false
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

  if p_start_immediately then
    update public.appointments appointment
    set status = 'in_progress',
        actual_started_at = now(),
        updated_at = now()
    where appointment.id = v_create.appointment_id
    returning appointment.outlet_id into v_outlet_id;
  else
    select appointment.outlet_id
    into v_outlet_id
    from public.appointments appointment
    where appointment.id = v_create.appointment_id;
  end if;

  select therapist.name into v_therapist_name
  from public.therapists therapist
  where therapist.id = p_therapist_id;

  select room.name into v_room_name
  from public.rooms room
  where room.id = p_room_id;

  v_therapist_commission := public.csp_commission_for_items(
    p_service_items,
    p_therapist_id,
    'Therapist'
  );
  v_counter_commission := case
    when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(
      p_service_items,
      p_counter_staff_id,
      'Counter'
    )
  end;

  insert into public.transactions (
    outlet_id,
    appointment_id,
    customer_id,
    customer_name,
    customer_phone,
    service_id,
    service_name,
    service_items,
    item_count,
    therapist_id,
    therapist_name,
    counter_staff_id,
    counter_staff_name,
    room_id,
    room_name,
    service_price,
    sst_amount,
    total_amount,
    therapist_commission_amount,
    counter_commission_amount,
    source,
    payment_method,
    payment_status,
    receipt_number,
    notes
  ) values (
    v_outlet_id,
    v_create.appointment_id,
    p_customer_id,
    coalesce(p_customer_name, ''),
    coalesce(p_customer_phone, ''),
    p_service_id,
    coalesce(p_service_name, ''),
    coalesce(p_service_items, '[]'::jsonb),
    greatest(coalesce(p_item_count, 1), 1),
    p_therapist_id,
    coalesce(v_therapist_name, ''),
    p_counter_staff_id,
    p_counter_staff_name,
    p_room_id,
    coalesce(v_room_name, ''),
    coalesce(p_service_price, 0),
    coalesce(p_sst_amount, 0),
    coalesce(p_total_amount, 0),
    v_therapist_commission,
    v_counter_commission,
    'walkin',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status,
    p_receipt_number,
    coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  insert into public.appointment_therapist_allocations (
    appointment_id,
    therapist_id,
    commission_share,
    allocation_method,
    created_by
  ) values (
    v_create.appointment_id,
    p_therapist_id,
    1,
    'full',
    p_created_by
  )
  on conflict on constraint
    appointment_therapist_allocatio_appointment_id_therapist_id_key
  do update set
    commission_share = 1,
    allocation_method = 'full',
    updated_at = now();

  perform public.recalculate_appointment_therapist_commission(
    v_create.appointment_id
  );

  success := true;
  appointment_id := v_create.appointment_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

revoke all on function public.create_staff_walkin_with_payment(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer,
  text, text, text, uuid, text, numeric, numeric, text, text, text, boolean,
  text, uuid, text, uuid, text
) from public, anon;
grant execute on function public.create_staff_walkin_with_payment(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer,
  text, text, text, uuid, text, numeric, numeric, text, text, text, boolean,
  text, uuid, text, uuid, text
) to authenticated;


comment on function public.consume_therapist_queue_turn_for_start(
  uuid, date, uuid, timestamptz, uuid
) is 'Consumes the started therapist live turn, except an out-of-turn exact customer request.';

commit;
