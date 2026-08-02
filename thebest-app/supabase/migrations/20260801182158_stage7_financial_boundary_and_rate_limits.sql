-- Stage 7: close direct staff financial writes, make single-appointment
-- checkout server-priced and idempotent, and provide a private rate-limit
-- counter for the public booking Edge Function.

-- Direct transaction creation is an administrator-only correction path.
-- Normal counter payments continue through SECURITY DEFINER checkout RPCs.
drop policy if exists transactions_insert_staff_admin on public.transactions;
drop policy if exists transactions_insert_admin on public.transactions;
create policy transactions_insert_admin
on public.transactions
for insert
to authenticated
with check ((select public.is_admin()));

-- Staff may update operational appointment fields, but not the financial
-- snapshot directly. Privileged database workflows and service_role remain
-- able to synchronize payment state; administrators retain direct correction
-- ability and every change is already captured by appointments_write_audit_log.
create or replace function public.protect_appointment_financial_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (
    new.total_price is distinct from old.total_price
    or new.payment_status is distinct from old.payment_status
  ) and not (
    current_user in ('postgres', 'supabase_admin', 'service_role')
    or (select public.is_admin())
  ) then
    raise exception using
      errcode = '42501',
      message = 'Only an administrator or authorised payment workflow can change appointment financial fields.';
  end if;

  return new;
end;
$$;

revoke all on function public.protect_appointment_financial_fields()
from public, anon, authenticated, service_role;

drop trigger if exists appointments_financial_fields_admin_only
on public.appointments;
create trigger appointments_financial_fields_admin_only
before update of total_price, payment_status
on public.appointments
for each row
execute function public.protect_appointment_financial_fields();

