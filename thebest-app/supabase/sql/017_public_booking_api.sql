-- Public website booking support (Supabase phase, before Billplz).
-- All public traffic goes through the booking-api Edge Function. These RPCs
-- are callable only by service_role so browser users cannot bypass validation.

alter table public.booking_holds
  add column if not exists public_token uuid not null default gen_random_uuid(),
  add column if not exists request_fingerprint text not null default '';

create unique index if not exists booking_holds_public_token_uidx
  on public.booking_holds(public_token);

create index if not exists booking_holds_active_resources_idx
  on public.booking_holds(outlet_id, assigned_therapist_id, assigned_room_id, start_at, end_at)
  where status = 'pending_payment';

create index if not exists booking_holds_request_fingerprint_idx
  on public.booking_holds(request_fingerprint, created_at)
  where request_fingerprint <> '';

create or replace function public.expire_stale_booking_holds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.booking_holds
  set status = 'expired', updated_at = now()
  where status = 'pending_payment'
    and expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.expire_stale_booking_holds() from public, anon, authenticated;
grant execute on function public.expire_stale_booking_holds() to service_role;

create or replace function public.get_public_booking_slots(
  p_outlet_id uuid,
  p_service_ids uuid[],
  p_date date,
  p_therapist_preference text default 'none'
)
returns table (
  start_at timestamptz,
  end_at timestamptz,
  available_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open_time time;
  v_close_time time;
  v_duration integer;
  v_required_room_type text;
  v_room_type_count integer;
  v_open_at timestamptz;
  v_close_at timestamptz;
  v_slot timestamptz;
  v_slot_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_therapist_count integer;
  v_room_capacity integer;
  v_preference text := lower(coalesce(p_therapist_preference, 'none'));
begin
  if p_date < (now() at time zone 'Asia/Kuala_Lumpur')::date
     or p_date > (now() at time zone 'Asia/Kuala_Lumpur')::date + 60 then
    return;
  end if;

  if p_service_ids is null or cardinality(p_service_ids) = 0 then
    return;
  end if;

  select sum(greatest(coalesce(s.duration, 0), 1))::integer,
         min(nullif(lower(coalesce(s.room_type::text, '')), '')),
         count(distinct nullif(lower(coalesce(s.room_type::text, '')), ''))::integer
  into v_duration, v_required_room_type, v_room_type_count
  from public.services s
  where s.outlet_id = p_outlet_id
    and s.id = any(p_service_ids)
    and coalesce(s.is_active, true);

  if v_duration is null or v_room_type_count > 1 or (
    select count(distinct s.id)
    from public.services s
    where s.outlet_id = p_outlet_id
      and s.id = any(p_service_ids)
      and coalesce(s.is_active, true)
  ) <> cardinality(p_service_ids) then
    return;
  end if;

  select bs.open_time, bs.close_time
  into v_open_time, v_close_time
  from public.business_settings bs
  where bs.outlet_id = p_outlet_id;

  if v_open_time is null or v_close_time is null then return; end if;

  v_open_at := (p_date + v_open_time) at time zone 'Asia/Kuala_Lumpur';
  v_close_at := (p_date + v_close_time) at time zone 'Asia/Kuala_Lumpur';
  if v_close_time <= v_open_time then
    v_close_at := v_close_at + interval '1 day';
  end if;

  v_slot := v_open_at;
  while v_slot + make_interval(mins => v_duration) <= v_close_at loop
    v_slot_end := v_slot + make_interval(mins => v_duration);
    v_local_start := v_slot at time zone 'Asia/Kuala_Lumpur';
    v_local_end := v_slot_end at time zone 'Asia/Kuala_Lumpur';

    select count(*)::integer
    into v_therapist_count
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.is_active, true)
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
      and (
        v_preference not in ('female', 'male')
        or lower(coalesce(t.gender, '')) = v_preference
      )
      and (
        coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb
        or not exists (
          select 1
          from unnest(p_service_ids) requested_service(id)
          where not (t.service_commissions ? requested_service.id::text)
        )
      )
      and not exists (
        select 1 from public.appointments a
        where a.outlet_id = p_outlet_id
          and a.therapist_id = t.id
          and lower(coalesce(a.status::text, '')) in ('confirmed', 'in_progress')
          and public.csp_appointment_start_at(a) < v_local_end
          and public.csp_appointment_end_at(a) > v_local_start
      )
      and not exists (
        select 1 from public.booking_holds h
        where h.outlet_id = p_outlet_id
          and h.assigned_therapist_id = t.id
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and h.start_at < v_slot_end
          and h.end_at > v_slot
      );

    select coalesce(sum(greatest(
      coalesce(r.total_slots, 1)
      - (
          select count(*)::integer from public.appointments a
          where a.outlet_id = p_outlet_id
            and a.room_id = r.id
            and lower(coalesce(a.status::text, '')) in ('confirmed', 'in_progress')
            and public.csp_appointment_start_at(a) < v_local_end
            and public.csp_appointment_end_at(a) > v_local_start
        )
      - (
          select count(*)::integer from public.booking_holds h
          where h.outlet_id = p_outlet_id
            and h.assigned_room_id = r.id
            and h.status = 'pending_payment'
            and h.expires_at > now()
            and h.start_at < v_slot_end
            and h.end_at > v_slot
        ),
      0
    )), 0)::integer
    into v_room_capacity
    from public.rooms r
    where r.outlet_id = p_outlet_id
      and coalesce(r.is_active, true)
      and (
        v_required_room_type is null
        or lower(coalesce(r.room_type::text, r.type::text, '')) = v_required_room_type
      );

    if least(v_therapist_count, v_room_capacity) > 0 then
      start_at := v_slot;
      end_at := v_slot_end;
      available_count := least(v_therapist_count, v_room_capacity);
      return next;
    end if;

    v_slot := v_slot + interval '30 minutes';
  end loop;
