-- Safe public DTO functions and atomic booking allocation.

create or replace function public.list_public_booking_outlets()
returns table (code text, name text, address text, phone text, customer_therapist_selection_allowed boolean)
language sql security definer set search_path = public stable as $$
  select o.code, o.name, o.address, o.phone, s.customer_therapist_selection_allowed
  from public.outlets o
  join public.online_booking_outlet_settings s on s.outlet_id = o.id
  where o.is_active and s.online_booking_enabled
  order by o.name;
$$;

create or replace function public.list_public_booking_catalogue(p_outlet_code text)
returns table (
  catalogue_id uuid, public_name text, short_description text, public_image_url text,
  display_price numeric, show_price boolean,
  duration_minutes integer, display_order integer
)
language sql security definer set search_path = public stable as $$
  select c.id, c.public_name, c.short_description, c.public_image_url,
         case when c.show_price then c.display_price else null end,
         c.show_price, greatest(s.duration, 1)::integer, c.display_order
  from public.online_booking_services c
  join public.outlets o on o.id = c.outlet_id
  join public.online_booking_outlet_settings os on os.outlet_id = o.id
  join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
  where o.code = lower(trim(p_outlet_code)) and o.is_active and os.online_booking_enabled
    and coalesce(s.is_active, true) and c.enabled
    and trim(c.public_name) <> '' and trim(c.short_description) <> '' and trim(c.public_image_url) <> ''
    and exists (select 1 from public.online_booking_service_rooms cr where cr.online_booking_service_id = c.id)
  order by c.display_order, c.public_name;
$$;

create or replace function public.get_public_booking_slots_v2(
  p_catalogue_id uuid, p_date date, p_therapist_preference text default 'none'
)
returns table (start_at timestamptz, end_at timestamptz)
language plpgsql security definer set search_path = public stable as $$
declare
  v_cfg public.online_booking_services%rowtype;
  v_settings public.online_booking_outlet_settings%rowtype;
  v_business public.business_settings%rowtype;
  v_service public.services%rowtype;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_pref text := lower(coalesce(p_therapist_preference, 'none'));
  v_window record;
  v_open time;
  v_close time;
  v_slot_local timestamp;
  v_end_local timestamp;
  v_block_start_local timestamp;
  v_block_end_local timestamp;
  v_therapists integer;
  v_rooms integer;
  v_public_remaining integer;
