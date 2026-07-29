-- 130: "Selling fast" reflects online-exclusive consumption only.
--
-- 093 marked a slot 'selling_fast' when ANY blocking appointment or live hold
-- at the outlet overlapped it. That included walk-ins and counter bookings, so
-- a busy floor made every public time look scarce even when the whole online
-- allowance for the requested service was still untouched.
--
-- The public allowance is `online_booking_services.maximum_concurrent_bookings`
-- per catalogue entry, and get_public_booking_group_slots_v1 already enforces
-- it by counting only rows carrying that entry's online_booking_service_id.
-- The badge now uses the same books: a feasible slot is 'selling_fast' only
-- once some of that online allowance has actually been taken online. 'full'
-- still means the slot is not feasible at all -- whatever the reason, public
-- allowance or real therapist/room capacity.

begin;

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
  ),
  -- The catalogue entries this enquiry actually spans.
  requested as (
    select distinct (a.value->>'catalogue_id')::uuid as cfg_id
    from jsonb_array_elements(p_allocations) a
  )
  select
    m.start_at,
    coalesce(f.end_at, g.end_at) as end_at,
    case
      when f.start_at is null then 'full'
      when exists (
        select 1
        from requested rq
        where exists (
          select 1 from public.booking_holds h
          where h.online_booking_service_id = rq.cfg_id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at < coalesce(f.end_at, g.end_at)
            and h.end_at > m.start_at
        ) or exists (
          select 1 from public.appointments ap
          where ap.online_booking_service_id = rq.cfg_id
            and public.csp_blocks_schedule(ap.status::text)
            and public.csp_appointment_start_at(ap)
              < (coalesce(f.end_at, g.end_at) at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_block_end_at(ap)
              > (m.start_at at time zone 'Asia/Kuala_Lumpur')
        )
      ) then 'selling_fast'
      else 'available'
    end as status
  from merged m
  left join feasible f on f.start_at = m.start_at
  left join grid g on g.start_at = m.start_at
  order by m.start_at;
end; $$;

revoke all on function public.get_public_booking_group_slot_status_v1(jsonb,date)
  from public, anon, authenticated;
grant execute on function public.get_public_booking_group_slot_status_v1(jsonb,date)
  to service_role;

commit;
