-- Public time picker: show every in-hours slot with a display status instead of
-- only the bookable ones. The website previously received only feasible slots
-- (full/unavailable times simply never appeared). This adds an ADDITIVE status
-- API so the picker can render three states:
--   * available    - bookable, nothing booked over it yet (pale green)
--   * selling_fast  - bookable, but >=1 appointment/hold already overlaps it (amber)
--   * full          - not bookable at this time (greyed out, non-selectable)
--
-- Intentionally additive: get_public_booking_group_slots_v1 is NOT modified, so
-- the string-copy regeneration in 066 and the text guard in 075 stay valid.

-- 1. The full in-hours candidate grid for a catalogue/date. This mirrors the
--    enumeration in get_public_booking_slots_v2 (022) EXACTLY -- same window
--    resolution, 30-minute grid snap, and minimum-advance / past / closure
--    filters -- but omits the therapist/room/concurrency capacity checks, so it
--    returns every candidate time including fully-booked ones.
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
  v_slot_local timestamp;
  v_end_local timestamp;
  v_block_start_local timestamp;
  v_block_end_local timestamp;
begin
  select * into v_cfg from public.online_booking_services where id = p_catalogue_id;
  if not found then return; end if;
  select * into v_settings from public.online_booking_outlet_settings where outlet_id = v_cfg.outlet_id;
  select * into v_business from public.business_settings where outlet_id = v_cfg.outlet_id;
  select * into v_service from public.services where id = v_cfg.service_id and outlet_id = v_cfg.outlet_id;

  if not coalesce(v_settings.online_booking_enabled, false)
     or not v_cfg.enabled
     or not coalesce(v_service.is_active, true)
     or p_date < v_today + 1 or p_date > v_today + 7 then return; end if;

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

      start_at := v_slot_local at time zone 'Asia/Kuala_Lumpur';
      end_at := v_end_local at time zone 'Asia/Kuala_Lumpur';
      return next;
      v_slot_local := v_slot_local + interval '30 minutes';
    end loop;
  end loop;
end; $$;

-- 2. Per-slot display status for the group time picker. Feasibility is the
--    authoritative group function (reused unmodified); the grid supplies the
--    full universe so fully-booked times still appear (as 'full'). A feasible
--    slot is 'selling_fast' when any blocking appointment or live pending hold
--    at the outlet already overlaps it, otherwise 'available'.
create or replace function public.get_public_booking_group_slot_status_v1(
  p_allocations jsonb, p_date date
)
returns table (start_at timestamptz, end_at timestamptz, status text)
language plpgsql security definer set search_path = public stable as $$
declare
  v_first_cat uuid;
  v_outlet uuid;
begin
  if jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) < 1
     or jsonb_array_length(p_allocations) > 6 then return; end if;

  v_first_cat := (p_allocations->0->>'catalogue_id')::uuid;
  select c.outlet_id into v_outlet from public.online_booking_services c where c.id = v_first_cat;
  if v_outlet is null then return; end if;

  return query
  with feasible as (
    select s.start_at, min(s.end_at) as end_at
    from public.get_public_booking_group_slots_v1(p_allocations, p_date) s
    group by s.start_at
  ),
  grid as (
    select g.start_at, min(g.end_at) as end_at
    from public.get_public_booking_grid_times_v1(v_first_cat, p_date) g
    group by g.start_at
  ),
  merged as (
    select f.start_at from feasible f
    union
    select g.start_at from grid g
  )
  select
    m.start_at,
    coalesce(f.end_at, g.end_at) as end_at,
    case
      when f.start_at is null then 'full'
      when exists (
        select 1 from public.appointments ap
        where ap.outlet_id = v_outlet
          and public.csp_blocks_schedule(ap.status::text)
          and public.csp_appointment_start_at(ap) < (coalesce(f.end_at, g.end_at) at time zone 'Asia/Kuala_Lumpur')
          and public.csp_appointment_end_at(ap) > (m.start_at at time zone 'Asia/Kuala_Lumpur')
      ) or exists (
        select 1 from public.booking_holds h
        where h.outlet_id = v_outlet
          and h.status = 'pending_payment' and h.expires_at > now()
          and h.start_at < coalesce(f.end_at, g.end_at)
          and h.end_at > m.start_at
      ) then 'selling_fast'
      else 'available'
    end as status
  from merged m
  left join feasible f on f.start_at = m.start_at
  left join grid g on g.start_at = m.start_at
  order by m.start_at;
end; $$;

revoke all on function public.get_public_booking_grid_times_v1(uuid,date)
  from public, anon, authenticated;
revoke all on function public.get_public_booking_group_slot_status_v1(jsonb,date)
  from public, anon, authenticated;
grant execute on function public.get_public_booking_grid_times_v1(uuid,date)
  to service_role;
grant execute on function public.get_public_booking_group_slot_status_v1(jsonb,date)
  to service_role;
