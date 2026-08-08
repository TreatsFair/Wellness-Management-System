-- =====================================================================
-- 136_group_checkout_authorization.sql
-- =====================================================================
-- Defence-in-depth hardening for public.checkout_appointment_group_with_payment.
--
-- WHY
--   Stage 7 hardened the single-appointment checkout path
--   (checkout_appointment_with_payment -> _v2) with an explicit
--   is_staff_or_admin() gate. The GROUP path was not given the same
--   treatment: it relied entirely on the BEFORE INSERT trigger
--   transactions_stage7_authoritative_money to reject unauthorised callers
--   and to overwrite client-supplied money.
--
--   That trigger does work -- an unauthorised caller is rejected and the
--   amounts are recomputed -- so this is NOT an exploitable hole. It is a
--   defence-in-depth gap: the function should fail fast at entry rather
--   than depend on a single downstream layer, and it should validate its
--   own inputs before mutating any appointment row.
--
-- WHAT THIS CHANGES
--   * explicit authorisation at function entry (auth.uid() + staff/admin)
--   * deterministic row locking of the group and its appointments BEFORE
--     any mutation
--   * input validation: every appointment exists, belongs to the supplied
--     group, and all share one outlet
--   * idempotent duplicate-checkout guard (returns the existing
--     transaction instead of creating a second paid one)
--
-- WHAT THIS DELIBERATELY DOES NOT CHANGE
--   * money: the client parameters are still passed through exactly as
--     before. transactions_stage7_authoritative_money remains the single
--     authoritative-money layer. outlet_payment_breakdown is NOT called
--     here and its logic is NOT duplicated.
--   * commissions: unchanged.
--   * p_per_appointment_updates semantics: unchanged.
--   * the RPC name and argument signature: unchanged, so no Flutter
--     release is required.
--   * atomicity: the whole function remains one transaction; any raise
--     rolls back every appointment update.
-- =====================================================================

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
returns table(
  success boolean,
  appointment_group_id uuid,
  transaction_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path to ''
as $function$
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
  v_group_exists boolean;
  v_supplied_count integer;
  v_found_count integer;
  v_wrong_group_count integer;
  v_distinct_outlets integer;
  v_existing_transaction_id uuid;
begin
  if auth.uid() is null or not (select public.is_staff_or_admin()) then
    raise exception using errcode = '42501', message = 'Not authorised';
  end if;

  if p_appointment_ids is null or array_length(p_appointment_ids, 1) is null then
    success := false;
    appointment_group_id := p_appointment_group_id;
    transaction_id := null;
    error_code := 'INVALID_ALLOCATIONS';
    error_message := 'No appointments supplied for checkout.';
    return next;
    return;
  end if;

  if p_appointment_group_id is null then
    success := false;
    appointment_group_id := null;
    transaction_id := null;
    error_code := 'INVALID_GROUP';
    error_message := 'An appointment group is required for group checkout.';
    return next;
    return;
  end if;

  select true into v_group_exists
  from public.appointment_groups grp
  where grp.id = p_appointment_group_id
  for update;

  if not found then
    success := false;
    appointment_group_id := p_appointment_group_id;
    transaction_id := null;
    error_code := 'GROUP_NOT_FOUND';
    error_message := 'Appointment group was not found.';
    return next;
    return;
  end if;

  perform 1
  from public.appointments appointment
  where appointment.id = any(p_appointment_ids)
  order by appointment.id
  for update;

  select count(distinct supplied.id)
  into v_supplied_count
  from unnest(p_appointment_ids) as supplied(id);

  select
    count(*),
    count(*) filter (
      where appointment.appointment_group_id is distinct from p_appointment_group_id
    ),
    count(distinct appointment.outlet_id)
  into v_found_count, v_wrong_group_count, v_distinct_outlets
  from public.appointments appointment
  where appointment.id = any(p_appointment_ids);

  if v_found_count <> v_supplied_count then
    success := false;
    appointment_group_id := p_appointment_group_id;
    transaction_id := null;
    error_code := 'APPOINTMENT_NOT_FOUND';
    error_message := 'One or more appointments were not found.';
    return next;
    return;
  end if;

  if v_wrong_group_count > 0 then
    success := false;
    appointment_group_id := p_appointment_group_id;
    transaction_id := null;
    error_code := 'GROUP_MISMATCH';
    error_message := 'Every appointment must belong to the supplied group.';
    return next;
    return;
  end if;

  if v_distinct_outlets > 1 then
    success := false;
    appointment_group_id := p_appointment_group_id;
    transaction_id := null;
    error_code := 'MIXED_OUTLET';
    error_message := 'A group checkout cannot span multiple outlets.';
    return next;
    return;
  end if;

  select transaction.id
  into v_existing_transaction_id
  from public.transactions transaction
  where transaction.appointment_group_id = p_appointment_group_id
    and coalesce(transaction.source, '') <> 'appointment_addon'
  order by transaction.created_at, transaction.id
  limit 1
  for update;

  if v_existing_transaction_id is not null then
    success := true;
    appointment_group_id := p_appointment_group_id;
    transaction_id := v_existing_transaction_id;
    error_code := null;
    error_message := null;
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
$function$;

comment on function public.checkout_appointment_group_with_payment(
  uuid, uuid[], uuid, text, text, jsonb, uuid, text, numeric, numeric,
  numeric, text, text, text
) is 'Group counter checkout. Authorises staff/admin at entry, locks and validates the group before mutation, and is idempotent per group. Money remains enforced by transactions_stage7_authoritative_money.';
