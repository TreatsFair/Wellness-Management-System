-- The RPC's RETURNS TABLE declares an appointment_id output variable. Using
-- appointment_id again in ON CONFLICT inference is ambiguous in PL/pgSQL, so
-- target the existing unique constraint by name instead.

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
  v_existing record;
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

  if p_start_immediately then
    select * into v_existing
    from public.create_walkin_appointment_with_payment(
      p_customer_id, p_therapist_id, p_room_id, p_service_id, p_date,
      p_start_time, p_end_time, p_service_price, p_service_name,
      p_service_items, p_item_count, p_notes, p_customer_name, p_customer_phone,
      p_counter_staff_id, p_counter_staff_name, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes, p_created_by
    );
    success := v_existing.success;
    appointment_id := v_existing.appointment_id;
    transaction_id := v_existing.transaction_id;
    error_code := v_existing.error_code;
    error_message := v_existing.error_message;
    return next; return;
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
    p_notes => p_notes
  );
  if not coalesce(v_create.success, false) then
    success := false; appointment_id := null; transaction_id := null;
    error_code := v_create.error_code; error_message := v_create.error_message;
    return next; return;
  end if;

  select a.outlet_id into v_outlet_id
  from public.appointments a where a.id = v_create.appointment_id;
  select t.name into v_therapist_name
  from public.therapists t where t.id = p_therapist_id;
  select r.name into v_room_name
  from public.rooms r where r.id = p_room_id;
  v_therapist_commission := public.csp_commission_for_items(
    p_service_items, p_therapist_id, 'Therapist'
  );
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(
      p_service_items, p_counter_staff_id, 'Counter'
    ) end;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_outlet_id, v_create.appointment_id, p_customer_id,
    coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    p_service_id, coalesce(p_service_name, ''),
    coalesce(p_service_items, '[]'::jsonb),
    greatest(coalesce(p_item_count, 1), 1),
    p_therapist_id, coalesce(v_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    p_room_id, coalesce(v_room_name, ''), coalesce(p_service_price, 0),
    coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'walkin',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    coalesce(p_transaction_notes, '')
  ) returning id into v_transaction_id;

  insert into public.appointment_therapist_allocations (
    appointment_id, therapist_id, commission_share, allocation_method,
    created_by
  ) values (
    v_create.appointment_id, p_therapist_id, 1, 'full', p_created_by
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
  text, uuid
) from public, anon;
grant execute on function public.create_staff_walkin_with_payment(
  uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer,
  text, text, text, uuid, text, numeric, numeric, text, text, text, boolean,
  text, uuid
) to authenticated;
