-- Two independent fixes:
--
-- 1) Staff booking screen (`get_available_slots`, used by `CspService.getAvailableSlots`)
--    only ever checked resource conflicts (therapist/room overlap) -- it never checked
--    whether a candidate slot had already passed. So at 3:43pm today, 9:00am today still
--    showed up as bookable. The public website's `get_public_booking_slots_v2` already
--    guards against this (it only offers today+1..+7), so this is a staff-app-only gap.
--    Fix: skip any slot whose start time is not strictly in the future, mirroring how
--    the public booking function skips slots inside `minimum_advance_minutes`.
--
-- 2) `confirm_public_booking_hold` matched customers on an exact string equality of
--    `phone`. Online booking customer_phone is free-typed with no normalization, so the
--    same person entering "012 822 0430" one time and "+012 822 0430" or "0128220430"
--    another time produced a *new* duplicate customer row each time instead of matching
--    the existing one -- there was never a "reject duplicate" behavior at all.
--    Fix: add `normalize_my_phone()` (digits-only, leading 0 -> 60 country code) and match
--    on the normalized value. The stored `customers.phone` / `booking_holds.customer_phone`
--    values are left as originally typed (no backfill) -- only the comparison is
--    normalization-aware. Per user decision: on a normalized-phone match, keep the name
--    already on file (do not overwrite it) -- this was already the existing behavior.

create or replace function public.normalize_my_phone(p_phone text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_phone is null or regexp_replace(p_phone, '\D', '', 'g') = '' then null
    when regexp_replace(p_phone, '\D', '', 'g') like '60%' then regexp_replace(p_phone, '\D', '', 'g')
    when regexp_replace(p_phone, '\D', '', 'g') like '0%' then '6' || regexp_replace(p_phone, '\D', '', 'g')
    else '60' || regexp_replace(p_phone, '\D', '', 'g')
  end;
$$;

create or replace function public.get_available_slots(
  p_date date,
  p_therapist_id uuid,
  p_room_id uuid,
  p_duration integer,
  p_exclude_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  classification text,
  score integer,
  reason text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
begin
  if p_duration is null or p_duration <= 0 then
    return;
  end if;

  select coalesce(open_time, '09:00'::time), coalesce(close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings
  where id = 1;

  v_start_at := p_date + v_open;
  v_close_at := p_date
    + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  while v_start_at + make_interval(mins => p_duration) <= v_close_at loop
    v_end_at := v_start_at + make_interval(mins => p_duration);

    if v_start_at <= v_now_local then
      v_start_at := v_start_at + interval '30 minutes';
      continue;
    end if;

    select *
    into v_check
    from public.check_booking_availability(
      p_date,
      v_start_at::time,
      v_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    if not coalesce(v_check.therapist_available, false) then
      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
    elsif coalesce(v_check.room_full, false) then
      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
    else
      v_score := 0;
      v_reason := 'standard_slot';

      if exists (
        select 1
        from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and public.csp_blocks_schedule(a.status::text)
          and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
          and public.csp_appointment_block_end_at(a) = v_start_at
          and (p_exclude_id is null or a.id <> p_exclude_id)
      ) then
        v_score := v_score + 2;
        v_reason := 'minimizes_gap';
      end if;

      if exists (
        select 1
        from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and public.csp_blocks_schedule(a.status::text)
          and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
          and public.csp_appointment_start_at(a) = v_end_at
          and (p_exclude_id is null or a.id <> p_exclude_id)
      ) then
        v_score := v_score + 1;
        if v_reason = 'standard_slot' then
          v_reason := 'minimizes_gap';
        end if;
      end if;

      if v_average_count > 0 and v_therapist_count < v_average_count then
        v_score := v_score + 1;
        if v_reason = 'standard_slot' then
          v_reason := 'balances_workload';
        end if;
      end if;

      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := case when v_score > 0 then 'recommended' else 'standard' end;
      score := v_score;
      reason := v_reason;
      return next;
    end if;

    v_start_at := v_start_at + interval '30 minutes';
  end loop;
end;
$$;

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

  -- Find-or-create a customer in this outlet, matched on normalized phone (so
  -- "012 822 0430" / "+012 822 0430" / "0128220430" all resolve to the same
  -- customer). On a match, the name on file is kept as-is (not overwritten).
  select id into v_customer_id
  from public.customers
  where outlet_id = v_hold.outlet_id
    and public.normalize_my_phone(phone) = public.normalize_my_phone(v_hold.customer_phone)
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
;
