-- Remove superseded public-booking RPCs and repair live staff RPCs against the
-- current therapists/appointments schema.

drop function if exists public.get_public_booking_slots(uuid, uuid[], date, text);
drop function if exists public.create_public_booking_hold(
  uuid, uuid[], timestamptz, text, text, text, text, text, text, text
);

create or replace function public.check_walkin_availability(
  p_today date,
  p_now_time time,
  p_duration integer,
  p_room_id uuid
)
returns table (
  therapists jsonb,
  zone_available_now boolean,
  zone_free_slots integer,
  can_start_now boolean,
  next_available_time time
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
  v_outlet_id uuid;
  v_room_total integer := 1;
  v_room_booked integer := 0;
  v_room_free_at timestamp;
  v_therapist_free_at time;
begin
  select r.outlet_id, greatest(coalesce(r.total_slots, 1), 1)
  into v_outlet_id, v_room_total
  from public.rooms r
  where r.id = p_room_id;

  if v_outlet_id is null then
    therapists := '[]'::jsonb;
    zone_available_now := false;
    zone_free_slots := 0;
    can_start_now := false;
    next_available_time := null;
    return next;
    return;
  end if;

  select count(*)::integer, max(conflict_end)
  into v_room_booked, v_room_free_at
  from (
    select public.csp_appointment_block_end_at(a) as conflict_end
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.room_id = p_room_id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_block_end_at(a) > v_start_at
    union all
    select (h.end_at + make_interval(
      mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
    )) at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    where h.assigned_room_id = p_room_id
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
      and ((h.end_at + make_interval(
        mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
      )) at time zone 'Asia/Kuala_Lumpur') > v_start_at
  ) room_conflicts;

  zone_free_slots := greatest(v_room_total - coalesce(v_room_booked, 0), 0);
  zone_available_now := zone_free_slots > 0;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'therapist_id', availability.therapist_id,
      'name', availability.therapist_name,
      'status', availability.status,
      'free_at', availability.free_at::time,
      'free_in_minutes', case
        when availability.free_at is null then 0
        else greatest(
          ceil(extract(epoch from (availability.free_at - v_start_at)) / 60)::integer,
          0
        )
      end
    )
    order by availability.status_order,
      availability.free_at nulls first,
      availability.therapist_name
  ), '[]'::jsonb), min(availability.free_at::time)
  into therapists, v_therapist_free_at
  from (
    select t.id as therapist_id,
      t.name as therapist_name,
      case
        when conflicts.leave_end is not null then 'on_leave'
        when conflicts.free_at is null then 'free_now'
        else 'busy'
      end as status,
      case
        when conflicts.leave_end is not null then conflicts.leave_end
        else conflicts.free_at
      end as free_at,
      case
        when conflicts.leave_end is not null then 2
        when conflicts.free_at is null then 0
        else 1
      end as status_order
    from public.therapists t
    left join lateral (
      select max(c.conflict_end) as free_at,
        max(c.conflict_end) filter (where c.conflict_kind = 'leave') as leave_end
      from (
        select public.csp_appointment_block_end_at(a) as conflict_end,
          'appointment'::text as conflict_kind
        from public.appointments a
        where a.appointment_date::date between p_today - 1 and p_today + 1
          and a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_end_at
          and public.csp_appointment_block_end_at(a) > v_start_at
        union all
        select u.ends_at at time zone 'Asia/Kuala_Lumpur', 'leave'
        from public.therapist_unavailability u
        where u.therapist_id = t.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
          and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
        union all
        select (h.end_at + make_interval(
          mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
        )) at time zone 'Asia/Kuala_Lumpur', 'hold'
        from public.booking_holds h
        where h.assigned_therapist_id = t.id
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
          and ((h.end_at + make_interval(
            mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
          )) at time zone 'Asia/Kuala_Lumpur') > v_start_at
      ) c
    ) conflicts on true
    where t.outlet_id = v_outlet_id
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
  ) availability;

  can_start_now := zone_available_now and exists (
    select 1
    from jsonb_array_elements(therapists) item
    where item ->> 'status' = 'free_now'
  );
  next_available_time := case
    when can_start_now then p_now_time
    when v_room_free_at is null then v_therapist_free_at
    when v_therapist_free_at is null then v_room_free_at::time
    else greatest(v_room_free_at::time, v_therapist_free_at)
  end;
  return next;
