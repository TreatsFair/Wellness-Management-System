-- Record a successful Billplz booking as a paid sale exactly once.

create unique index if not exists transactions_online_booking_appointment_uidx
  on public.transactions (appointment_id)
  where source = 'online_booking' and appointment_id is not null;

create or replace function public.record_online_booking_payment(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hold public.booking_holds%rowtype;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_therapist_name text := '';
  v_room_name text := '';
  v_transaction_id uuid;
begin
  select * into v_hold
  from public.booking_holds
  where public_token = p_token
  for update;

  if not found or v_hold.status <> 'confirmed' or v_hold.appointment_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_hold.appointment_id;

  select * into v_customer from public.customers where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_appointment.room_id;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, room_id, room_name,
    service_price, sst_amount, total_amount,
    payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_hold.outlet_id, v_appointment.id, v_appointment.customer_id,
    coalesce(v_customer.name, v_hold.customer_name),
    coalesce(v_customer.phone, v_hold.customer_phone),
    v_appointment.service_id, v_appointment.service_name,
    v_appointment.service_items, v_appointment.item_count,
    v_appointment.therapist_id, v_therapist_name,
    v_appointment.room_id, v_room_name,
    v_hold.total_amount, 0, v_hold.total_amount,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_hold.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_id) where source = 'online_booking' and appointment_id is not null
  do update set
    payment_status = 'paid',
    total_amount = excluded.total_amount,
    receipt_number = excluded.receipt_number
  returning id into v_transaction_id;

  return v_transaction_id;
end;
$$;

revoke all on function public.record_online_booking_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.record_online_booking_payment(uuid)
  to service_role;