begin
  select * into v_cfg from public.online_booking_services where id = p_catalogue_id;
  if not found then return; end if;
  select * into v_settings from public.online_booking_outlet_settings where outlet_id = v_cfg.outlet_id;
  select * into v_business from public.business_settings where outlet_id = v_cfg.outlet_id;
  select * into v_service from public.services where id = v_cfg.service_id and outlet_id = v_cfg.outlet_id;

  if not coalesce(v_settings.online_booking_enabled, false)
     or not v_cfg.enabled
     or not coalesce(v_service.is_active, true)
     or p_date < v_today + 1 or p_date > v_today + 7
     or v_pref not in ('none', 'female', 'male') then return; end if;

  if exists (select 1 from public.online_booking_closures c where c.outlet_id = v_cfg.outlet_id and c.closure_date = p_date and c.is_full_day) then return; end if;

  for v_window in
    select h.start_time, h.end_time
    from public.online_booking_service_hours h
    where v_cfg.use_custom_hours and h.online_booking_service_id = v_cfg.id
      and h.day_of_week = extract(dow from p_date)::integer
    union all
    select v_settings.public_open_time, v_settings.public_close_time
    where not v_cfg.use_custom_hours
  loop
    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);
    v_close := least(v_window.end_time, v_settings.public_close_time, v_business.close_time);
    if v_close <= v_open then continue; end if;
    v_slot_local := p_date + v_open;
    if extract(minute from v_slot_local)::integer not in (0, 30) then
      v_slot_local := date_trunc('hour', v_slot_local) +
        case when extract(minute from v_slot_local) < 30 then interval '30 minutes' else interval '1 hour' end;
    end if;

    while v_slot_local + make_interval(mins => greatest(v_service.duration, 1) + v_cfg.buffer_after_minutes) <= p_date + v_close loop
      v_end_local := v_slot_local + make_interval(mins => greatest(v_service.duration, 1));
      v_block_start_local := v_slot_local - make_interval(mins => v_cfg.buffer_before_minutes);
      v_block_end_local := v_end_local + make_interval(mins => v_cfg.buffer_after_minutes);

      if (v_slot_local at time zone 'Asia/Kuala_Lumpur') < now() + make_interval(mins => v_settings.minimum_advance_minutes)
         or v_block_start_local < p_date + v_open or exists (
        select 1 from public.online_booking_closures c
        where c.outlet_id = v_cfg.outlet_id and c.closure_date = p_date and not c.is_full_day
          and (p_date + c.start_time) < v_block_end_local and (p_date + c.end_time) > v_block_start_local
      ) then
        v_slot_local := v_slot_local + interval '30 minutes'; continue;
      end if;

      select greatest(v_cfg.maximum_concurrent_bookings
        - (select count(*) from public.booking_holds h where h.online_booking_service_id = v_cfg.id
             and h.status = 'pending_payment' and h.expires_at > now()
             and h.start_at - make_interval(mins => h.buffer_before_minutes) < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
             and h.end_at + make_interval(mins => h.buffer_after_minutes) > (v_block_start_local at time zone 'Asia/Kuala_Lumpur'))
        - (select count(*) from public.appointments a where a.online_booking_service_id = v_cfg.id
             and public.csp_blocks_schedule(a.status::text)
             and public.csp_appointment_start_at(a) < v_block_end_local
             and public.csp_appointment_end_at(a) > v_block_start_local), 0)::integer
      into v_public_remaining;

      select count(*)::integer into v_therapists
      from public.therapists t
      where t.outlet_id = v_cfg.outlet_id and coalesce(t.availability_status, true)
        and lower(coalesce(t.role, 'therapist')) = 'therapist'
        and (v_pref = 'none' or lower(coalesce(t.gender, '')) = v_pref)
        and (coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb or t.service_commissions ? v_cfg.service_id::text)
        and exists (
          select 1 from public.therapist_working_hours wh
          where wh.therapist_id = t.id and wh.outlet_id = v_cfg.outlet_id
            and wh.day_of_week = extract(dow from p_date)::integer
            and p_date + wh.start_time <= v_block_start_local and p_date + wh.end_time >= v_block_end_local
        )
        and not exists (select 1 from public.therapist_unavailability u where u.therapist_id = t.id
          and u.starts_at < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
          and u.ends_at > (v_block_start_local at time zone 'Asia/Kuala_Lumpur'))
        and not exists (select 1 from public.appointments a where a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_block_end_local and public.csp_appointment_end_at(a) > v_block_start_local)
        and not exists (select 1 from public.booking_holds h where h.assigned_therapist_id = t.id
          and h.status = 'pending_payment' and h.expires_at > now()
          and h.start_at - make_interval(mins => h.buffer_before_minutes) < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
          and h.end_at + make_interval(mins => h.buffer_after_minutes) > (v_block_start_local at time zone 'Asia/Kuala_Lumpur'));

      select coalesce(sum(greatest(coalesce(r.total_slots, 1)
        - (select count(*) from public.appointments a where a.room_id = r.id and public.csp_blocks_schedule(a.status::text)
             and public.csp_appointment_start_at(a) < v_block_end_local and public.csp_appointment_end_at(a) > v_block_start_local)
        - (select count(*) from public.booking_holds h where h.assigned_room_id = r.id
             and h.status = 'pending_payment' and h.expires_at > now()
             and h.start_at - make_interval(mins => h.buffer_before_minutes) < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
             and h.end_at + make_interval(mins => h.buffer_after_minutes) > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')), 0)), 0)::integer
      into v_rooms
      from public.rooms r join public.online_booking_service_rooms cr on cr.room_id = r.id
      where cr.online_booking_service_id = v_cfg.id and cr.outlet_id = v_cfg.outlet_id and coalesce(r.is_active, true);

      if least(v_public_remaining, v_therapists, v_rooms) > 0 then
        start_at := v_slot_local at time zone 'Asia/Kuala_Lumpur';
        end_at := v_end_local at time zone 'Asia/Kuala_Lumpur';
        return next;
      end if;
      v_slot_local := v_slot_local + interval '30 minutes';
    end loop;
  end loop;
end; $$;

create or replace function public.get_public_booking_dates_v2(p_catalogue_id uuid, p_therapist_preference text default 'none')
returns table (booking_date date, available boolean)
language plpgsql security definer set search_path = public stable as $$
declare v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_date date;
begin
  for i in 1..7 loop
    v_date := v_today + i;
    booking_date := v_date;
    available := exists(select 1 from public.get_public_booking_slots_v2(p_catalogue_id, v_date, p_therapist_preference));
    return next;
  end loop;
end; $$;

create or replace function public.create_public_booking_hold_v2(
  p_catalogue_id uuid, p_start_at timestamptz, p_therapist_preference text,
  p_customer_name text, p_customer_phone text, p_customer_email text,
  p_therapist_request text default '', p_notes text default '', p_request_fingerprint text default ''
)
returns table (hold_id uuid, hold_token uuid, hold_expires_at timestamptz, total_price numeric, duration_minutes integer)
language plpgsql security definer set search_path = public as $$
declare
  v_cfg public.online_booking_services%rowtype; v_service public.services%rowtype;
  v_pref text := lower(coalesce(p_therapist_preference, 'none'));
  v_local_start timestamp := p_start_at at time zone 'Asia/Kuala_Lumpur';
  v_end_at timestamptz; v_block_start timestamptz; v_block_end timestamptz;
  v_therapist uuid; v_room uuid;
begin
  if length(trim(p_customer_name)) < 2 or length(trim(p_customer_phone)) < 8 or position('@' in p_customer_email) < 2 then
    raise exception 'Valid customer details are required'; end if;
  select * into v_cfg from public.online_booking_services where id = p_catalogue_id;
  if not found then raise exception 'Online treatment is unavailable'; end if;
  select * into v_service from public.services where id = v_cfg.service_id and outlet_id = v_cfg.outlet_id;
  perform pg_advisory_xact_lock(hashtextextended(v_cfg.outlet_id::text || '|' || v_local_start::date::text, 0));
  perform public.expire_stale_booking_holds();
  if not exists(select 1 from public.get_public_booking_slots_v2(v_cfg.id, v_local_start::date, v_pref) s where s.start_at = p_start_at) then
    raise exception 'The selected time is no longer available'; end if;
  if trim(p_request_fingerprint) <> '' and (select count(*) from public.booking_holds h
      where h.request_fingerprint = trim(p_request_fingerprint) and h.created_at > now() - interval '1 hour') >= 12 then
    raise exception 'Too many booking attempts. Please try again later'; end if;

  v_end_at := p_start_at + make_interval(mins => greatest(v_service.duration, 1));
  v_block_start := p_start_at - make_interval(mins => v_cfg.buffer_before_minutes);
  v_block_end := v_end_at + make_interval(mins => v_cfg.buffer_after_minutes);

  select t.id into v_therapist from public.therapists t
  where t.outlet_id = v_cfg.outlet_id and coalesce(t.availability_status, true)
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
    and (v_pref = 'none' or lower(coalesce(t.gender, '')) = v_pref)
    and (coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb or t.service_commissions ? v_cfg.service_id::text)
    and exists (select 1 from public.therapist_working_hours wh where wh.therapist_id = t.id
      and wh.day_of_week = extract(dow from v_local_start)::integer
      and v_local_start::date + wh.start_time <= (v_block_start at time zone 'Asia/Kuala_Lumpur')
      and v_local_start::date + wh.end_time >= (v_block_end at time zone 'Asia/Kuala_Lumpur'))
    and not exists (select 1 from public.therapist_unavailability u where u.therapist_id=t.id and u.starts_at<v_block_end and u.ends_at>v_block_start)
    and not exists (select 1 from public.appointments a where a.therapist_id=t.id and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < (v_block_end at time zone 'Asia/Kuala_Lumpur')
      and public.csp_appointment_end_at(a) > (v_block_start at time zone 'Asia/Kuala_Lumpur'))
    and not exists (select 1 from public.booking_holds h where h.assigned_therapist_id=t.id and h.status='pending_payment'
      and h.expires_at>now()
      and h.start_at-make_interval(mins=>h.buffer_before_minutes)<v_block_end
      and h.end_at+make_interval(mins=>h.buffer_after_minutes)>v_block_start)
  order by t.name for update of t skip locked limit 1;
  if v_therapist is null then raise exception 'The selected time is no longer available'; end if;

  select r.id into v_room from public.rooms r join public.online_booking_service_rooms cr on cr.room_id=r.id
  where cr.online_booking_service_id=v_cfg.id and coalesce(r.is_active,true)
    and coalesce(r.total_slots,1) >
      (select count(*) from public.appointments a where a.room_id=r.id and public.csp_blocks_schedule(a.status::text)
       and public.csp_appointment_start_at(a)<(v_block_end at time zone 'Asia/Kuala_Lumpur') and public.csp_appointment_end_at(a)>(v_block_start at time zone 'Asia/Kuala_Lumpur')) +
      (select count(*) from public.booking_holds h where h.assigned_room_id=r.id and h.status='pending_payment'
       and h.expires_at>now()
       and h.start_at-make_interval(mins=>h.buffer_before_minutes)<v_block_end
       and h.end_at+make_interval(mins=>h.buffer_after_minutes)>v_block_start)
  order by r.name for update of r skip locked limit 1;
  if v_room is null then raise exception 'The selected time is no longer available'; end if;

  insert into public.booking_holds(outlet_id, online_booking_service_id, customer_name, customer_phone, customer_email,
    therapist_preference, therapist_request, assigned_therapist_id, assigned_room_id, service_items,
    start_at, end_at, total_amount, buffer_before_minutes, buffer_after_minutes,
    status, expires_at, notes, request_fingerprint)
  values(v_cfg.outlet_id, v_cfg.id, trim(p_customer_name), trim(p_customer_phone), lower(trim(p_customer_email)),
    v_pref, left(trim(p_therapist_request),200), v_therapist, v_room,
    jsonb_build_array(jsonb_build_object('service_id',v_cfg.service_id,'public_name',v_cfg.public_name,
      'duration',v_service.duration,'display_price',v_cfg.display_price)),
    p_start_at, v_end_at, v_cfg.display_price, v_cfg.buffer_before_minutes, v_cfg.buffer_after_minutes,
    'pending_payment', now()+interval '15 minutes', left(trim(p_notes),500), left(trim(p_request_fingerprint),128))
  returning booking_holds.id, booking_holds.public_token, booking_holds.expires_at
  into hold_id, hold_token, hold_expires_at;
  total_price := v_cfg.display_price; duration_minutes := v_service.duration; return next;
end; $$;

create or replace function public.get_public_booking_hold_status_v2(p_token uuid)
returns table (token uuid, status text, expires_at timestamptz, total_price numeric, start_at timestamptz, end_at timestamptz)
language sql security definer set search_path = public as $$
  select h.public_token, h.status, h.expires_at, h.total_amount, h.start_at, h.end_at
  from public.booking_holds h where h.public_token = p_token;
$$;

do $$ declare f text; begin
  foreach f in array array[
    'list_public_booking_outlets()','list_public_booking_catalogue(text)',
    'get_public_booking_slots_v2(uuid,date,text)','get_public_booking_dates_v2(uuid,text)',
    'create_public_booking_hold_v2(uuid,timestamptz,text,text,text,text,text,text,text)',
    'get_public_booking_hold_status_v2(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
