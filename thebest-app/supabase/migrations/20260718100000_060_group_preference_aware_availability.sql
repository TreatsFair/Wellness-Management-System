-- Group availability previously intersected each guest's individual slots, so
-- two guests who both prefer a female therapist could be offered a time when
-- only ONE female therapist was free — each guest alone saw an available slot,
-- and the failure only surfaced as an exception at group hold creation (shown
-- to the customer as a generic 500 after they had filled in billing).
--
-- These functions make group dates/times honour the combined demand:
--   * get_public_booking_group_slots_v1 intersects per-guest slots, then
--     simulates the same greedy therapist/room assignment that
--     create_public_booking_hold_v2 performs, so a time is only offered when
--     every guest can actually be seated together.
--   * A cheap outlet-level pre-check (e.g. 2 female-preference guests but only
--     1 female therapist employed) fails instantly, so infeasible groups see
--     "no dates available" immediately at the date step.
--   * create_public_booking_group_hold_v1 now seats gender-preference guests
--     first (keeping each guest's original index/name), so a "no preference"
--     guest never takes the last matching therapist from a guest who needs it.

create or replace function public.get_public_booking_group_slots_v1(
  p_allocations jsonb,
  p_date date
)
returns table (start_at timestamptz, end_at timestamptz)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_count integer := jsonb_array_length(coalesce(p_allocations, '[]'::jsonb));
  v_outlet uuid;
  v_distinct_outlets integer;
  v_female_needed integer;
  v_male_needed integer;
  v_female_avail integer;
  v_male_avail integer;
  v_total_avail integer;
  v_guest record;
  v_cand record;
  v_sets jsonb := '[]'::jsonb;
  v_one jsonb;
  v_taken uuid[];
  v_rooms_taken uuid[];
  v_therapist uuid;
  v_room uuid;
  v_ok boolean;
  v_guest_end timestamptz;
  v_bs timestamptz;
  v_be timestamptz;
  v_cat record;
  v_remaining integer;
begin
  if jsonb_typeof(p_allocations) <> 'array' or v_count < 1 or v_count > 6 then return; end if;

  select count(distinct c.outlet_id), min(c.outlet_id::text)::uuid
  into v_distinct_outlets, v_outlet
  from jsonb_array_elements(p_allocations) a
  join public.online_booking_services c on c.id = (a.value->>'catalogue_id')::uuid;
  if v_distinct_outlets is distinct from 1 then return; end if;

  -- Fast infeasibility check: the outlet must employ at least as many active
  -- therapists of each preferred gender as there are guests preferring it.
  select count(*) filter (where lower(coalesce(t.gender, '')) = 'female'),
         count(*) filter (where lower(coalesce(t.gender, '')) = 'male'),
         count(*)
  into v_female_avail, v_male_avail, v_total_avail
  from public.therapists t
  where t.outlet_id = v_outlet
    and coalesce(t.availability_status, true)
    and lower(coalesce(t.role, 'therapist')) = 'therapist';

  select count(*) filter (where lower(coalesce(a.value->>'therapist_preference', 'none')) = 'female'),
         count(*) filter (where lower(coalesce(a.value->>'therapist_preference', 'none')) = 'male')
  into v_female_needed, v_male_needed
  from jsonb_array_elements(p_allocations) a;

  if v_female_avail < v_female_needed
     or v_male_avail < v_male_needed
     or v_total_avail < v_count then return; end if;

  -- Candidate times: every guest must individually have the slot.
  for v_guest in
    select (a.value->>'catalogue_id')::uuid as catalogue_id,
           lower(coalesce(a.value->>'therapist_preference', 'none')) as pref
    from jsonb_array_elements(p_allocations) a
  loop
    select coalesce(jsonb_agg(jsonb_build_object('s', s.start_at, 'e', s.end_at)), '[]'::jsonb)
    into v_one
    from public.get_public_booking_slots_v2(v_guest.catalogue_id, p_date, v_guest.pref) s;
    if v_one = '[]'::jsonb then return; end if;
    v_sets := v_sets || jsonb_build_array(v_one);
  end loop;

  for v_cand in
    select (slot->>'s')::timestamptz as cand_start,
           max((slot->>'e')::timestamptz) as cand_end
    from jsonb_array_elements(v_sets) with ordinality gs(guest_set, gi)
    cross join jsonb_array_elements(gs.guest_set) slot
    group by slot->>'s'
    having count(distinct gs.gi) = v_count
    order by 1
  loop
    if v_count = 1 then
      start_at := v_cand.cand_start;
      end_at := v_cand.cand_end;
      return next;
      continue;
    end if;

    -- Simulate the exact greedy assignment hold creation performs: gendered
    -- preferences first, then original order; each guest takes the first
    -- eligible therapist by name and the first room with a free slot.
    v_taken := '{}'::uuid[];
    v_rooms_taken := '{}'::uuid[];
    v_ok := true;

    for v_guest in
      select c.id as cfg_id, c.outlet_id, c.service_id, c.buffer_before_minutes, c.buffer_after_minutes,
             greatest(s.duration, 1) as duration,
             lower(coalesce(a.value->>'therapist_preference', 'none')) as pref
      from jsonb_array_elements(p_allocations) with ordinality a
      join public.online_booking_services c on c.id = (a.value->>'catalogue_id')::uuid
      join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
      order by (lower(coalesce(a.value->>'therapist_preference', 'none')) = 'none'), a.ordinality
    loop
      v_guest_end := v_cand.cand_start + make_interval(mins => v_guest.duration);
      v_bs := v_cand.cand_start - make_interval(mins => v_guest.buffer_before_minutes);
      v_be := v_guest_end + make_interval(mins => v_guest.buffer_after_minutes);

      select t.id into v_therapist from public.therapists t
      where t.outlet_id = v_guest.outlet_id
        and coalesce(t.availability_status, true)
        and lower(coalesce(t.role, 'therapist')) = 'therapist'
        and (v_guest.pref = 'none' or lower(coalesce(t.gender, '')) = v_guest.pref)
        and (coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb
             or t.service_commissions ? v_guest.service_id::text)
        and t.id <> all(v_taken)
        and exists (
          select 1 from public.therapist_working_hours wh
          where wh.therapist_id = t.id
            and wh.day_of_week = extract(dow from p_date)::integer
            and p_date + wh.start_time <= (v_bs at time zone 'Asia/Kuala_Lumpur')
            and p_date + wh.end_time >= (v_be at time zone 'Asia/Kuala_Lumpur')
        )
        and not exists (
          select 1 from public.therapist_unavailability u
          where u.therapist_id = t.id and u.starts_at < v_be and u.ends_at > v_bs
        )
        and not exists (
          select 1 from public.appointments ap
          where ap.therapist_id = t.id and public.csp_blocks_schedule(ap.status::text)
            and public.csp_appointment_start_at(ap) < (v_be at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_end_at(ap) > (v_bs at time zone 'Asia/Kuala_Lumpur')
        )
        and not exists (
          select 1 from public.booking_holds h
          where h.assigned_therapist_id = t.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes) < v_be
            and h.end_at + make_interval(mins => h.buffer_after_minutes) > v_bs
        )
      order by t.name limit 1;

      if v_therapist is null then v_ok := false; exit; end if;
      v_taken := array_append(v_taken, v_therapist);

      select r.id into v_room
      from public.rooms r
      join public.online_booking_service_rooms cr on cr.room_id = r.id
      where cr.online_booking_service_id = v_guest.cfg_id
        and coalesce(r.is_active, true)
        and coalesce(r.total_slots, 1) >
          (select count(*) from public.appointments ap
           where ap.room_id = r.id and public.csp_blocks_schedule(ap.status::text)
             and public.csp_appointment_start_at(ap) < (v_be at time zone 'Asia/Kuala_Lumpur')
             and public.csp_appointment_end_at(ap) > (v_bs at time zone 'Asia/Kuala_Lumpur'))
          + (select count(*) from public.booking_holds h
             where h.assigned_room_id = r.id
               and h.status = 'pending_payment' and h.expires_at > now()
               and h.start_at - make_interval(mins => h.buffer_before_minutes) < v_be
               and h.end_at + make_interval(mins => h.buffer_after_minutes) > v_bs)
          + (select count(*) from unnest(v_rooms_taken) taken_room where taken_room = r.id)
      order by r.name limit 1;

      if v_room is null then v_ok := false; exit; end if;
      v_rooms_taken := array_append(v_rooms_taken, v_room);
    end loop;

    -- Per-catalogue public concurrency cap must cover every guest on it.
    if v_ok then
      for v_cat in
        select c.id as cfg_id, c.maximum_concurrent_bookings,
               c.buffer_before_minutes, c.buffer_after_minutes,
               greatest(s.duration, 1) as duration,
               count(*)::integer as guests_on_it
        from jsonb_array_elements(p_allocations) a
        join public.online_booking_services c on c.id = (a.value->>'catalogue_id')::uuid
        join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
        group by c.id, c.maximum_concurrent_bookings, c.buffer_before_minutes,
                 c.buffer_after_minutes, s.duration
      loop
        v_guest_end := v_cand.cand_start + make_interval(mins => v_cat.duration);
        v_bs := v_cand.cand_start - make_interval(mins => v_cat.buffer_before_minutes);
        v_be := v_guest_end + make_interval(mins => v_cat.buffer_after_minutes);
        select v_cat.maximum_concurrent_bookings
          - (select count(*) from public.booking_holds h
             where h.online_booking_service_id = v_cat.cfg_id
               and h.status = 'pending_payment' and h.expires_at > now()
               and h.start_at - make_interval(mins => h.buffer_before_minutes) < v_be
               and h.end_at + make_interval(mins => h.buffer_after_minutes) > v_bs)
          - (select count(*) from public.appointments ap
             where ap.online_booking_service_id = v_cat.cfg_id
               and public.csp_blocks_schedule(ap.status::text)
               and public.csp_appointment_start_at(ap) < (v_be at time zone 'Asia/Kuala_Lumpur')
               and public.csp_appointment_block_end_at(ap) > (v_bs at time zone 'Asia/Kuala_Lumpur'))
        into v_remaining;
        if coalesce(v_remaining, 0) < v_cat.guests_on_it then v_ok := false; exit; end if;
      end loop;
    end if;

    if v_ok then
      start_at := v_cand.cand_start;
      end_at := v_cand.cand_end;
      return next;
    end if;
  end loop;
end;
$$;

create or replace function public.get_public_booking_group_dates_v1(p_allocations jsonb)
returns table (booking_date date, available boolean)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_maximum_days integer;
begin
  if jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) < 1
     or jsonb_array_length(p_allocations) > 6 then return; end if;

  select greatest(coalesce(s.maximum_booking_days, 7), 1)
  into v_maximum_days
  from public.online_booking_services c
  join public.online_booking_outlet_settings s on s.outlet_id = c.outlet_id
  where c.id = (p_allocations->0->>'catalogue_id')::uuid;
  if v_maximum_days is null then return; end if;

  for i in 1..v_maximum_days loop
    booking_date := v_today + i;
    available := exists(
      select 1 from public.get_public_booking_group_slots_v1(p_allocations, v_today + i)
    );
    return next;
  end loop;