end;
$$;

revoke all on function public.check_walkin_availability(date, time, integer, uuid)
  from public, anon;
grant execute on function public.check_walkin_availability(date, time, integer, uuid)
  to authenticated;

create or replace function public.create_walkin_appointment_group_with_payment(
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
  p_created_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
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
  v_alloc jsonb;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_outlet_id uuid;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_transaction_id uuid;
  v_idx integer := 0;
  v_appointment_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_create
  from public.create_appointment_group_with_csp(
    p_customer_id => p_customer_id,
    p_group_name => p_group_name,
    p_pax_count => p_pax_count,
    p_appointment_date => p_appointment_date,
    p_allocations => p_allocations,
    p_type => 'walkin',
    p_status => 'in_progress',
    p_notes => p_notes,
    p_created_by => p_created_by
  );

  if not coalesce(v_create.success, false) then
    success := false;
    appointment_group_id := null;
    appointment_ids := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  update public.appointments a
  set actual_started_at = now(), updated_at = now()
  where a.appointment_group_id = v_create.appointment_group_id;

  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    v_idx := v_idx + 1;
    v_all_items := v_all_items || coalesce(v_alloc -> 'service_items', '[]'::jsonb);
    v_item_count := v_item_count
      + jsonb_array_length(coalesce(v_alloc -> 'service_items', '[]'::jsonb));
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_alloc -> 'service_items',
          nullif(v_alloc ->> 'therapist_id', '')::uuid,
          'Therapist'
        );
    if v_idx = 1 then
      v_first_therapist_id := nullif(v_alloc ->> 'therapist_id', '')::uuid;
      v_first_room_id := nullif(v_alloc ->> 'room_id', '')::uuid;
      v_first_service_id := nullif(v_alloc ->> 'service_id', '')::uuid;
      v_first_service_name := v_alloc ->> 'service_name';
    end if;
  end loop;

  select t.name into v_first_therapist_name
  from public.therapists t where t.id = v_first_therapist_id;
  select r.name into v_first_room_name
  from public.rooms r where r.id = v_first_room_id;
  select a.outlet_id into v_outlet_id
  from public.appointments a
  where a.appointment_group_id = v_create.appointment_group_id
  limit 1;

  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_outlet_id, v_create.appointment_group_id, p_customer_id,
    coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items,
    greatest(v_item_count, 1), v_first_therapist_id,
    coalesce(v_first_therapist_name, ''), p_counter_staff_id,
    p_counter_staff_name, v_first_room_id, coalesce(v_first_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
    coalesce(p_total_amount, 0), v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    coalesce(p_transaction_notes, '')
  ) returning id into v_transaction_id;

  foreach v_appointment_id in array v_create.appointment_ids loop
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    )
    select a.id, a.therapist_id, 1, 'full', p_created_by
    from public.appointments a where a.id = v_appointment_id
    on conflict (appointment_id, therapist_id) do update
      set commission_share = 1, allocation_method = 'full', updated_at = now();
    perform public.recalculate_appointment_therapist_commission(v_appointment_id);
  end loop;

  success := true;
  appointment_group_id := v_create.appointment_group_id;
  appointment_ids := v_create.appointment_ids;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

revoke all on function public.create_walkin_appointment_group_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text,
  numeric, numeric, numeric, text, text, text, uuid
) from public, anon;
grant execute on function public.create_walkin_appointment_group_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text,
  numeric, numeric, numeric, text, text, text, uuid
) to authenticated;

