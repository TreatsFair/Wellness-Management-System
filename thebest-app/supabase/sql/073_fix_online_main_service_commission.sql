-- Credit original online-booking services to the therapist who performs them.
-- Online group receipts historically stored service_id while the commission
-- calculator only understood id/serviceId, leaving the primary receipt at zero.

create or replace function public.csp_commission_for_items(
  p_service_items jsonb,
  p_staff_id uuid,
  p_role text
)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v_overrides jsonb;
  v_is_counter boolean := position('counter' in lower(coalesce(p_role, ''))) > 0
    or position('cashier' in lower(coalesce(p_role, ''))) > 0;
  v_item jsonb;
  v_service_id uuid;
  v_total numeric := 0;
  v_default numeric;
begin
  if p_staff_id is null or p_service_items is null then
    return 0;
  end if;

  select coalesce(service_commissions, '{}'::jsonb)
  into v_overrides
  from public.therapists
  where id = p_staff_id;

  for v_item in
    select value
    from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb))
  loop
    v_service_id := nullif(coalesce(
      v_item ->> 'id',
      v_item ->> 'serviceId',
      v_item ->> 'service_id'
    ), '')::uuid;
    if v_service_id is null then
      continue;
    end if;

    if v_overrides is not null and v_overrides ? v_service_id::text then
      v_total := v_total
        + coalesce((v_overrides ->> v_service_id::text)::numeric, 0);
      continue;
    end if;

    select case
      when v_is_counter then s.counter_commission
      else s.therapist_commission
    end
    into v_default
    from public.services s
    where s.id = v_service_id;

    v_total := v_total + coalesce(v_default, 0);
  end loop;

  return round(v_total, 2);
end;
$$;

-- Store future online group receipts in the same canonical item shape used by
-- counter bookings. Each line keeps its appointment owner so group commission
-- can resolve the correct therapist independently for every pax.
create or replace function public.record_online_booking_group_payment(
  p_token uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_first public.booking_holds%rowtype;
  v_customer public.customers%rowtype;
  v_service_price numeric := 0;
  v_sst numeric := 0;
  v_total numeric := 0;
  v_items jsonb;
  v_count integer;
  v_transaction_id uuid;
begin
  select * into v_first
  from public.booking_holds h
  where h.booking_group_token = p_token
  order by h.guest_index
  limit 1
  for update;

  if not found or v_first.appointment_group_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  v_group_id := v_first.appointment_group_id;

  select
    sum(h.total_amount),
    count(*),
    jsonb_agg(
      coalesce(h.service_items -> 0, '{}'::jsonb)
      || jsonb_strip_nulls(jsonb_build_object(
        'id', a.service_id,
        'name', coalesce(
          nullif(a.service_name, ''),
          nullif(h.service_items -> 0 ->> 'public_name', ''),
          s.name,
          'Service'
        ),
        'appointmentId', h.appointment_id,
        'guestName', h.guest_name,
        'price', h.total_amount,
        'lineType', 'booked',
        'assignedTherapistId', a.therapist_id,
        'assignedTherapistName', therapist.name,
        'assignedRoomId', a.room_id,
        'assignedRoomName', room.name
      ))
      order by h.guest_index
    )
  into v_total, v_count, v_items
  from public.booking_holds h
  join public.appointments a on a.id = h.appointment_id
  left join public.services s on s.id = a.service_id
  left join public.therapists therapist on therapist.id = a.therapist_id
  left join public.rooms room on room.id = a.room_id
  where h.booking_group_token = p_token;

  select b.service_price, b.sst_amount
  into v_service_price, v_sst
  from public.outlet_payment_breakdown(v_first.outlet_id, v_total) b;

  select * into v_customer
  from public.customers c
  where c.id = v_first.customer_id;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_name, service_items, item_count, service_price, sst_amount,
    total_amount, payment_method, payment_status, receipt_number, source,
    created_at
  ) values (
    v_first.outlet_id, v_group_id, v_first.customer_id,
    coalesce(v_customer.name, v_first.customer_name),
    coalesce(v_customer.phone, v_first.customer_phone),
    'Online group booking', v_items, v_count, v_service_price, v_sst, v_total,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_first.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_group_id)
    where appointment_group_id is not null
      and coalesce(source, '') <> 'appointment_addon'
  do update set
    payment_status = 'paid',
    service_name = excluded.service_name,
    service_items = excluded.service_items,
    item_count = excluded.item_count,
    service_price = excluded.service_price,
    sst_amount = excluded.sst_amount,
    total_amount = excluded.total_amount,
    receipt_number = excluded.receipt_number
  returning id into v_transaction_id;

  return v_transaction_id;
end;
$$;

revoke all on function public.record_online_booking_group_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.record_online_booking_group_payment(uuid)
  to service_role;

-- Canonicalize existing online group receipt lines without changing their
-- prices, receipt numbers, payment records, or appointment relationships.
update public.transactions t
set service_items = (
      select jsonb_agg(
        item.value
        || jsonb_strip_nulls(jsonb_build_object(
          'id', coalesce(
            nullif(item.value ->> 'id', ''),
            nullif(item.value ->> 'serviceId', ''),
            nullif(item.value ->> 'service_id', ''),
            a.service_id::text
          ),
          'name', coalesce(
            nullif(item.value ->> 'name', ''),
            nullif(item.value ->> 'public_name', ''),
            nullif(a.service_name, ''),
            s.name,
            'Service'
          ),
          'appointmentId', a.id,
          'lineType', coalesce(
            nullif(item.value ->> 'lineType', ''),
            'booked'
          ),
          'assignedTherapistId', a.therapist_id,
          'assignedTherapistName', therapist.name,
          'assignedRoomId', a.room_id,
          'assignedRoomName', room.name
        ))
        order by item.ordinality
      )
      from jsonb_array_elements(coalesce(t.service_items, '[]'::jsonb))
        with ordinality as item(value, ordinality)
      left join public.appointments a
        on a.id = nullif(coalesce(
          item.value ->> 'appointmentId',
          item.value ->> 'appointment_id'
        ), '')::uuid
      left join public.services s on s.id = a.service_id
      left join public.therapists therapist on therapist.id = a.therapist_id
      left join public.rooms room on room.id = a.room_id
    ),
    updated_at = now()
where t.source = 'online_booking'
  and t.appointment_group_id is not null
  and jsonb_array_length(coalesce(t.service_items, '[]'::jsonb)) > 0;

-- Recalculate allocation and receipt commission whenever service completion
-- becomes real. Payment alone still does not award service commission.
create or replace function public.sync_completed_appointment_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'completed'
      and old.status is distinct from new.status then
    perform public.recalculate_appointment_therapist_commission(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_sync_completed_commission
  on public.appointments;
create trigger appointments_sync_completed_commission
after update of status on public.appointments
for each row
execute function public.sync_completed_appointment_commission();

-- Repair already-completed appointments using the same idempotent calculator.
do $$
declare
  v_appointment record;
begin
  for v_appointment in
    select a.id
    from public.appointments a
    where a.status = 'completed'
      and a.payment_status = 'paid'
  loop
    perform public.recalculate_appointment_therapist_commission(
      v_appointment.id
    );
  end loop;
end;
$$;

revoke all on function public.sync_completed_appointment_commission()
  from public, anon, authenticated;