-- New identifiers/operational-choices-only contract. Monetary values are
-- resolved from services and business_settings inside the locked transaction.
create or replace function public.checkout_appointment_with_payment_v2(
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
set search_path = ''
as $$
declare
  v_appointment public.appointments%rowtype;
  v_existing_transaction_id uuid;
  v_transaction_id uuid;
  v_item_count integer := 0;
  v_matched_count integer := 0;
  v_display_price numeric := 0;
  v_service_items jsonb := '[]'::jsonb;
  v_service_id uuid;
  v_service_name text := '';
  v_therapist_name text := '';
  v_room_name text := '';
  v_counter_staff_name text;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric := 0;
  v_breakdown record;
begin
  if auth.uid() is null or not (select public.is_staff_or_admin()) then
    raise exception using errcode = '42501', message = 'Not authorised';
  end if;

  select appointment.*
  into v_appointment
  from public.appointments appointment
  where appointment.id = p_appointment_id
  for update;

  if not found then
    success := false;
    appointment_id := null;
    transaction_id := null;
    error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.';
    return next;
    return;
  end if;

  select transaction.id
  into v_existing_transaction_id
  from public.transactions transaction
  where transaction.appointment_id = p_appointment_id
    and coalesce(transaction.source, '') <> 'appointment_addon'
  order by transaction.created_at, transaction.id
  limit 1
  for update;

  if v_existing_transaction_id is not null then
    success := true;
    appointment_id := p_appointment_id;
    transaction_id := v_existing_transaction_id;
    error_code := null;
    error_message := null;
    return next;
    return;
  end if;

  if v_appointment.status in ('cancelled', 'no_show', 'completed') then
    success := false;
    appointment_id := p_appointment_id;
    transaction_id := null;
    error_code := 'INVALID_STATUS';
    error_message := 'This appointment can no longer be checked out.';
    return next;
    return;
  end if;

  if nullif(trim(coalesce(p_receipt_number, '')), '') is null then
    raise exception using errcode = '22023', message = 'A receipt number is required.';
  end if;

  if jsonb_typeof(coalesce(v_appointment.service_items, '[]'::jsonb)) = 'array'
     and jsonb_array_length(coalesce(v_appointment.service_items, '[]'::jsonb)) > 0 then
    select
      count(*)::integer,
      count(service.id)::integer,
      coalesce(sum(service.price), 0),
      coalesce(
        jsonb_agg(
          item.value || jsonb_build_object(
            'id', service.id,
            'name', service.name,
            'price', service.price,
            'duration', service.duration,
            'category', service.category,
            'therapistCommission', service.therapist_commission,
            'counterCommission', service.counter_commission
          )
          order by item.ordinality
        ) filter (where service.id is not null),
        '[]'::jsonb
      ),
      (array_agg(service.id order by item.ordinality)
        filter (where service.id is not null))[1],
      coalesce(string_agg(service.name, ' + ' order by item.ordinality), '')
    into
      v_item_count,
      v_matched_count,
      v_display_price,
      v_service_items,
      v_service_id,
      v_service_name
    from jsonb_array_elements(v_appointment.service_items)
      with ordinality as item(value, ordinality)
    left join public.services service
      on service.id = case
        when coalesce(item.value ->> 'id', '')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (item.value ->> 'id')::uuid
        else null
      end
      and service.outlet_id = v_appointment.outlet_id;
  elsif v_appointment.service_id is not null then
    select
      1,
      1,
      service.price,
      jsonb_build_array(jsonb_build_object(
        'id', service.id,
        'name', service.name,
        'price', service.price,
        'duration', service.duration,
        'category', service.category,
        'therapistCommission', service.therapist_commission,
        'counterCommission', service.counter_commission
      )),
      service.id,
      service.name
    into
      v_item_count,
      v_matched_count,
      v_display_price,
      v_service_items,
      v_service_id,
      v_service_name
    from public.services service
    where service.id = v_appointment.service_id
      and service.outlet_id = v_appointment.outlet_id;
  end if;

  if v_item_count < 1 or v_matched_count <> v_item_count then
    raise exception using
      errcode = '22023',
      message = 'Every appointment item must match an authoritative outlet service.';
  end if;

  select breakdown.*
  into v_breakdown
  from public.outlet_payment_breakdown(
    v_appointment.outlet_id,
    v_display_price,
    'counter'
  ) breakdown;

  if p_counter_staff_id is not null then
    select therapist.name
    into v_counter_staff_name
    from public.therapists therapist
    where therapist.id = p_counter_staff_id
      and therapist.outlet_id = v_appointment.outlet_id
      and lower(coalesce(therapist.role, '')) in ('counter', 'cashier');

    if not found then
      raise exception using
        errcode = '22023',
        message = 'Counter staff must belong to the appointment outlet.';
    end if;
  end if;

  select therapist.name into v_therapist_name
  from public.therapists therapist
  where therapist.id = v_appointment.therapist_id;

  select room.name into v_room_name
  from public.rooms room
  where room.id = v_appointment.room_id;

  v_therapist_commission := public.csp_commission_for_items(
    v_service_items,
    v_appointment.therapist_id,
    'Therapist'
  );
  v_counter_commission := case
    when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(
      v_service_items,
      p_counter_staff_id,
      'Counter'
    )
  end;

  perform set_config(
    'app.allow_late_extension_overlap',
    case when p_allow_late_extension_overlap then 'on' else 'off' end,
    true
  );
  perform set_config('app.authorized_financial_write', 'on', true);

  update public.appointments appointment
  set customer_id = p_customer_id,
      booked_date = coalesce(p_booked_date, appointment.booked_date),
      booked_start_time = coalesce(
        p_booked_start_time,
        appointment.booked_start_time
      ),
      booked_end_time = coalesce(p_booked_end_time, appointment.booked_end_time),
      booked_start_at = coalesce(p_booked_start_at, appointment.booked_start_at),
      booked_end_at = coalesce(p_booked_end_at, appointment.booked_end_at),
      end_time = coalesce(p_end_time, appointment.end_time),
      end_at = coalesce(p_end_at, appointment.end_at),
      service_id = v_service_id,
      service_name = v_service_name,
      service_items = v_service_items,
      item_count = v_item_count,
      total_price = v_breakdown.total_amount,
      payment_status = 'paid'::public.payment_status,
      actual_started_at = coalesce(appointment.actual_started_at, now()),
      status = 'in_progress',
      updated_at = now()
  where appointment.id = p_appointment_id;

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
    v_appointment.outlet_id,
    p_appointment_id,
    p_customer_id,
    coalesce(p_customer_name, ''),
    coalesce(p_customer_phone, ''),
    v_service_id,
    v_service_name,
    v_service_items,
    v_item_count,
    v_appointment.therapist_id,
    coalesce(v_therapist_name, ''),
    p_counter_staff_id,
    v_counter_staff_name,
    v_appointment.room_id,
    coalesce(v_room_name, ''),
    v_breakdown.service_price,
    v_breakdown.sst_amount,
    v_breakdown.total_amount,
    v_therapist_commission,
    v_counter_commission,
    'appointment',
    coalesce(nullif(trim(p_payment_method), ''), 'cash')::public.payment_method,
    'paid'::public.payment_status,
    trim(p_receipt_number),
    left(coalesce(p_transaction_notes, ''), 1000)
  )
  returning id into v_transaction_id;

  insert into public.audit_log (
    table_name,
    record_id,
    action,
    changed_at,
    changed_by,
    new_data
  ) values (
    'transactions',
    v_transaction_id::text,
    'SECURE_CHECKOUT',
    now(),
    auth.uid(),
    jsonb_build_object(
      'appointment_id', p_appointment_id,
      'transaction_id', v_transaction_id,
      'service_price', v_breakdown.service_price,
      'sst_amount', v_breakdown.sst_amount,
      'total_amount', v_breakdown.total_amount,
      'payment_method', coalesce(nullif(trim(p_payment_method), ''), 'cash'),
      'server_priced', true
    )
  );

  success := true;
  appointment_id := p_appointment_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