end;
$$;

revoke all on function public.get_public_booking_slots(uuid, uuid[], date, text)
  from public, anon, authenticated;
grant execute on function public.get_public_booking_slots(uuid, uuid[], date, text)
  to service_role;

-- Remove the pre-rate-limit development signature if this migration is rerun.
drop function if exists public.create_public_booking_hold(
  uuid, uuid[], timestamptz, text, text, text, text, text, text
);

create or replace function public.create_public_booking_hold(
  p_outlet_id uuid,
  p_service_ids uuid[],
  p_start_at timestamptz,
  p_therapist_preference text,
  p_therapist_request text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_notes text default '',
  p_request_fingerprint text default ''
)
returns table (
  hold_id uuid,
  hold_token uuid,
  hold_expires_at timestamptz,
  amount numeric,
  duration_minutes integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_preference text := lower(coalesce(p_therapist_preference, 'none'));
  v_duration integer;
  v_total numeric(12,2);
  v_room_type text;
  v_room_type_count integer;
  v_end_at timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_open_time time;
  v_close_time time;
  v_open_local timestamp;
  v_close_local timestamp;
  v_therapist_id uuid;
  v_room_id uuid;
  v_items jsonb;
begin
  if p_service_ids is null or cardinality(p_service_ids) = 0 then
    raise exception 'At least one treatment is required';
  end if;
  if cardinality(p_service_ids) > 8 then
    raise exception 'Too many treatments selected';
  end if;
  if v_preference not in ('none', 'female', 'male', 'specific') then
    raise exception 'Invalid therapist preference';
  end if;
  if length(trim(coalesce(p_customer_name, ''))) < 2
     or length(trim(coalesce(p_customer_phone, ''))) < 8
     or position('@' in coalesce(p_customer_email, '')) < 2 then
    raise exception 'Valid customer details are required';
  end if;
  if p_start_at <= now() or p_start_at > now() + interval '60 days' then
    raise exception 'Invalid booking time';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || '|' || p_start_at::text, 0)
  );
  perform public.expire_stale_booking_holds();

  if trim(coalesce(p_request_fingerprint, '')) <> '' and (
    select count(*)
    from public.booking_holds h
    where h.request_fingerprint = trim(p_request_fingerprint)
      and h.created_at > now() - interval '1 hour'
  ) >= 12 then
    raise exception 'Too many booking attempts. Please try again later';
  end if;

  select sum(greatest(coalesce(s.duration, 0), 1))::integer,
         sum(greatest(coalesce(s.price, 0), 0))::numeric(12,2),
         min(nullif(lower(coalesce(s.room_type::text, '')), '')),
         count(distinct nullif(lower(coalesce(s.room_type::text, '')), ''))::integer,
         jsonb_agg(
           jsonb_build_object(
             'id', s.id,
             'name', s.name,
             'duration', s.duration,
             'price', s.price,
             'room_type', s.room_type
           ) order by array_position(p_service_ids, s.id)
         )
  into v_duration, v_total, v_room_type, v_room_type_count, v_items
  from public.services s
  where s.outlet_id = p_outlet_id
    and s.id = any(p_service_ids)
    and coalesce(s.is_active, true);

  if v_duration is null or (
    select count(distinct s.id)
    from public.services s
    where s.outlet_id = p_outlet_id
      and s.id = any(p_service_ids)
      and coalesce(s.is_active, true)
  ) <> cardinality(p_service_ids) then
    raise exception 'One or more treatments are unavailable';
  end if;
  if v_room_type_count > 1 then
    raise exception 'Selected treatments require different room types. Please book them separately';
  end if;

  v_end_at := p_start_at + make_interval(mins => v_duration);
  v_local_start := p_start_at at time zone 'Asia/Kuala_Lumpur';
  v_local_end := v_end_at at time zone 'Asia/Kuala_Lumpur';

  select bs.open_time, bs.close_time
  into v_open_time, v_close_time
  from public.business_settings bs
  where bs.outlet_id = p_outlet_id;
  if v_open_time is null or v_close_time is null then
    raise exception 'Outlet business hours are unavailable';
  end if;
  v_open_local := v_local_start::date + v_open_time;
  v_close_local := v_local_start::date + v_close_time;
  if v_close_time <= v_open_time then v_close_local := v_close_local + interval '1 day'; end if;
  if v_local_start < v_open_local or v_local_end > v_close_local
     or extract(minute from v_local_start)::integer % 30 <> 0
     or extract(second from v_local_start)::integer <> 0 then
    raise exception 'Booking time is outside the available schedule';
  end if;

  select t.id
  into v_therapist_id
  from public.therapists t
  where t.outlet_id = p_outlet_id
    and coalesce(t.is_active, true)
    and coalesce(t.availability_status, true)
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
    and (
      v_preference not in ('female', 'male')
      or lower(coalesce(t.gender, '')) = v_preference
    )
    and (
      coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb
      or not exists (
        select 1 from unnest(p_service_ids) requested_service(id)
        where not (t.service_commissions ? requested_service.id::text)
      )
    )
    and not exists (
      select 1 from public.appointments a
      where a.outlet_id = p_outlet_id
        and a.therapist_id = t.id
        and lower(coalesce(a.status::text, '')) in ('confirmed', 'in_progress')
        and public.csp_appointment_start_at(a) < v_local_end
        and public.csp_appointment_end_at(a) > v_local_start
    )
    and not exists (
      select 1 from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.assigned_therapist_id = t.id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and h.start_at < v_end_at
        and h.end_at > p_start_at
    )
  order by t.name
  for update of t skip locked
  limit 1;

  if v_therapist_id is null then
    raise exception 'The selected time is no longer available';
  end if;

  select r.id
  into v_room_id
  from public.rooms r
  where r.outlet_id = p_outlet_id
    and coalesce(r.is_active, true)
    and (
      v_room_type is null
      or lower(coalesce(r.room_type::text, r.type::text, '')) = v_room_type
    )
    and coalesce(r.total_slots, 1) > (
      select count(*) from public.appointments a
      where a.outlet_id = p_outlet_id
        and a.room_id = r.id
        and lower(coalesce(a.status::text, '')) in ('confirmed', 'in_progress')
        and public.csp_appointment_start_at(a) < v_local_end
        and public.csp_appointment_end_at(a) > v_local_start
    ) + (
      select count(*) from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.assigned_room_id = r.id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and h.start_at < v_end_at
        and h.end_at > p_start_at
    )
  order by r.name
  for update of r skip locked
  limit 1;

  if v_room_id is null then
    raise exception 'The selected time is no longer available';
  end if;

  insert into public.booking_holds (
    outlet_id,
    customer_name,
    customer_phone,
    customer_email,
    therapist_preference,
    therapist_request,
    assigned_therapist_id,
    assigned_room_id,
    service_items,
    start_at,
    end_at,
    total_amount,
    status,
    expires_at,
    notes,
    request_fingerprint
  ) values (
    p_outlet_id,
    trim(p_customer_name),
    trim(p_customer_phone),
    lower(trim(p_customer_email)),
    v_preference,
    left(trim(coalesce(p_therapist_request, '')), 200),
    v_therapist_id,
    v_room_id,
    v_items,
    p_start_at,
    v_end_at,
    v_total,
    'pending_payment',
    now() + interval '15 minutes',
    left(trim(coalesce(p_notes, '')), 500),
    left(trim(coalesce(p_request_fingerprint, '')), 128)
  )
  returning booking_holds.id,
            booking_holds.public_token,
            booking_holds.expires_at,
            booking_holds.total_amount
  into hold_id, hold_token, hold_expires_at, amount;

  duration_minutes := v_duration;
  return next;
end;
$$;

revoke all on function public.create_public_booking_hold(
  uuid, uuid[], timestamptz, text, text, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.create_public_booking_hold(
  uuid, uuid[], timestamptz, text, text, text, text, text, text, text
) to service_role;
