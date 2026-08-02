-- Stage 7: central, authoritative money enforcement for every staff payment
-- path, plus clean separation of Flutter entrypoints from internal legacy RPCs.

create or replace function private.authoritative_service_snapshot(
  p_outlet_id uuid,
  p_items jsonb
)
returns table (
  service_items jsonb,
  display_price numeric,
  item_count integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_id_text text;
  v_service public.services%rowtype;
begin
  service_items := '[]'::jsonb;
  display_price := 0;
  item_count := 0;

  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'Service items must be an array.';
  end if;

  for v_item in
    select item.value
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) item(value)
  loop
    v_id_text := nullif(trim(coalesce(
      v_item ->> 'id',
      v_item ->> 'service_id',
      v_item ->> 'serviceId'
    )), '');
    if v_id_text is null or v_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception using errcode = '22023', message = 'Every financial item must identify a service.';
    end if;

    select service.* into v_service
    from public.services service
    where service.id = v_id_text::uuid
      and service.outlet_id = p_outlet_id;
    if not found then
      raise exception using errcode = '22023', message = 'A financial item does not belong to the selected outlet.';
    end if;

    service_items := service_items || jsonb_build_array(
      v_item || jsonb_build_object(
        'id', v_service.id,
        'service_id', v_service.id,
        'name', v_service.name,
        'price', v_service.price,
        'display_price', v_service.price,
        'duration', v_service.duration,
        'category', v_service.category,
        'bufferAfterMinutes', v_service.buffer_after_minutes,
        'therapistCommission', v_service.therapist_commission,
        'counterCommission', v_service.counter_commission
      )
    );
    display_price := display_price + coalesce(v_service.price, 0);
    item_count := item_count + 1;
  end loop;

  display_price := round(display_price, 2);
  return next;
end;
$$;

revoke all on function private.authoritative_service_snapshot(uuid, jsonb)
from public, anon, authenticated, service_role;

create or replace function public.stage7_enforce_transaction_money()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_snapshot record;
  v_breakdown record;
  v_first jsonb;
  v_counter_name text;
begin
  -- Service-role Billplz writes have a separate authoritative hold contract.
  if auth.uid() is null then
    return new;
  end if;
  if not (select public.is_staff_or_admin()) then
    raise exception using errcode = '42501', message = 'Not authorised';
  end if;
  if coalesce(new.source, '') = 'online_booking' then
    raise exception using errcode = '42501', message = 'Staff cannot create online-booking transactions.';
  end if;
  if nullif(trim(coalesce(new.receipt_number, '')), '') is null then
    raise exception using errcode = '22023', message = 'A receipt number is required.';
  end if;

  if new.appointment_id is not null then
    perform 1 from public.appointments appointment
    where appointment.id = new.appointment_id
    for update;
  end if;
  if new.appointment_group_id is not null then
    perform 1 from public.appointments appointment
    where appointment.appointment_group_id = new.appointment_group_id
    order by appointment.id
    for update;
  end if;

  select * into v_snapshot
  from private.authoritative_service_snapshot(new.outlet_id, new.service_items);
  if coalesce(v_snapshot.item_count, 0) < 1 then
    raise exception using errcode = '22023', message = 'A financial transaction requires at least one service item.';
  end if;

  select * into v_breakdown
  from public.outlet_payment_breakdown(
    new.outlet_id,
    v_snapshot.display_price,
    case when coalesce(new.source, '') = 'appointment_addon'
      then 'appointment_addon' else 'counter' end
  );

  v_first := v_snapshot.service_items -> 0;
  new.service_items := v_snapshot.service_items;
  new.item_count := v_snapshot.item_count;
  new.service_id := (v_first ->> 'id')::uuid;
  new.service_name := coalesce(v_first ->> 'name', '');
  new.service_price := v_breakdown.service_price;
  new.sst_amount := v_breakdown.sst_amount;
  new.total_amount := v_breakdown.total_amount;

  if new.counter_staff_id is not null then
    select therapist.name into v_counter_name
    from public.therapists therapist
    where therapist.id = new.counter_staff_id
      and therapist.outlet_id = new.outlet_id
      and lower(coalesce(therapist.role, '')) in ('counter', 'cashier');
    if not found then
      raise exception using errcode = '22023', message = 'Counter staff must belong to the transaction outlet.';
    end if;
    new.counter_staff_name := v_counter_name;
  else
    new.counter_staff_name := null;
  end if;

  new.therapist_commission_amount :=
    public.csp_commission_for_transaction_items(
      new.service_items,
      new.therapist_id
    );
  new.counter_commission_amount := case
    when new.counter_staff_id is null then 0
    else public.csp_commission_for_items(
      new.service_items,
      new.counter_staff_id,
      'Counter'
    )
  end;
  perform set_config('app.authorized_financial_write', 'on', true);
  return new;
end;
$$;

revoke all on function public.stage7_enforce_transaction_money()
from public, anon, authenticated, service_role;

