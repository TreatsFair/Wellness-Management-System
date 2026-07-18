-- Respect each outlet's same-day setting when returning group booking dates.
-- Migration 060 introduced exact group feasibility checks but always started
-- its date range tomorrow, bypassing the existing same-day configuration.

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
  v_same_day_allowed boolean;
  v_first_offset integer;
begin
  if jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) < 1
     or jsonb_array_length(p_allocations) > 6 then return; end if;

  select greatest(coalesce(s.maximum_booking_days, 7), 1),
         coalesce(s.same_day_booking_allowed, false)
  into v_maximum_days, v_same_day_allowed
  from public.online_booking_services c
  join public.online_booking_outlet_settings s on s.outlet_id = c.outlet_id
  where c.id = (p_allocations->0->>'catalogue_id')::uuid;
  if v_maximum_days is null then return; end if;

  v_first_offset := case when v_same_day_allowed then 0 else 1 end;
  for i in v_first_offset..(v_first_offset + v_maximum_days - 1) loop
    booking_date := v_today + i;
    available := exists(
      select 1 from public.get_public_booking_group_slots_v1(p_allocations, v_today + i)
    );
    return next;
  end loop;
end;
$$;

revoke all on function public.get_public_booking_group_dates_v1(jsonb)
  from public, anon, authenticated;
grant execute on function public.get_public_booking_group_dates_v1(jsonb)
  to service_role;
