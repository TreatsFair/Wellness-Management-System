-- Fix: get_public_booking_grid_times_v1 (093) was copied from the ORIGINAL 022
-- enumeration, which hard-codes a 30-minute grid. The live
-- get_public_booking_slots_v2 was later made interval-configurable
-- (configurable_online_booking_interval_and_window), so an outlet set to a
-- 60-minute interval (e.g. Taman Wahyu) produced feasible slots only on the hour,
-- yet the grid still emitted :30 candidates -- which then rendered as bogus,
-- greyed-out "full" 11:30/12:30/... slots in the public time picker.
--
-- Re-mirror the CURRENT v2 enumeration exactly (configurable interval, aligned
-- anchor, per-outlet maximum_booking_days) minus the capacity checks, so the grid
-- universe matches what v2 actually offers.

create or replace function public.get_public_booking_grid_times_v1(
  p_catalogue_id uuid, p_date date
)
returns table (start_at timestamptz, end_at timestamptz)
language plpgsql security definer set search_path = public stable as $$
declare
  v_cfg public.online_booking_services%rowtype;
  v_settings public.online_booking_outlet_settings%rowtype;
  v_business public.business_settings%rowtype;
  v_service public.services%rowtype;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
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
     or p_date > v_today + v_maximum_days then return; end if;

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

      start_at := v_slot_local at time zone 'Asia/Kuala_Lumpur';
      end_at := v_end_local at time zone 'Asia/Kuala_Lumpur';
      return next;
      v_slot_local := v_slot_local + make_interval(mins => v_interval);
    end loop;
  end loop;
end; $$;

revoke all on function public.get_public_booking_grid_times_v1(uuid,date)
  from public, anon, authenticated;
grant execute on function public.get_public_booking_grid_times_v1(uuid,date)
  to service_role;