create or replace function public.create_staff_walkin_group_with_payment(
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
  p_start_immediately boolean default true,
  p_draft_session_id text default null,
  p_created_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
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
  v_alloc jsonb;
  v_therapist_text text;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_outlet_id uuid;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_transaction_id uuid;
  v_idx integer := 0;
  v_appointment_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  for v_therapist_text in
    select distinct value ->> 'therapist_id'
    from jsonb_array_elements(p_allocations)
    order by value ->> 'therapist_id'
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_therapist_text, 0));
  end loop;
  for v_therapist_text in
    select distinct 'room:' || (value ->> 'room_id')
    from jsonb_array_elements(p_allocations)
    order by 'room:' || (value ->> 'room_id')
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_therapist_text, 0));
  end loop;

  if p_draft_session_id is not null then
    update public.booking_holds h
    set status = 'cancelled', updated_at = now()
    where h.hold_kind = 'staff_walkin_draft'
      and h.draft_session_id = p_draft_session_id
      and h.status = 'pending_payment';
  end if;

  if p_start_immediately then
    select * into v_existing
    from public.create_walkin_appointment_group_with_payment(
      p_customer_id, p_group_name, p_pax_count, p_appointment_date, p_allocations,
      p_notes, p_customer_name, p_customer_phone, p_counter_staff_id,
      p_counter_staff_name, p_service_price, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes, p_created_by
    );
    success := v_existing.success;
    appointment_group_id := v_existing.appointment_group_id;
    appointment_ids := v_existing.appointment_ids;
    transaction_id := v_existing.transaction_id;
    error_code := v_existing.error_code;
    error_message := v_existing.error_message;
    return next;
    return;
  end if;

  perform set_config('app.ignore_cleanup_buffer', 'on', true);
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  select * into v_create
  from public.create_appointment_group_with_csp(
    p_customer_id => p_customer_id,
    p_group_name => p_group_name,
    p_pax_count => p_pax_count,
    p_appointment_date => p_appointment_date,
    p_allocations => p_allocations,
    p_type => 'walkin',
    p_status => 'confirmed',
    p_notes => p_notes,
    p_created_by => p_created_by
  );
  if not coalesce(v_create.success, false) then
    success := false;
    appointment_group_id := null;
    appointment_ids := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    v_idx := v_idx + 1;
    v_all_items := v_all_items || coalesce(v_alloc -> 'service_items', '[]'::jsonb);
    v_item_count := v_item_count
      + jsonb_array_length(coalesce(v_alloc -> 'service_items', '[]'::jsonb));
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_alloc -> 'service_items',
          nullif(v_alloc ->> 'therapist_id', '')::uuid,
          'Therapist'
        );
    if v_idx = 1 then
      v_first_therapist_id := nullif(v_alloc ->> 'therapist_id', '')::uuid;
      v_first_room_id := nullif(v_alloc ->> 'room_id', '')::uuid;
      v_first_service_id := nullif(v_alloc ->> 'service_id', '')::uuid;
      v_first_service_name := v_alloc ->> 'service_name';
    end if;
  end loop;

  select t.name into v_first_therapist_name
  from public.therapists t where t.id = v_first_therapist_id;
  select r.name into v_first_room_name
  from public.rooms r where r.id = v_first_room_id;
  select a.outlet_id into v_outlet_id
  from public.appointments a
  where a.appointment_group_id = v_create.appointment_group_id
  limit 1;
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_outlet_id, v_create.appointment_group_id, p_customer_id,
    coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items,
    greatest(v_item_count, 1), v_first_therapist_id,
    coalesce(v_first_therapist_name, ''), p_counter_staff_id,
    p_counter_staff_name, v_first_room_id, coalesce(v_first_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
    coalesce(p_total_amount, 0), v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    coalesce(p_transaction_notes, '')
  ) returning id into v_transaction_id;

  foreach v_appointment_id in array v_create.appointment_ids loop
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    )
    select a.id, a.therapist_id, 1, 'full', p_created_by
    from public.appointments a where a.id = v_appointment_id
    on conflict (appointment_id, therapist_id) do update
      set commission_share = 1, allocation_method = 'full', updated_at = now();
    perform public.recalculate_appointment_therapist_commission(v_appointment_id);
  end loop;

  success := true;
  appointment_group_id := v_create.appointment_group_id;
  appointment_ids := v_create.appointment_ids;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

revoke all on function public.create_staff_walkin_group_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text,
  numeric, numeric, numeric, text, text, text, boolean, text, uuid
) from public, anon;
grant execute on function public.create_staff_walkin_group_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text,
  numeric, numeric, numeric, text, text, text, boolean, text, uuid
) to authenticated;