exception
  when unique_violation then
    select transaction.id
    into v_existing_transaction_id
    from public.transactions transaction
    where transaction.appointment_id = p_appointment_id
      and coalesce(transaction.source, '') <> 'appointment_addon'
    order by transaction.created_at, transaction.id
    limit 1;

    if v_existing_transaction_id is not null then
      success := true;
      appointment_id := p_appointment_id;
      transaction_id := v_existing_transaction_id;
      error_code := null;
      error_message := null;
      return next;
      return;
    end if;
    raise;
end;
$$;

revoke all on function public.checkout_appointment_with_payment_v2(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  time, timestamptz, boolean, uuid, text, text, text
) from public, anon;
grant execute on function public.checkout_appointment_with_payment_v2(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  time, timestamptz, boolean, uuid, text, text, text
) to authenticated;

-- Compatibility wrapper for already-installed Flutter builds. Legacy client
-- money parameters remain accepted at the protocol boundary but are ignored;
-- only the v2 server-derived values can reach transactions.
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
set search_path = ''
as $$
begin
  return query
  select result.success,
         result.appointment_id,
         result.transaction_id,
         result.error_code,
         result.error_message
  from public.checkout_appointment_with_payment_v2(
    p_appointment_id,
    p_customer_id,
    p_customer_name,
    p_customer_phone,
    p_booked_date,
    p_booked_start_time,
    p_booked_end_time,
    p_booked_start_at,
    p_booked_end_at,
    p_end_time,
    p_end_at,
    p_allow_late_extension_overlap,
    p_counter_staff_id,
    p_payment_method,
    p_receipt_number,
    p_transaction_notes
  ) result;
end;
$$;

revoke all on function public.checkout_appointment_with_payment(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  time, timestamptz, boolean, uuid, text, numeric, numeric, numeric,
  text, text, text
) from public, anon;
grant execute on function public.checkout_appointment_with_payment(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  time, timestamptz, boolean, uuid, text, numeric, numeric, numeric,
  text, text, text
) to authenticated;

-- Private fixed-window counters used only through the service-role Edge
-- Function. Inbound Supabase Edge requests are not platform-rate-limited.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.booking_rate_limit_buckets (
  subject_hash text not null,
  route_key text not null,
  window_seconds integer not null,
  window_start timestamptz not null,
  request_count integer not null default 1,
  updated_at timestamptz not null default now(),
  primary key (subject_hash, route_key, window_seconds, window_start),
  constraint booking_rate_limit_window_valid
    check (window_seconds between 1 and 86400),
  constraint booking_rate_limit_count_valid
    check (request_count >= 1)
);

revoke all on private.booking_rate_limit_buckets
from public, anon, authenticated, service_role;

create or replace function public.consume_booking_rate_limit(
  p_subject_hash text,
  p_route_key text,
  p_limit integer,
  p_window_seconds integer
)
returns table (
  allowed boolean,
  retry_after_seconds integer,
  remaining integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_window_start timestamptz;
  v_count integer;
begin
  if length(trim(coalesce(p_subject_hash, ''))) < 16
     or length(trim(coalesce(p_route_key, ''))) < 1
     or p_limit < 1
     or p_window_seconds < 1
     or p_window_seconds > 86400 then
    raise exception using errcode = '22023', message = 'Invalid rate-limit input.';
  end if;

  v_window_start := to_timestamp(
    floor(extract(epoch from v_now) / p_window_seconds) * p_window_seconds
  );

  insert into private.booking_rate_limit_buckets (
    subject_hash,
    route_key,
    window_seconds,
    window_start,
    request_count,
    updated_at
  ) values (
    left(trim(p_subject_hash), 128),
    left(trim(p_route_key), 80),
    p_window_seconds,
    v_window_start,
    1,
    v_now
  )
  on conflict (subject_hash, route_key, window_seconds, window_start)
  do update set
    request_count = private.booking_rate_limit_buckets.request_count + 1,
    updated_at = excluded.updated_at
  returning request_count into v_count;

  if random() < 0.01 then
    delete from private.booking_rate_limit_buckets
    where window_start < v_now - interval '2 days';
  end if;

  allowed := v_count <= p_limit;
  retry_after_seconds := case
    when allowed then 0
    else greatest(
      1,
      ceil(extract(epoch from (
        v_window_start + make_interval(secs => p_window_seconds) - v_now
      )))::integer
    )
  end;
  remaining := greatest(p_limit - v_count, 0);
  return next;
end;
$$;

revoke all on function public.consume_booking_rate_limit(
  text, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.consume_booking_rate_limit(
  text, text, integer, integer
) to service_role;

comment on function public.checkout_appointment_with_payment_v2(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  time, timestamptz, boolean, uuid, text, text, text
) is 'Stage 7 server-priced, locked and idempotent single-appointment counter checkout.';

comment on function public.consume_booking_rate_limit(
  text, text, integer, integer
) is 'Service-role-only fixed-window limiter for public booking Edge routes.';
