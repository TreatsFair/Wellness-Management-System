-- Return only the configured group-booking date range. The Edge Function uses
-- this cheap range to run exact group feasibility checks with bounded
-- parallelism instead of scanning all seven days sequentially in one RPC.

create or replace function public.get_public_booking_group_date_range_v1(
  p_allocations jsonb
)
returns table (booking_date date)
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
    return next;
  end loop;
end;
$$;

revoke all on function public.get_public_booking_group_date_range_v1(jsonb)
  from public, anon, authenticated;
grant execute on function public.get_public_booking_group_date_range_v1(jsonb)
  to service_role;
