-- Keep the availability implementation from the preceding migration intact;
-- shift its date anchor back one day when same-day booking is enabled. The
-- existing lower/upper checks then yield today..N-1 instead of tomorrow..N.
do $migration$
declare
  v_definition text;
  v_marker text :=
    'v_maximum_days := greatest(coalesce(v_settings.maximum_booking_days, 7), 1);';
  v_replacement text := v_marker || E'\n\n  if coalesce(v_settings.same_day_booking_allowed, false) then\n    v_today := v_today - 1;\n  end if;';
begin
  select pg_get_functiondef(p.oid)
  into v_definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_public_booking_slots_v2'
    and pg_get_function_identity_arguments(p.oid) =
      'p_catalogue_id uuid, p_date date, p_therapist_preference text';

  if v_definition is null or strpos(v_definition, v_marker) = 0 then
    raise exception 'Unable to update get_public_booking_slots_v2 date anchor';
  end if;

  execute replace(v_definition, v_marker, v_replacement);
end;
$migration$;

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
  v_same_day boolean;
begin
  select
    greatest(coalesce(s.maximum_booking_days, 7), 1),
    coalesce(s.same_day_booking_allowed, false)
  into v_maximum_days, v_same_day
  from public.online_booking_services c
  join public.online_booking_outlet_settings s on s.outlet_id = c.outlet_id
  where c.id = p_catalogue_id;

  if v_maximum_days is null then return; end if;
  if v_same_day then v_today := v_today - 1; end if;

  for i in 1..v_maximum_days loop
    v_date := v_today + i;
    booking_date := v_date;
    available := exists(
      select 1
      from public.get_public_booking_slots_v2(
        p_catalogue_id,
        v_date,
        p_therapist_preference
      )
    );
    return next;
  end loop;
end;
$$;
