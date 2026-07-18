alter table public.online_booking_outlet_settings
  drop constraint if exists online_booking_outlet_settings_slot_interval_minutes_check,
  drop constraint if exists online_booking_outlet_settings_maximum_booking_days_check;

alter table public.online_booking_outlet_settings
  add constraint online_booking_outlet_settings_slot_interval_minutes_check
    check (slot_interval_minutes between 5 and 120),
  add constraint online_booking_outlet_settings_maximum_booking_days_check
    check (maximum_booking_days between 1 and 90);

create or replace function public.get_public_booking_slots_v2(
  p_catalogue_id uuid,
  p_date date,
  p_therapist_preference text default 'none'
)
returns table (start_at timestamptz, end_at timestamptz)
language plpgsql
security definer
set search_path = public
stable
as $$
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
  v_anchor timestamp;
  v_slot_local timestamp;
  v_end_local timestamp;
  v_block_start_local timestamp;
  v_block_end_local timestamp;
  v_interval integer;
  v_maximum_days integer;
  v_steps integer;
  v_therapists integer;
  v_rooms integer;
  v_public_remaining integer;
begin
  select * into v_cfg from public.online_booking_services where id = p_catalogue_id;
  if not found then return; end if;
  select * into v_settings from public.online_booking_outlet_settings where outlet_id = v_cfg.outlet_id;
  select * into v_business from public.business_settings where outlet_id = v_cfg.outlet_id;
  select * into v_service from public.services where id = v_cfg.service_id and outlet_id = v_cfg.outlet_id;

  v_interval := greatest(coalesce(v_settings.slot_interval_minutes, 30), 5);
  v_maximum_days := greatest(coalesce(v_settings.maximum_booking_days, 7), 1);

  if not coalesce(v_settings.online_booking_enabled, false)
     or not v_cfg.enabled
     or not coalesce(v_service.is_active, true)
     or p_date < v_today + 1
     or p_date > v_today + v_maximum_days
     or v_pref not in ('none', 'female', 'male') then return; end if;

  if exists (
    select 1 from public.online_booking_closures c
    where c.outlet_id = v_cfg.outlet_id and c.closure_date = p_date and c.is_full_day
  ) then return; end if;

  for v_window in
    select h.start_time, h.end_time
    from public.online_booking_service_hours h
    where v_cfg.use_custom_hours
      and h.online_booking_service_id = v_cfg.id
      and h.day_of_week = extract(dow from p_date)::integer
    union all
    select v_settings.public_open_time, v_settings.public_close_time
    where not v_cfg.use_custom_hours
  loop
    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);
    v_close := least(v_window.end_time, v_settings.public_close_time, v_business.close_time);
    if v_close <= v_open then continue; end if;

    v_anchor := p_date + greatest(v_settings.public_open_time, v_business.open_time);
    v_steps := greatest(
      ceil(extract(epoch from ((p_date + v_open) - v_anchor)) / 60.0 / v_interval)::integer,
      0
    );
    v_slot_local := v_anchor + make_interval(mins => v_steps * v_interval);

    while v_slot_local + make_interval(
      mins => greatest(v_service.duration, 1) + v_cfg.buffer_after_minutes
    ) <= p_date + v_close loop
      v_end_local := v_slot_local + make_interval(mins => greatest(v_service.duration, 1));
      v_block_start_local := v_slot_local - make_interval(mins => v_cfg.buffer_before_minutes);
      v_block_end_local := v_end_local + make_interval(mins => v_cfg.buffer_after_minutes);

      if (v_slot_local at time zone 'Asia/Kuala_Lumpur')
          < now() + make_interval(mins => v_settings.minimum_advance_minutes)
         or v_block_start_local < p_date + v_open
         or exists (
           select 1 from public.online_booking_closures c
           where c.outlet_id = v_cfg.outlet_id
             and c.closure_date = p_date
             and not c.is_full_day
             and (p_date + c.start_time) < v_block_end_local
             and (p_date + c.end_time) > v_block_start_local
         ) then
        v_slot_local := v_slot_local + make_interval(mins => v_interval);
        continue;
      end if;

      select greatest(
        v_cfg.maximum_concurrent_bookings
        - (
          select count(*) from public.booking_holds h
          where h.online_booking_service_id = v_cfg.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes)
              < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and h.end_at + make_interval(mins => h.buffer_after_minutes)
              > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        )
        - (
          select count(*) from public.appointments a
          where a.online_booking_service_id = v_cfg.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_block_end_local
            and public.csp_appointment_block_end_at(a) > v_block_start_local
        ), 0
      )::integer into v_public_remaining;

      select count(*)::integer into v_therapists
      from public.therapists t
      where t.outlet_id = v_cfg.outlet_id
        and coalesce(t.availability_status, true)
        and lower(coalesce(t.role, 'therapist')) = 'therapist'
        and (v_pref = 'none' or lower(coalesce(t.gender, '')) = v_pref)
        and (
          coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb
          or t.service_commissions ? v_cfg.service_id::text
        )
        and exists (
          select 1 from public.therapist_working_hours wh
          where wh.therapist_id = t.id and wh.outlet_id = v_cfg.outlet_id
            and wh.day_of_week = extract(dow from p_date)::integer
            and p_date + wh.start_time <= v_block_start_local
            and p_date + wh.end_time >= v_block_end_local
        )
        and not exists (
          select 1 from public.therapist_unavailability u
          where u.therapist_id = t.id
            and u.starts_at < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and u.ends_at > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        )
        and not exists (
          select 1 from public.appointments a
          where a.therapist_id = t.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_block_end_local
            and public.csp_appointment_block_end_at(a) > v_block_start_local
        )
        and not exists (
          select 1 from public.booking_holds h
          where h.assigned_therapist_id = t.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes)
              < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and h.end_at + make_interval(mins => h.buffer_after_minutes)
              > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        );

      select coalesce(sum(greatest(
        coalesce(r.total_slots, 1)
        - (
          select count(*) from public.appointments a
          where a.room_id = r.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_block_end_local
            and public.csp_appointment_block_end_at(a) > v_block_start_local
        )
        - (
          select count(*) from public.booking_holds h
          where h.assigned_room_id = r.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes)
              < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and h.end_at + make_interval(mins => h.buffer_after_minutes)
              > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        ), 0
      )), 0)::integer into v_rooms
      from public.rooms r
      join public.online_booking_service_rooms cr on cr.room_id = r.id
      where cr.online_booking_service_id = v_cfg.id
        and cr.outlet_id = v_cfg.outlet_id
        and coalesce(r.is_active, true);

      if least(v_public_remaining, v_therapists, v_rooms) > 0 then
        start_at := v_slot_local at time zone 'Asia/Kuala_Lumpur';
        end_at := v_end_local at time zone 'Asia/Kuala_Lumpur';
        return next;
      end if;
      v_slot_local := v_slot_local + make_interval(mins => v_interval);
    end loop;
  end loop;
end;
$$;

create or replace function public.get_public_booking_dates_v2(
  p_catalogue_id uuid,
  p_therapist_preference text default 'none'
)
returns table (booking_date date, available boolean)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_date date;
  v_maximum_days integer;
begin
  select greatest(coalesce(s.maximum_booking_days, 7), 1)
  into v_maximum_days
  from public.online_booking_services c
  join public.online_booking_outlet_settings s on s.outlet_id = c.outlet_id
  where c.id = p_catalogue_id;

  if v_maximum_days is null then return; end if;
  for i in 1..v_maximum_days loop
    v_date := v_today + i;
    booking_date := v_date;
    available := exists(
      select 1
      from public.get_public_booking_slots_v2(
        p_catalogue_id, v_date, p_therapist_preference
      )
    );
    return next;
  end loop;
end;
$$;;
