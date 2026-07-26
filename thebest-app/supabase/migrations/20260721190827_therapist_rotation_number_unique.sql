-- Keep therapist rotation numbers unambiguous within each outlet. Counter
-- staff retain their independent display ordering and are deliberately not
-- included in this uniqueness rule.

do $$
begin
  if exists (
    select 1
    from public.therapists
    where lower(role) = 'therapist'
    group by outlet_id, display_order
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Duplicate therapist rotation numbers exist within an outlet.';
  end if;
end;
$$;

create unique index if not exists therapists_outlet_rotation_number_uidx
  on public.therapists(outlet_id, display_order)
  where lower(role) = 'therapist';

comment on index public.therapists_outlet_rotation_number_uidx is
  'Ensures each therapist has one unique rotation number within an outlet.';

-- Preserve drag-to-reorder after adding the unique index. The first update
-- moves the selected role to collision-free temporary values; the second
-- applies the requested rotation numbers. Both statements run in the same
-- transaction, so a failure cannot leave temporary values behind.
create or replace function public.reorder_staff_display_order(
  p_outlet_id uuid,
  p_staff_ids uuid[],
  p_display_orders integer[]
)
returns void
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  v_role text;
  v_expected_count integer;
  v_supplied_count integer := coalesce(cardinality(p_staff_ids), 0);
  v_temp_base integer;
begin
  if v_supplied_count = 0
     or cardinality(p_display_orders) is distinct from v_supplied_count then
    raise exception using
      errcode = '22023',
      message = 'Staff IDs and display orders must be non-empty arrays of equal length.';
  end if;

  if exists (
    select 1
    from unnest(p_display_orders) requested(display_order)
    where requested.display_order < 0
  ) or (
    select count(distinct requested.display_order)
    from unnest(p_display_orders) requested(display_order)
  ) <> v_supplied_count then
    raise exception using
      errcode = '22023',
      message = 'Display orders must be unique non-negative integers.';
  end if;

  select lower(therapist.role)
  into v_role
  from public.therapists therapist
  where therapist.id = p_staff_ids[1]
    and therapist.outlet_id = p_outlet_id;

  if v_role is null then
    raise exception using
      errcode = '22023',
      message = 'The selected staff do not belong to this outlet.';
  end if;

  select count(*)
  into v_expected_count
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and lower(therapist.role) = v_role;

  if v_expected_count <> v_supplied_count
     or exists (
       select 1
       from unnest(p_staff_ids) requested(id)
       left join public.therapists therapist
         on therapist.id = requested.id
        and therapist.outlet_id = p_outlet_id
        and lower(therapist.role) = v_role
       where therapist.id is null
     )
     or (
       select count(distinct requested.id)
       from unnest(p_staff_ids) requested(id)
     ) <> v_supplied_count then
    raise exception using
      errcode = '22023',
      message = 'Reordering requires every staff member of one outlet role exactly once.';
  end if;

  select coalesce(min(therapist.display_order), 0) - v_supplied_count - 1000
  into v_temp_base
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and lower(therapist.role) = v_role;

  update public.therapists therapist
  set display_order = v_temp_base - requested.ordinality::integer
  from unnest(p_staff_ids) with ordinality requested(id, ordinality)
  where therapist.id = requested.id
    and therapist.outlet_id = p_outlet_id;

  update public.therapists therapist
  set display_order = requested.display_order
  from unnest(p_staff_ids, p_display_orders)
    requested(id, display_order)
  where therapist.id = requested.id
    and therapist.outlet_id = p_outlet_id;
end;
$$;

revoke all on function public.reorder_staff_display_order(
  uuid, uuid[], integer[]
) from public, anon;
grant execute on function public.reorder_staff_display_order(
  uuid, uuid[], integer[]
) to authenticated;
