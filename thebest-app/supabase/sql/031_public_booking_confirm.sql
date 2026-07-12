-- Convert a public booking hold into a real, confirmed appointment.
--
-- This is the step that was deferred to the "Billplz phase": create_public_booking_hold_v2
-- only reserves a therapist + room on a `booking_holds` row (status pending_payment).
-- confirm_public_booking_hold() promotes that hold into an appointments row and links the
-- two. For the pre-Billplz test the Edge Function calls this immediately after the hold is
-- created (gated by BOOKING_TEST_AUTOCONFIRM); later, the Billplz payment callback will call
-- this same function as the source of truth for confirmation.
--
-- Ordering matters: prevent_appointment_resource_overlap (028) counts any
-- booking_holds row with status = 'pending_payment' as an occupied resource. The hold we
-- are converting is assigned to the same therapist/room over the same time, so the hold
-- MUST be moved off 'pending_payment' before the appointment is inserted, or the overlap
-- trigger would reject the insert against the hold's own reservation.

create or replace function public.confirm_public_booking_hold(p_token uuid)
returns table (
  appointment_id uuid,
  status text,
  start_at timestamptz,
  end_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hold public.booking_holds%rowtype;
  v_service_id uuid;
  v_service_name text;
  v_duration integer;
  v_customer_id uuid;
  v_local_start timestamp;
  v_local_end timestamp;
  v_appointment_id uuid;
begin
  select * into v_hold
  from public.booking_holds
  where public_token = p_token
  for update;

  if not found then
    raise exception 'Booking reference not found';
  end if;

  -- Idempotent: a retry / double-call returns the appointment already created.
  if v_hold.status = 'confirmed' and v_hold.appointment_id is not null then
    appointment_id := v_hold.appointment_id;
    status := v_hold.status;
    start_at := v_hold.start_at;
    end_at := v_hold.end_at;
    return next;
    return;
  end if;

  if v_hold.status not in ('pending_payment', 'paid')
     or (v_hold.status = 'pending_payment' and v_hold.expires_at <= now()) then
    raise exception 'This booking hold can no longer be confirmed';
  end if;

  if v_hold.assigned_therapist_id is null or v_hold.assigned_room_id is null then
    raise exception 'This booking hold has no assigned therapist or room';
  end if;

  select s.id, s.name, greatest(s.duration, 1)
  into v_service_id, v_service_name, v_duration
  from public.online_booking_services c
  join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
  where c.id = v_hold.online_booking_service_id;

  if v_service_id is null then
    raise exception 'The booked service is no longer available';
  end if;

  -- Find-or-create a customer in this outlet, matched on phone.
  select id into v_customer_id
  from public.customers
  where outlet_id = v_hold.outlet_id
    and phone = v_hold.customer_phone
  limit 1;

  if v_customer_id is null then
    insert into public.customers (name, phone, email, outlet_id, join_date)
    values (
      v_hold.customer_name,
      v_hold.customer_phone,
      nullif(v_hold.customer_email, ''),
      v_hold.outlet_id,
      (now() at time zone 'Asia/Kuala_Lumpur')::date
    )
    returning id into v_customer_id;
  end if;

  -- Move the hold off pending_payment BEFORE inserting the appointment so the
  -- resource-overlap trigger does not treat the hold as a competing reservation.
  update public.booking_holds
  set status = 'confirmed',
      confirmed_at = now(),
      customer_id = v_customer_id,
      updated_at = now()
  where id = v_hold.id;

  v_local_start := v_hold.start_at at time zone 'Asia/Kuala_Lumpur';
  v_local_end := v_hold.end_at at time zone 'Asia/Kuala_Lumpur';

  insert into public.appointments (
    outlet_id,
    customer_id,
    therapist_id,
    room_id,
    service_id,
    online_booking_service_id,
    appointment_date,
    start_time,
    end_time,
    start_at,
    end_at,
    booked_date,
    booked_start_time,
    booked_end_time,
    booked_start_at,
    booked_end_at,
    status,
    total_price,
    type,
    service_name,
    service_items,
    item_count,
    buffer_after_minutes,
    notes,
    created_at
  )
  values (
    v_hold.outlet_id,
    v_customer_id,
    v_hold.assigned_therapist_id,
    v_hold.assigned_room_id,
    v_service_id,
    v_hold.online_booking_service_id,
    v_local_start::date,
    v_local_start::time,
    v_local_end::time,
    v_hold.start_at,
    v_hold.end_at,
    v_local_start::date,
    v_local_start::time,
    v_local_end::time,
    v_hold.start_at,
    v_hold.end_at,
    'confirmed',
    v_hold.total_amount,
    'appointment',
    v_service_name,
    jsonb_build_array(jsonb_build_object(
      'id', v_service_id,
      'name', v_service_name,
      'duration', v_duration,
      'price', v_hold.total_amount
    )),
    1,
    greatest(coalesce(v_hold.buffer_after_minutes, 0), 0),
    v_hold.notes,
    now()
  )
  returning id into v_appointment_id;

  update public.booking_holds
  set appointment_id = v_appointment_id,
      updated_at = now()
  where id = v_hold.id;

  appointment_id := v_appointment_id;
  status := 'confirmed';
  start_at := v_hold.start_at;
  end_at := v_hold.end_at;
  return next;
end;
$$;

do $$ begin
  execute 'revoke all on function public.confirm_public_booking_hold(uuid) from public, anon, authenticated';
  execute 'grant execute on function public.confirm_public_booking_hold(uuid) to service_role';
end $$;
