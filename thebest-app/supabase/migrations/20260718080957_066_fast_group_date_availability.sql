-- Date availability needs only one valid group slot, while the time picker
-- needs every valid slot. Build an internal early-exit variant from the current
-- group-slot function so date checks do not simulate every candidate time.

do $migration$
declare
  v_definition text;
  v_signature text :=
    'CREATE OR REPLACE FUNCTION public.get_public_booking_group_slots_v1(p_allocations jsonb, p_date date)';
  v_fast_signature text :=
    'CREATE OR REPLACE FUNCTION public.get_public_booking_group_slots_scan_v1(p_allocations jsonb, p_date date, p_stop_after_first boolean DEFAULT false)';
begin
  select pg_get_functiondef(p.oid)
  into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_public_booking_group_slots_v1'
    and pg_get_function_identity_arguments(p.oid) =
      'p_allocations jsonb, p_date date';

  if v_definition is null
     or strpos(v_definition, v_signature) = 0
     or strpos(v_definition, 'return next;') = 0 then
    raise exception 'Unable to create early-exit group slot scanner';
  end if;

  v_definition := replace(v_definition, v_signature, v_fast_signature);
  v_definition := replace(
    v_definition,
    'return next;',
    E'return next;\n      if p_stop_after_first then return; end if;'
  );
  execute v_definition;
end;
$migration$;

create or replace function public.get_public_booking_group_slots_v1(
  p_allocations jsonb,
  p_date date
)
returns table (start_at timestamptz, end_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select *
  from public.get_public_booking_group_slots_scan_v1(
    p_allocations,
    p_date,
    false
  );
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
      select 1
      from public.get_public_booking_group_slots_scan_v1(
        p_allocations,
        v_today + i,
        true
      )
    );
    return next;
  end loop;
end;
$$;

revoke all on function public.get_public_booking_group_slots_scan_v1(jsonb,date,boolean)
  from public, anon, authenticated;
revoke all on function public.get_public_booking_group_slots_v1(jsonb,date)
  from public, anon, authenticated;
revoke all on function public.get_public_booking_group_dates_v1(jsonb)
  from public, anon, authenticated;

grant execute on function public.get_public_booking_group_slots_scan_v1(jsonb,date,boolean)
  to service_role;
grant execute on function public.get_public_booking_group_slots_v1(jsonb,date)
  to service_role;
grant execute on function public.get_public_booking_group_dates_v1(jsonb)
  to service_role;