drop trigger if exists transactions_stage7_authoritative_money
on public.transactions;
create trigger transactions_stage7_authoritative_money
before insert on public.transactions
for each row execute function public.stage7_enforce_transaction_money();

create or replace function public.protect_appointment_financial_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_snapshot record;
  v_breakdown record;
begin
  if tg_op = 'UPDATE'
     and current_setting('app.authorized_financial_write', true) = 'on'
     and old.payment_status <> 'unpaid'::public.payment_status then
    raise exception using
      errcode = '23514',
      message = 'Only an unpaid appointment can enter counter checkout.';
  end if;

  if auth.uid() is null then
    return new;
  end if;
  if not (select public.is_staff_or_admin()) then
    raise exception using errcode = '42501', message = 'Not authorised';
  end if;
  if jsonb_typeof(coalesce(new.service_items, '[]'::jsonb)) = 'array'
     and jsonb_array_length(coalesce(new.service_items, '[]'::jsonb)) > 0 then
    select * into v_snapshot
    from private.authoritative_service_snapshot(new.outlet_id, new.service_items);
    new.service_items := v_snapshot.service_items;
    new.item_count := v_snapshot.item_count;
    new.service_id := ((v_snapshot.service_items -> 0) ->> 'id')::uuid;
    new.service_name := (v_snapshot.service_items -> 0) ->> 'name';
    if new.payment_status = 'paid'::public.payment_status then
      select * into v_breakdown
      from public.outlet_payment_breakdown(
        new.outlet_id,
        v_snapshot.display_price,
        'counter'
      );
      new.total_price := v_breakdown.total_amount;
    else
      new.total_price := v_snapshot.display_price;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.protect_appointment_financial_fields()
from public, anon, authenticated, service_role;

drop trigger if exists appointments_financial_fields_admin_only
on public.appointments;
drop trigger if exists appointments_insert_financial_normalization
on public.appointments;
create trigger appointments_financial_fields_admin_only
before update of total_price, payment_status, service_items
on public.appointments
for each row execute function public.protect_appointment_financial_fields();
create trigger appointments_insert_financial_normalization
before insert on public.appointments
for each row execute function public.protect_appointment_financial_fields();

-- Do not rely on a SECURITY DEFINER trigger's current_user to identify the
-- caller: inside the trigger it is the function owner. Enforce the direct
-- client boundary with column privileges instead. Staff use the hardened
-- SECURITY DEFINER RPCs for appointment creation and financial changes.
revoke insert on table public.appointments from authenticated;
revoke update on table public.appointments from authenticated;
grant update (
  customer_id,
  therapist_id,
  room_id,
  appointment_date,
  start_time,
  end_time,
  status,
  type,
  updated_at,
  updated_by,
  notes,
  appointment_group_id,
  start_at,
  end_at,
  outlet_id,
  online_booking_service_id,
  booked_date,
  booked_start_time,
  booked_end_time,
  booked_start_at,
  booked_end_at,
  actual_started_at,
  actual_completed_at,
  buffer_after_minutes,
  room_unit_id,
  room_unit_name,
  assignment_source,
  requested_therapist_id,
  requested_gender,
  therapist_assignment_state,
  room_assignment_state,
  therapist_auto_assigned_at,
  resources_confirmed_at,
  resources_confirmed_by,
  assignment_last_attempted_at,
  assignment_error_code,
  assignment_error_message,
  assignment_reconcile_attempt_count,
  assignment_next_retry_at,
  checked_in_at,
  checked_in_by,
  cancelled_at,
  cancelled_by,
  cancellation_reason,
  guest_name,
  guest_phone
) on table public.appointments to authenticated;

create or replace function public.stage7_enforce_staff_hold_money()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_snapshot record;
  v_breakdown record;
begin
  if coalesce(new.hold_kind, '') <> 'staff_walkin_draft'
     or auth.uid() is null then
    return new;
  end if;
  if not (select public.is_staff_or_admin()) then
    raise exception using errcode = '42501', message = 'Not authorised';
  end if;
  select * into v_snapshot
  from private.authoritative_service_snapshot(new.outlet_id, new.service_items);
  if coalesce(v_snapshot.item_count, 0) < 1 then
    raise exception using errcode = '22023', message = 'A walk-in draft requires at least one service.';
  end if;
  select * into v_breakdown
  from public.outlet_payment_breakdown(
    new.outlet_id,
    v_snapshot.display_price,
    'counter'
  );
  new.service_items := v_snapshot.service_items;
  new.total_amount := v_breakdown.total_amount;
  select coalesce(max(
    case when item.value ->> 'bufferAfterMinutes' ~ '^[0-9]+$'
      then (item.value ->> 'bufferAfterMinutes')::integer else 0 end
  ), 0) into new.buffer_after_minutes
  from jsonb_array_elements(v_snapshot.service_items) item(value);
  return new;
end;
$$;

revoke all on function public.stage7_enforce_staff_hold_money()
from public, anon, authenticated, service_role;

