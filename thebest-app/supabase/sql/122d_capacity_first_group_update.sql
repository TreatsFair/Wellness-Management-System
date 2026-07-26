-- Phase 6B.1: capacity-first-safe edits for existing appointment groups.
--
-- This is deliberately a follow-up to 121/122, not a rewrite of an applied
-- migration.  When the feature flag is OFF it delegates byte-for-byte behaviour
-- to the 097 implementation.  When it is ON, normal queue/gender pax remain
-- anonymous and the whole revised group is admitted by one capacity_feasible
-- verdict while holding bounded outlet/date advisory locks.

begin;

alter function public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) rename to update_appointment_group_with_csp_concrete_legacy;

create or replace function public.update_appointment_group_with_csp(
  p_appointment_group_id uuid,
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_type text default 'appointment',
  p_status text default 'confirmed',
  p_notes text default '',
  p_updated_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_group public.appointment_groups%rowtype;
  v_existing public.appointments%rowtype;
  v_allocation jsonb;
  v_normalized jsonb := '[]'::jsonb;
  v_demands jsonb := '[]'::jsonb;
  v_feasible jsonb;
  v_check record;
  v_outlet_id uuid;
  v_service_id uuid;
  v_existing_id uuid;
  v_therapist_id uuid;
  v_room_id uuid;
  v_requested_therapist_id uuid;
  v_start time without time zone;
  v_end time without time zone;
  v_source text;
  v_requested_gender text;
  v_room_type text;
  v_buffer integer;
  v_is_concrete boolean;
  v_old_date date;
  v_lock_date date;
  v_existing_count integer;
  v_group_paid boolean;
  v_index integer := 0;
  v_saved_id uuid;
  v_ids uuid[] := array[]::uuid[];
  v_conflicts integer;
  v_room_slots integer;
begin
  -- Preserve the established concrete implementation until the per-outlet flag
  -- is intentionally enabled.  This branch is the compatibility boundary.
  select * into v_group
  from public.appointment_groups g
  where g.id = p_appointment_group_id;

  if not found then
    return query select false, p_appointment_group_id, v_ids,
      'NOT_FOUND', 'Appointment group was not found.';
    return;
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) = 0 then
    return query select false, p_appointment_group_id, v_ids,
      'INVALID_ALLOCATIONS', 'Group booking requires at least one pax allocation.';
    return;
  end if;

  -- The first service establishes the outlet. Every later service is checked
  -- against it before any mutation.
  select s.outlet_id into v_outlet_id
  from public.services s
  where s.id = nullif((p_allocations -> 0) ->> 'service_id', '')::uuid;

  if v_outlet_id is null then
    return query select false, p_appointment_group_id, v_ids,
      'INVALID_SERVICE', 'One pax allocation has an unknown service.';
    return;
  end if;

  if not public.capacity_first_enabled(v_outlet_id) then
    return query
      select * from public.update_appointment_group_with_csp_concrete_legacy(
        p_appointment_group_id, p_customer_id, p_group_name, p_pax_count,
        p_appointment_date, p_allocations, p_type, p_status, p_notes, p_updated_by
      );
    return;
  end if;

  -- The capacity-first path owns the group revision lock. Keep the flag-OFF
  -- delegate free of this extra lock so its legacy concrete behaviour is not
  -- changed merely by installing this corrective migration.
  select * into v_group
  from public.appointment_groups g
  where g.id = p_appointment_group_id
  for update;
  if not found then
    return query select false, p_appointment_group_id, v_ids,
      'NOT_FOUND', 'Appointment group was not found.';
    return;
  end if;

  -- Serialise revisions that can alter demand on either the old or new service
  -- date. Sorting keeps two simultaneous date moves deadlock-free.
  v_old_date := v_group.appointment_date;
  perform set_config('lock_timeout', '2s', true);
  for v_lock_date in
    select distinct d
    from (values (v_old_date), (p_appointment_date)) dates(d)
    where d is not null
    order by d
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(v_outlet_id::text || ':' || v_lock_date::text, 0)
    );
  end loop;

  -- Lock all current pax before deriving sources / confirmed-resource exceptions.
  perform 1
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id
  order by a.id
  for update;

  select count(*) into v_existing_count
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;

  select exists (
    select 1 from public.transactions t
    where t.appointment_group_id = p_appointment_group_id
      and t.payment_status = 'paid'
      and coalesce(t.source, '') <> 'appointment_addon'
  ) or exists (
    select 1 from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and a.payment_status = 'paid'
  ) into v_group_paid;

  if (
    select count(*) <> count(distinct nullif(value ->> 'appointment_id', ''))
    from jsonb_array_elements(p_allocations)
    where nullif(value ->> 'appointment_id', '') is not null
  ) then
    return query select false, p_appointment_group_id, v_ids,
      'DUPLICATE_APPOINTMENT', 'Each pax allocation must reference a different appointment.';
    return;
  end if;

  if v_group_paid and (
    jsonb_array_length(p_allocations) <> v_existing_count
    or exists (
      select 1 from jsonb_array_elements(p_allocations) x
      where nullif(x.value ->> 'appointment_id', '') is null
    )
  ) then
    return query select false, p_appointment_group_id, v_ids,
      'PAID_GROUP_LOCKED', 'Paid group pax cannot be added or removed.';
    return;
  end if;

  -- Build one normalized revision and one full demand set before updating even
  -- the group header. Normal queue/gender pax intentionally discard UI-supplied
  -- concrete IDs; requested/manual/confirmed pax retain their concrete IDs.
  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_service_id := nullif(v_allocation ->> 'service_id', '')::uuid;
    v_start := nullif(v_allocation ->> 'start_time', '')::time;
    v_end := nullif(v_allocation ->> 'end_time', '')::time;

    if v_existing_id is not null then
      select * into v_existing from public.appointments a
      where a.id = v_existing_id and a.appointment_group_id = p_appointment_group_id;
      if not found then
        return query select false, p_appointment_group_id, v_ids,
          'INVALID_APPOINTMENT', 'A pax allocation does not belong to this group.';
        return;
      end if;
    else
      v_existing := null;
    end if;

    if v_service_id is null or v_start is null or v_end is null or v_end = v_start then
      return query select false, p_appointment_group_id, v_ids,
        'INVALID_ALLOCATION', 'One pax allocation has a missing service or invalid time range.';
      return;
    end if;

    select s.outlet_id, coalesce(s.buffer_after_minutes, 0),
           lower(coalesce(s.room_type::text, ''))
      into v_outlet_id, v_buffer, v_room_type
    from public.services s where s.id = v_service_id;
    if v_outlet_id is null or v_outlet_id <> (select s.outlet_id from public.services s where s.id = nullif((p_allocations -> 0) ->> 'service_id', '')::uuid) then
      return query select false, p_appointment_group_id, v_ids,
        'INVALID_SERVICE', 'All pax services must belong to the group outlet.';
      return;
    end if;

    v_source := coalesce(nullif(v_allocation ->> 'assignment_source', ''),
                         v_existing.assignment_source, 'queue');
    if v_source not in ('queue', 'gender_preference', 'specific_customer_request', 'manual_override') then
      return query select false, p_appointment_group_id, v_ids,
        'INVALID_ASSIGNMENT_SOURCE', 'One pax allocation has an invalid assignment source.';
      return;
    end if;
    v_requested_gender := coalesce(nullif(v_allocation ->> 'requested_gender', ''), v_existing.requested_gender);
    v_is_concrete := v_source in ('specific_customer_request', 'manual_override')
                     or v_existing.resources_confirmed_at is not null;

    if v_is_concrete then
      -- Existing confirmed/requested/manual bindings win over accidental UI edits.
      v_therapist_id := coalesce(v_existing.therapist_id,
        nullif(v_allocation ->> 'therapist_id', '')::uuid);
      v_room_id := coalesce(v_existing.room_id,
        nullif(v_allocation ->> 'room_id', '')::uuid);
      v_requested_therapist_id := coalesce(v_existing.requested_therapist_id,
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid, v_therapist_id);
      if v_therapist_id is null or v_room_id is null then
        return query select false, p_appointment_group_id, v_ids,
          'CONCRETE_RESOURCE_REQUIRED', 'A requested, manually assigned, or confirmed pax needs both concrete resources.';
        return;
      end if;
    else
      v_therapist_id := null;
      v_room_id := null;
      v_requested_therapist_id := null;
    end if;

    v_normalized := v_normalized || jsonb_build_array(v_allocation || jsonb_build_object(
      'appointment_id', v_existing_id, 'service_id', v_service_id,
      'therapist_id', v_therapist_id, 'room_id', v_room_id,
      'assignment_source', v_source, 'requested_gender', v_requested_gender,
      'requested_therapist_id', v_requested_therapist_id,
      'is_concrete_exception', v_is_concrete
    ));
    v_demands := v_demands || jsonb_build_array(jsonb_build_object(
      'start', to_char(public.csp_start_at(p_appointment_date, v_start), 'YYYY-MM-DD HH24:MI:SS'),
      'duration_minutes', ceil(extract(epoch from (
        public.csp_end_at(p_appointment_date, v_start, v_end)
        - public.csp_start_at(p_appointment_date, v_start))) / 60.0)::integer,
      'buffer_after_minutes', v_buffer, 'service_id', v_service_id::text,
      'room_type', v_room_type, 'requested_gender', v_requested_gender,
      'requested_therapist_id', case when v_source = 'specific_customer_request' then v_requested_therapist_id::text else null end,
      'manual_lock_id', case when v_source = 'manual_override' then v_therapist_id::text else null end,
      'pax_index', v_index
    ));
    v_index := v_index + 1;
  end loop;

  v_feasible := public.capacity_feasible(
    (select s.outlet_id from public.services s where s.id = nullif((p_allocations -> 0) ->> 'service_id', '')::uuid),
    v_demands, 'hard', null, p_appointment_group_id
  );
  if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
    return query select false, p_appointment_group_id, v_ids,
      case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end,
      'The revised group exceeds available ' || coalesce(v_feasible ->> 'dimension', 'therapist') || ' capacity.';
    return;
  end if;

  -- Exact concrete exceptions still need exact-id conflict checks; the matching
  -- engine intentionally treats normal pax as anonymous capacity demand.
  for v_allocation in select value from jsonb_array_elements(v_normalized) loop
    if coalesce((v_allocation ->> 'is_concrete_exception')::boolean, false) then
      select * into v_check from public.check_booking_availability(
        p_appointment_date, (v_allocation ->> 'start_time')::time,
        (v_allocation ->> 'end_time')::time,
        (v_allocation ->> 'therapist_id')::uuid, (v_allocation ->> 'room_id')::uuid,
        nullif(v_allocation ->> 'appointment_id', '')::uuid, p_appointment_group_id
      );
      if not coalesce(v_check.therapist_available, false) then
        return query select false, p_appointment_group_id, v_ids,
          'THERAPIST_UNAVAILABLE', 'A preserved concrete therapist is unavailable.';
        return;
      end if;

      select count(*) into v_conflicts
      from jsonb_array_elements(v_normalized) other
      where coalesce((other.value ->> 'is_concrete_exception')::boolean, false)
        and nullif(other.value ->> 'therapist_id', '')::uuid = (v_allocation ->> 'therapist_id')::uuid
        and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time)
              < public.csp_end_at(p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time)
        and public.csp_end_at(p_appointment_date, (other.value ->> 'start_time')::time, (other.value ->> 'end_time')::time)
              > public.csp_start_at(p_appointment_date, (v_allocation ->> 'start_time')::time);
      if v_conflicts > 1 then
        return query select false, p_appointment_group_id, v_ids,
          'THERAPIST_UNAVAILABLE', 'The same concrete therapist cannot serve overlapping group pax.';
        return;
      end if;

      select count(*) into v_room_slots
      from jsonb_array_elements(v_normalized) other
      where coalesce((other.value ->> 'is_concrete_exception')::boolean, false)
        and nullif(other.value ->> 'room_id', '')::uuid = (v_allocation ->> 'room_id')::uuid
        and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time)
              < public.csp_end_at(p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time)
        and public.csp_end_at(p_appointment_date, (other.value ->> 'start_time')::time, (other.value ->> 'end_time')::time)
              > public.csp_start_at(p_appointment_date, (v_allocation ->> 'start_time')::time);
      if coalesce(v_check.room_booked_slots, 0) + v_room_slots > coalesce(v_check.room_total_slots, 1) then
        return query select false, p_appointment_group_id, v_ids,
          'ROOM_FULL', 'A preserved concrete room does not have enough slots for this group.';
        return;
      end if;
    end if;
  end loop;

  -- Apply only after every validation above has succeeded. The transaction and
  -- group-row lock make this all-or-none, including paid-group membership rules.
  update public.appointment_groups g
  set customer_id = p_customer_id, group_name = coalesce(p_group_name, ''),
      pax_count = jsonb_array_length(v_normalized), appointment_date = p_appointment_date,
      status = coalesce(nullif(p_status, ''), 'confirmed'), notes = coalesce(p_notes, '')
  where g.id = p_appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(v_normalized) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    if v_existing_id is not null then
      update public.appointments a set
        customer_id = p_customer_id, therapist_id = nullif(v_allocation ->> 'therapist_id', '')::uuid,
        room_id = nullif(v_allocation ->> 'room_id', '')::uuid,
        service_id = (v_allocation ->> 'service_id')::uuid, appointment_date = p_appointment_date,
        start_time = (v_allocation ->> 'start_time')::time, end_time = (v_allocation ->> 'end_time')::time,
        start_at = public.csp_start_at(p_appointment_date, (v_allocation ->> 'start_time')::time),
        end_at = public.csp_end_at(p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time),
        booked_date = case when a.actual_started_at is null then p_appointment_date else a.booked_date end,
        booked_start_time = case when a.actual_started_at is null then (v_allocation ->> 'start_time')::time else a.booked_start_time end,
        booked_end_time = case when a.actual_started_at is null then (v_allocation ->> 'end_time')::time else a.booked_end_time end,
        booked_start_at = case when a.actual_started_at is null then public.csp_start_at(p_appointment_date, (v_allocation ->> 'start_time')::time) at time zone 'Asia/Kuala_Lumpur' else a.booked_start_at end,
        booked_end_at = case when a.actual_started_at is null then public.csp_end_at(p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time) at time zone 'Asia/Kuala_Lumpur' else a.booked_end_at end,
        total_price = coalesce((v_allocation ->> 'total_price')::numeric, 0),
        type = coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
        service_name = coalesce(v_allocation ->> 'service_name', ''),
        service_items = coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        item_count = greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
        notes = coalesce(v_allocation ->> 'notes', ''), assignment_source = v_allocation ->> 'assignment_source',
        requested_therapist_id = nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        requested_gender = nullif(v_allocation ->> 'requested_gender', ''),
        is_provisional = coalesce((v_allocation ->> 'is_provisional')::boolean, a.is_provisional),
        updated_at = now(), updated_by = p_updated_by
      where a.id = v_existing_id and a.appointment_group_id = p_appointment_group_id
      returning a.id into v_saved_id;
    else
      insert into public.appointments (
        appointment_group_id, customer_id, therapist_id, room_id, service_id,
        appointment_date, start_time, end_time, start_at, end_at, status, total_price,
        booked_date, booked_start_time, booked_end_time, booked_start_at, booked_end_at,
        type, service_name, service_items, item_count, notes, created_at, created_by,
        assignment_source, requested_therapist_id, requested_gender, is_provisional
      ) values (
        p_appointment_group_id, p_customer_id, nullif(v_allocation ->> 'therapist_id', '')::uuid,
        nullif(v_allocation ->> 'room_id', '')::uuid, (v_allocation ->> 'service_id')::uuid,
        p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time,
        public.csp_start_at(p_appointment_date, (v_allocation ->> 'start_time')::time),
        public.csp_end_at(p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time),
        'confirmed', coalesce((v_allocation ->> 'total_price')::numeric, 0),
        p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time,
        public.csp_start_at(p_appointment_date, (v_allocation ->> 'start_time')::time) at time zone 'Asia/Kuala_Lumpur',
        public.csp_end_at(p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time) at time zone 'Asia/Kuala_Lumpur',
        coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
        coalesce(v_allocation ->> 'service_name', ''), coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
        coalesce(v_allocation ->> 'notes', ''), now(), p_updated_by,
        v_allocation ->> 'assignment_source', nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        nullif(v_allocation ->> 'requested_gender', ''), coalesce((v_allocation ->> 'is_provisional')::boolean, false)
      ) returning id into v_saved_id;
    end if;
    v_ids := array_append(v_ids, v_saved_id);
  end loop;

  if not v_group_paid then
    delete from public.appointments a
    where a.appointment_group_id = p_appointment_group_id and not (a.id = any(v_ids));
  end if;

  return query select true, p_appointment_group_id, v_ids, null::text, null::text;
end;
$function$;

revoke all on function public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid) from public, anon;
grant execute on function public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid) to authenticated, service_role;

commit;