end;
$$;

-- Seat gendered preferences before "no preference" guests so the greedy
-- assignment cannot give the last matching therapist to a guest who doesn't
-- need one. Guest index/name keep their original positions.
create or replace function public.create_public_booking_group_hold_v1(
  p_allocations jsonb,
  p_start_at timestamptz,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_notes text default '',
  p_request_fingerprint text default ''
)
returns table (
  group_token uuid,
  hold_expires_at timestamptz,
  total_price numeric,
  guest_count integer
)
language plpgsql security definer set search_path = public as $$
declare
  v_group_token uuid := gen_random_uuid();
  v_item record;
  v_hold record;
  v_total numeric := 0;
  v_expiry timestamptz;
  v_count integer := jsonb_array_length(coalesce(p_allocations, '[]'::jsonb));
begin
  if jsonb_typeof(p_allocations) <> 'array' or v_count < 1 or v_count > 6 then
    raise exception 'A group must contain between 1 and 6 guests';
  end if;

  for v_item in
    select a.value, a.ordinality
    from jsonb_array_elements(p_allocations) with ordinality a
    order by (lower(coalesce(a.value->>'therapist_preference', 'none')) = 'none'), a.ordinality
  loop
    select * into v_hold
    from public.create_public_booking_hold_v2(
      (v_item.value->>'catalogue_id')::uuid,
      p_start_at,
      coalesce(v_item.value->>'therapist_preference', 'none'),
      p_customer_name,
      p_customer_phone,
      p_customer_email,
      coalesce(v_item.value->>'therapist_request', ''),
      p_notes,
      p_request_fingerprint
    );

    update public.booking_holds
    set booking_group_token = v_group_token,
        guest_index = v_item.ordinality,
        guest_name = left(coalesce(nullif(trim(v_item.value->>'guest_name'), ''),
          'Guest ' || v_item.ordinality), 80),
        updated_at = now()
    where id = v_hold.hold_id;

    v_total := v_total + v_hold.total_price;
    v_expiry := case when v_expiry is null then v_hold.hold_expires_at
      else least(v_expiry, v_hold.hold_expires_at) end;
  end loop;

  group_token := v_group_token;
  hold_expires_at := v_expiry;
  total_price := v_total;
  guest_count := v_count;
  return next;
end;
$$;

do $$ declare f text; begin
  foreach f in array array[
    'get_public_booking_group_slots_v1(jsonb,date)',
    'get_public_booking_group_dates_v1(jsonb)',
    'create_public_booking_group_hold_v1(jsonb,timestamptz,text,text,text,text,text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
