-- Phase 6B.1 follow-up (pre-123): reject zero-based or malformed pax indexes
-- before either preference-aware capacity RPC begins its allocation work.
-- LOCAL ONLY; do not apply until validated.

alter function public.get_counter_preference_capacity_slots(
  uuid, date, jsonb, uuid, uuid
) rename to get_counter_preference_capacity_slots_122r_impl;

alter function public.allocate_preference_provisional_slots(
  uuid, date, time, jsonb, uuid
) rename to allocate_preference_provisional_slots_122r_impl;

revoke all on function public.get_counter_preference_capacity_slots_122r_impl(
  uuid, date, jsonb, uuid, uuid
) from public, anon, authenticated;

revoke all on function public.allocate_preference_provisional_slots_122r_impl(
  uuid, date, time, jsonb, uuid
) from public, anon, authenticated;

create or replace function public.validate_one_based_capacity_requirements_122s(
  p_requirements jsonb
)
returns void
language plpgsql
immutable
security invoker
set search_path = public
as $function$
declare
  v_requirement jsonb;
  v_pax_index integer;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array' then
    raise exception using
      errcode = '22023',
      message =
        'Every pax requirement must use a one-based pax_index starting from 1.';
  end if;

  for v_requirement in
    select value
    from jsonb_array_elements(p_requirements)
  loop
    begin
      v_pax_index := (v_requirement ->> 'pax_index')::integer;
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        raise exception using
          errcode = '22023',
          message =
            'Every pax requirement must use a one-based pax_index starting from 1.';
    end;

    if v_pax_index is null or v_pax_index < 1 then
      raise exception using
        errcode = '22023',
        message =
          'Every pax requirement must use a one-based pax_index starting from 1.';
    end if;
  end loop;
end;
$function$;

revoke all on function public.validate_one_based_capacity_requirements_122s(
  jsonb
) from public, anon, authenticated;

create or replace function public.get_counter_preference_capacity_slots(
  p_outlet_id uuid,
  p_date date,
  p_requirements jsonb,
  p_exclude_appointment_group_id uuid default null,
  p_exclude_appointment_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  therapist_free integer,
  room_free integer,
  is_available boolean,
  unavailable_dimension text,
  unavailable_at timestamp,
  conflict_therapist_id uuid,
  conflict_start time,
  conflict_end time
)
language plpgsql
stable
security definer
set search_path = public
as $function$
begin
  perform public.validate_one_based_capacity_requirements_122s(p_requirements);

  return query
  select *
  from public.get_counter_preference_capacity_slots_122r_impl(
    p_outlet_id,
    p_date,
    p_requirements,
    p_exclude_appointment_group_id,
    p_exclude_appointment_id
  );
end;
$function$;

revoke all on function public.get_counter_preference_capacity_slots(
  uuid, date, jsonb, uuid, uuid
) from public, anon;
grant execute on function public.get_counter_preference_capacity_slots(
  uuid, date, jsonb, uuid, uuid
) to authenticated;

create or replace function public.allocate_preference_provisional_slots(
  p_outlet_id uuid,
  p_date date,
  p_start_time time,
  p_requirements jsonb,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  pax_index integer,
  therapist_id uuid,
  room_id uuid,
  end_time time
)
language plpgsql
stable
security definer
set search_path = public
as $function$
begin
  perform public.validate_one_based_capacity_requirements_122s(p_requirements);

  return query
  select *
  from public.allocate_preference_provisional_slots_122r_impl(
    p_outlet_id,
    p_date,
    p_start_time,
    p_requirements,
    p_exclude_appointment_group_id
  );
end;
$function$;

revoke all on function public.allocate_preference_provisional_slots(
  uuid, date, time, jsonb, uuid
) from public, anon;
grant execute on function public.allocate_preference_provisional_slots(
  uuid, date, time, jsonb, uuid
) to authenticated;