drop trigger if exists booking_holds_stage7_authoritative_staff_money
on public.booking_holds;
create trigger booking_holds_stage7_authoritative_staff_money
before insert or update of service_items, total_amount
on public.booking_holds
for each row execute function public.stage7_enforce_staff_hold_money();

-- The old single-hold function counted raw rows. Keep it private and expose a
-- wrapper that counts one distinct public token or booking group per attempt.
alter function public.create_public_booking_hold_v2(
  uuid, timestamptz, text, text, text, text, text, text, text
) rename to create_public_booking_hold_v2_stage7_legacy;

revoke all on function public.create_public_booking_hold_v2_stage7_legacy(
  uuid, timestamptz, text, text, text, text, text, text, text
) from public, anon, authenticated, service_role;

create function public.create_public_booking_hold_v2(
  p_catalogue_id uuid,
  p_start_at timestamptz,
  p_therapist_preference text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_therapist_request text default '',
  p_notes text default '',
  p_request_fingerprint text default ''
)
returns table (
  hold_id uuid,
  hold_token uuid,
  hold_expires_at timestamptz,
  total_price numeric,
  deposit_due numeric,
  duration_minutes integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result record;
  v_fingerprint text := left(trim(coalesce(p_request_fingerprint, '')), 128);
  v_attempts integer;
begin
  if v_fingerprint <> '' then
    perform pg_advisory_xact_lock(hashtextextended('public-hold-rate:' || v_fingerprint, 0));
    select count(distinct coalesce(hold.booking_group_token, hold.public_token))
    into v_attempts
    from public.booking_holds hold
    where hold.request_fingerprint = v_fingerprint
      and hold.created_at > now() - interval '1 hour';
    if coalesce(v_attempts, 0) >= 12 then
      raise exception 'Too many booking attempts. Please try again later';
    end if;
  end if;

  select * into v_result
  from public.create_public_booking_hold_v2_stage7_legacy(
    p_catalogue_id,
    p_start_at,
    p_therapist_preference,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_therapist_request,
    p_notes,
    ''
  );

  update public.booking_holds hold
  set request_fingerprint = v_fingerprint,
      updated_at = now()
  where hold.id = v_result.hold_id;

  hold_id := v_result.hold_id;
  hold_token := v_result.hold_token;
  hold_expires_at := v_result.hold_expires_at;
  total_price := v_result.total_price;
  deposit_due := v_result.deposit_due;
  duration_minutes := v_result.duration_minutes;
  return next;
end;
$$;

revoke all on function public.create_public_booking_hold_v2(
  uuid, timestamptz, text, text, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.create_public_booking_hold_v2(
  uuid, timestamptz, text, text, text, text, text, text, text
) to service_role;

-- These are the Flutter-reachable operational/financial APIs. Their bodies
-- already schema-qualify database objects; pin their runtime lookup path.
do $$
declare
  v_function record;
begin
  for v_function in
    select procedure.oid::regprocedure as identity
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname = any(array[
        'check_in_appointment',
        'check_in_appointment_group',
        'checkout_appointment_group_with_payment',
        'checkout_appointment_with_payment',
        'checkout_appointment_with_payment_v2',
        'create_appointment_group_with_csp',
        'create_appointment_with_csp',
        'create_staff_walkin_and_start_with_payment',
        'create_staff_walkin_group_and_start_with_payment',
        'create_staff_walkin_group_with_payment',
        'create_staff_walkin_with_payment',
        'finalize_and_start_appointment',
        'finalize_and_start_appointment_group',
        'pay_appointment_addons',
        'pay_appointment_group_addons',
        'reserve_staff_walkin_allocation',
        'update_appointment_group_with_csp'
      ])
  loop
    execute format('alter function %s set search_path = %L', v_function.identity, '');
  end loop;
end;
$$;

-- Internal aliases are not Flutter entrypoints. Removing their Data API grants
-- prevents staff from bypassing the hardened wrappers.
do $$
declare
  v_function record;
begin
  for v_function in
    select procedure.oid::regprocedure as identity
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname = any(array[
        'check_in_paid_appointment_group_with_addon',
        'check_in_paid_appointment_with_addon',
        'confirm_and_start_appointment',
        'confirm_and_start_group',
        'create_walkin_appointment_group_with_payment',
        'create_walkin_appointment_with_payment',
        'finalize_and_start_appointment_122t_capacity_first_dormant',
        'finalize_and_start_appointment_group_122t_capacity_first_dorman'
      ])
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated, service_role',
      v_function.identity
    );
  end loop;
end;
$$;

alter function public.create_public_booking_group_hold_v1(
  jsonb, timestamptz, text, text, text, text, text
) set search_path = '';

comment on function private.authoritative_service_snapshot(uuid, jsonb)
is 'Stage 7 authoritative service names, prices, duration and commission defaults.';
comment on function public.stage7_enforce_transaction_money()
is 'Final staff financial-write boundary: role check, locks and server-derived money.';
comment on function public.create_public_booking_hold_v2(
  uuid, timestamptz, text, text, text, text, text, text, text
) is 'Public single-hold wrapper whose hourly limit counts distinct groups/requests.';
