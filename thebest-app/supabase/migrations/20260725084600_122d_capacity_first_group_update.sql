-- Phase 6B.1: capacity-first-safe edits for existing appointment groups.
--
-- Safety properties:
--   * feature flag OFF delegates immediately to the deployed concrete function;
--   * feature flag ON rejects cross-outlet moves;
--   * the full revised group is capacity-validated before any write;
--   * queue/gender-preference pax remain anonymous;
--   * requested/manual and independently confirmed therapist/room bindings are
--     preserved without requiring both dimensions to be concrete;
--   * started, completed, cancelled, no-show, or resource-confirmed groups are
--     not editable through this RPC;
--   * omitted pax are deleted only when operationally removable;
--   * group-internal concrete conflicts include cleanup buffers;
--   * no-op updates are skipped with IS DISTINCT FROM guards.
--
-- It also corrects normalize_appointment_assignment_states so therapist and room
-- confirmation can be represented independently (for example exact therapist +
-- anonymous room, or manual room + anonymous therapist).
--
-- Flag-OFF trigger compatibility (Step 2B): the flag-OFF branch below was
-- diffed against the deployed pg_get_functiondef of
-- public.normalize_appointment_assignment_states(). The deployed body begins by
-- normalizing therapist_assignment_state and room_assignment_state to 'pending'
-- when NULL/empty. Those two statements are hoisted above the flag branch here
-- so the flag-OFF path is behaviourally identical to the deployed function,
-- statement for statement.
--
-- No explicit BEGIN/COMMIT: every supported apply mechanism (supabase db push,
-- the Supabase MCP apply_migration tool) already wraps a migration in a single
-- transaction, and an inner COMMIT would break that guarantee.

do $preflight$
begin
  if to_regprocedure(
       'public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'
     ) is null then
    raise exception '122d requires update_appointment_group_with_csp';
  end if;

  if to_regprocedure(
       'public.update_appointment_group_with_csp_concrete_legacy(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'
     ) is not null then
    raise exception
      '122d cannot continue: update_appointment_group_with_csp_concrete_legacy already exists';
  end if;

  if to_regprocedure(
       'public.capacity_feasible(uuid,jsonb,text,uuid,uuid)'
     ) is null then
    raise exception '122d requires capacity_feasible';
  end if;
end;
$preflight$;

alter function public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) rename to update_appointment_group_with_csp_concrete_legacy;

-- Step 2A: the rename carried the deployed ACL (which included authenticated)
-- onto the legacy name. Revoke it so an authenticated client cannot call the
-- concrete implementation directly and bypass the capacity-first wrapper.
revoke all on function public.update_appointment_group_with_csp_concrete_legacy(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) from public, anon, authenticated, service_role;

create or replace function public.normalize_appointment_assignment_states()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $function$
declare
  v_cf_enabled boolean;
begin
  -- Deployed prologue, shared by both branches. Verified against the live
  -- pg_get_functiondef; it must run before any other assignment-state logic.
  new.therapist_assignment_state := coalesce(
    nullif(new.therapist_assignment_state, ''),
    'pending'
  );
  new.room_assignment_state := coalesce(
    nullif(new.room_assignment_state, ''),
    'pending'
  );

  v_cf_enabled := public.capacity_first_enabled(new.outlet_id);

  if not v_cf_enabled then
    -- Preserve exact deployed 112/116 behavior:
    if new.actual_started_at is not null
       or new.status::text in ('in_progress', 'completed')
       or new.type::text = 'walkin' then
      new.therapist_assignment_state := 'confirmed';
      new.room_assignment_state := 'confirmed';
      new.resources_confirmed_at := coalesce(
        new.resources_confirmed_at,
        new.actual_started_at,
        now()
      );
      new.resources_confirmed_by := coalesce(new.resources_confirmed_by, auth.uid());
    elsif new.assignment_source in (
      'specific_customer_request',
      'manual_override'
    ) then
      new.therapist_assignment_state := 'confirmed';
    end if;

    if new.therapist_assignment_state = 'auto_assigned' then
      new.therapist_auto_assigned_at := coalesce(
        new.therapist_auto_assigned_at,
        now()
      );
    end if;

    if new.therapist_assignment_state = 'confirmed'
       and new.room_assignment_state = 'confirmed' then
      new.resources_confirmed_at := coalesce(
        new.resources_confirmed_at,
        now()
      );
    end if;

    return new;
  end if;

  -- Capacity-first (flag ON) behavior. Step 2D: an absent concrete resource
  -- always reads back as 'pending' on its own dimension.
  if new.therapist_id is null then
    new.therapist_assignment_state := 'pending';
    new.therapist_auto_assigned_at := null;
  end if;

  if new.room_id is null then
    new.room_assignment_state := 'pending';
    new.room_unit_id := null;
    new.room_unit_name := '';
  end if;

  if new.actual_started_at is not null
     or new.status::text in ('in_progress', 'completed')
     or new.type::text = 'walkin' then
    new.therapist_assignment_state := 'confirmed';
    new.room_assignment_state := 'confirmed';
    new.resources_confirmed_at := coalesce(
      new.resources_confirmed_at,
      new.actual_started_at,
      now()
    );
    new.resources_confirmed_by := coalesce(
      new.resources_confirmed_by,
      auth.uid()
    );
  else
    if new.assignment_source = 'specific_customer_request'
       and new.therapist_id is not null then
      new.therapist_assignment_state := 'confirmed';
    elsif new.assignment_source = 'manual_override' then
      if new.therapist_id is not null then
        new.therapist_assignment_state := 'confirmed';
      end if;
      if new.room_id is not null then
        new.room_assignment_state := 'confirmed';
      end if;
    end if;
  end if;

  if new.therapist_assignment_state = 'auto_assigned'
     and new.therapist_id is not null then
    new.therapist_auto_assigned_at := coalesce(
      new.therapist_auto_assigned_at,
      now()
    );
  end if;

  if new.therapist_assignment_state = 'confirmed'
     and new.room_assignment_state = 'confirmed' then
    new.resources_confirmed_at := coalesce(
      new.resources_confirmed_at,
      now()
    );
  elsif new.actual_started_at is null
        and new.status::text not in ('in_progress', 'completed') then
    new.resources_confirmed_at := null;
    new.resources_confirmed_by := null;
  end if;

  return new;
end;
$function$;

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
set search_path = pg_catalog, public
as $function$
declare
  v_group public.appointment_groups%rowtype;
  v_existing public.appointments%rowtype;
  v_allocation jsonb;
  v_normalized jsonb := '[]'::jsonb;
  v_demands jsonb := '[]'::jsonb;
  v_feasible jsonb;

  v_old_outlet_id uuid;
  v_new_outlet_id uuid;
  v_service_outlet_id uuid;
  v_service_id uuid;
  v_existing_id uuid;
  v_saved_id uuid;

  v_input_therapist_id uuid;
  v_input_room_id uuid;
  v_input_room_unit_id uuid;
  v_target_therapist_id uuid;
  v_target_room_id uuid;
  v_target_room_unit_id uuid;
  v_target_room_unit_name text;
  v_requested_therapist_id uuid;

  v_source text;
  v_requested_gender text;
  v_target_therapist_state text;
  v_target_room_state text;
  v_preserve_therapist boolean;
  v_preserve_room boolean;
  v_has_existing boolean;

  v_start time without time zone;
  v_end time without time zone;
  v_start_at timestamp;
  v_end_at timestamp;
  v_block_end_at timestamp;
  v_buffer integer;
  v_room_type text;
  v_index integer := 0;

  v_existing_count integer;
  v_group_paid boolean;
  v_ids uuid[] := array[]::uuid[];
  v_previous_lock_timeout text;
  v_lock_date date;

  v_external_room_usage integer;
  v_internal_room_usage integer;
  v_room_total_slots integer;
  v_internal_therapist_usage integer;
  v_omitted record;
begin
  -- A single read is required only to locate the existing outlet flag.
  -- Missing/legacy-unknown groups are delegated so flag-OFF behavior remains
  -- the deployed concrete behavior.
  select g.*
  into v_group
  from public.appointment_groups g
  where g.id = p_appointment_group_id;

  if not found then
    return query
      select *
      from public.update_appointment_group_with_csp_concrete_legacy(
        p_appointment_group_id,
        p_customer_id,
        p_group_name,
        p_pax_count,
        p_appointment_date,
        p_allocations,
        p_type,
        p_status,
        p_notes,
        p_updated_by
      );
    return;
  end if;

  v_old_outlet_id := coalesce(
    v_group.outlet_id,
    (
      select min(a.outlet_id::text)::uuid
      from public.appointments a
      where a.appointment_group_id = p_appointment_group_id
    )
  );

  if v_old_outlet_id is null
     or not public.capacity_first_enabled(v_old_outlet_id) then
    return query
      select *
      from public.update_appointment_group_with_csp_concrete_legacy(
        p_appointment_group_id,
        p_customer_id,
        p_group_name,
        p_pax_count,
        p_appointment_date,
        p_allocations,
        p_type,
        p_status,
        p_notes,
        p_updated_by
      );
    return;
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) = 0 then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'INVALID_ALLOCATIONS',
      'Group booking requires at least one pax allocation.';
    return;
  end if;

  -- Resolve all proposed services before locking. Every allocation must have a
  -- valid service and all services must remain in the existing outlet.
  select
    count(*) filter (where s.id is not null),
    count(distinct s.outlet_id),
    min(s.outlet_id::text)::uuid
  into
    v_existing_count,
    v_index,
    v_new_outlet_id
  from jsonb_array_elements(p_allocations) item
  left join public.services s
    on s.id = nullif(item.value ->> 'service_id', '')::uuid;

  if v_existing_count <> jsonb_array_length(p_allocations)
     or v_index <> 1
     or v_new_outlet_id is null then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'INVALID_SERVICE',
      'Every pax needs a valid service from one outlet.';
    return;
  end if;

  if v_new_outlet_id is distinct from v_old_outlet_id then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'CROSS_OUTLET_MOVE_NOT_SUPPORTED',
      'A capacity-first group cannot be moved to another outlet.';
    return;
  end if;

  -- Lock the group, then old/new outlet-date keys in deterministic date order.
  select g.*
  into v_group
  from public.appointment_groups g
  where g.id = p_appointment_group_id
  for update;

  if not found then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'NOT_FOUND',
      'Appointment group was not found.';
    return;
  end if;

  if lower(coalesce(v_group.status, '')) in (
       'in_progress', 'completed', 'cancelled', 'no_show'
     ) then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'GROUP_NOT_EDITABLE',
      'Started or terminal appointment groups cannot be edited.';
    return;
  end if;

  v_previous_lock_timeout := current_setting('lock_timeout', true);
  perform set_config('lock_timeout', '2s', true);

  begin
    for v_lock_date in
      select distinct d
      from (
        values (v_group.appointment_date), (p_appointment_date)
      ) dates(d)
      where d is not null
      order by d
    loop
      perform pg_advisory_xact_lock(
        hashtextextended(
          v_old_outlet_id::text || ':' || v_lock_date::text,
          0
        )
      );
    end loop;
  exception
    when lock_not_available then
      perform set_config(
        'lock_timeout',
        coalesce(v_previous_lock_timeout, '0'),
        true
      );
      return query select
        false,
        p_appointment_group_id,
        v_ids,
        'RESOURCE_LOCK_TIMEOUT',
        'The appointment group is being changed elsewhere. Please retry.';
      return;
  end;

  perform set_config(
    'lock_timeout',
    coalesce(v_previous_lock_timeout, '0'),
    true
  );

  perform 1
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id
  order by a.id
  for update;

  if exists (
    select 1
    from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and (
        a.resources_confirmed_at is not null
        or a.actual_started_at is not null
        or a.status::text in (
          'in_progress', 'completed', 'cancelled', 'no_show'
        )
      )
  ) then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'GROUP_NOT_EDITABLE',
      'A started, terminal, or fully resource-confirmed pax cannot be edited.';
    return;
  end if;

  select count(*)
  into v_existing_count
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;

  select
    exists (
      select 1
      from public.transactions t
      where t.appointment_group_id = p_appointment_group_id
        and t.payment_status = 'paid'
        and coalesce(t.source, '') <> 'appointment_addon'
    )
    or exists (
      select 1
      from public.appointments a
      where a.appointment_group_id = p_appointment_group_id
        and a.payment_status = 'paid'
    )
  into v_group_paid;

  if (
    select count(*) <> count(
      distinct nullif(item.value ->> 'appointment_id', '')
    )
    from jsonb_array_elements(p_allocations) item
    where nullif(item.value ->> 'appointment_id', '') is not null
  ) then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'DUPLICATE_APPOINTMENT',
      'Each pax allocation must reference a different appointment.';
    return;
  end if;

  if v_group_paid and (
    jsonb_array_length(p_allocations) <> v_existing_count
    or exists (
      select 1
      from jsonb_array_elements(p_allocations) item
      where nullif(item.value ->> 'appointment_id', '') is null
    )
  ) then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      'PAID_GROUP_LOCKED',
      'Paid group pax cannot be added or removed.';
    return;
  end if;

  -- Omitted rows are removable only when they are future, unpaid, unstarted,
  -- not fully confirmed, and carry no independently confirmed resource.
  for v_omitted in
    select a.*
    from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and not exists (
        select 1
        from jsonb_array_elements(p_allocations) item
        where nullif(item.value ->> 'appointment_id', '')::uuid = a.id
      )
  loop
    if v_omitted.payment_status <> 'unpaid'
       or v_omitted.actual_started_at is not null
       or v_omitted.resources_confirmed_at is not null
       or v_omitted.status::text not in ('pending', 'confirmed')
       or v_omitted.therapist_assignment_state = 'confirmed'
       or v_omitted.room_assignment_state = 'confirmed'
       or public.csp_appointment_start_at(v_omitted)
            <= (now() at time zone 'Asia/Kuala_Lumpur') then
      return query select
        false,
        p_appointment_group_id,
        v_ids,
        'PAX_NOT_REMOVABLE',
        'One omitted pax is paid, started, protected, terminal, or no longer future.';
      return;
    end if;
  end loop;

  -- Build normalized rows and the complete revised demand set before any write.
  v_index := 0;

  for v_allocation in
    select item.value
    from jsonb_array_elements(p_allocations) item
  loop
    v_existing := null;
    v_has_existing := false;

    v_existing_id :=
      nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_service_id :=
      nullif(v_allocation ->> 'service_id', '')::uuid;
    v_start :=
      nullif(v_allocation ->> 'start_time', '')::time;
    v_end :=
      nullif(v_allocation ->> 'end_time', '')::time;

    if v_existing_id is not null then
      select a.*
      into v_existing
      from public.appointments a
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id;

      if not found then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'INVALID_APPOINTMENT',
          'A pax allocation does not belong to this group.';
        return;
      end if;

      v_has_existing := true;
    end if;

    if v_service_id is null
       or v_start is null
       or v_end is null
       or v_end = v_start then
      return query select
        false,
        p_appointment_group_id,
        v_ids,
        'INVALID_ALLOCATION',
        'One pax allocation has a missing service or invalid time range.';
      return;
    end if;

    select
      s.outlet_id,
      coalesce(s.buffer_after_minutes, 0),
      lower(trim(s.room_type::text))
    into
      v_service_outlet_id,
      v_buffer,
      v_room_type
    from public.services s
    where s.id = v_service_id;

    if v_service_outlet_id is distinct from v_old_outlet_id then
      return query select
        false,
        p_appointment_group_id,
        v_ids,
        'INVALID_SERVICE',
        'Every pax service must belong to the existing group outlet.';
      return;
    end if;

    v_start_at :=
      public.csp_start_at(p_appointment_date, v_start);
    v_end_at :=
      public.csp_end_at(p_appointment_date, v_start, v_end);
    v_block_end_at :=
      v_end_at + make_interval(mins => greatest(v_buffer, 0));

    v_source := coalesce(
      nullif(v_allocation ->> 'assignment_source', ''),
      case when v_has_existing then v_existing.assignment_source end,
      'queue'
    );

    if v_source not in (
      'queue',
      'gender_preference',
      'specific_customer_request',
      'manual_override'
    ) then
      return query select
        false,
        p_appointment_group_id,
        v_ids,
        'INVALID_ASSIGNMENT_SOURCE',
        'One pax allocation has an invalid assignment source.';
      return;
    end if;

    -- A protected existing resource cannot be downgraded by changing only the
    -- assignment_source field in the UI.
    if v_has_existing
       and (
         v_existing.therapist_assignment_state = 'confirmed'
         or v_existing.room_assignment_state = 'confirmed'
       ) then
      v_source := v_existing.assignment_source;
    end if;

    v_requested_gender := coalesce(
      nullif(v_allocation ->> 'requested_gender', ''),
      case when v_has_existing then v_existing.requested_gender end
    );

    v_input_therapist_id :=
      nullif(v_allocation ->> 'therapist_id', '')::uuid;
    v_input_room_id :=
      nullif(v_allocation ->> 'room_id', '')::uuid;
    v_input_room_unit_id :=
      nullif(v_allocation ->> 'room_unit_id', '')::uuid;

    v_target_therapist_id := null;
    v_target_room_id := null;
    v_target_room_unit_id := null;
    v_target_room_unit_name := '';
    v_target_therapist_state := 'pending';
    v_target_room_state := 'pending';

    v_preserve_therapist :=
      v_has_existing
      and v_existing.therapist_id is not null
      and v_existing.therapist_assignment_state = 'confirmed';

    v_preserve_room :=
      v_has_existing
      and v_existing.room_id is not null
      and v_existing.room_assignment_state = 'confirmed';

    if v_source = 'specific_customer_request' then
      v_requested_therapist_id := coalesce(
        case
          when v_has_existing then v_existing.requested_therapist_id
        end,
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        v_input_therapist_id,
        case when v_has_existing then v_existing.therapist_id end
      );

      if v_requested_therapist_id is null then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'REQUESTED_THERAPIST_REQUIRED',
          'A specific customer request needs an exact therapist.';
        return;
      end if;

      if v_preserve_therapist
         and v_existing.therapist_id is distinct from
             v_requested_therapist_id then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'PROTECTED_THERAPIST_CONFLICT',
          'A protected therapist cannot be silently replaced.';
        return;
      end if;

      v_target_therapist_id := coalesce(
        case
          when v_preserve_therapist then v_existing.therapist_id
        end,
        v_requested_therapist_id
      );
      v_target_therapist_state := 'confirmed';

      if v_preserve_room then
        v_target_room_id := v_existing.room_id;
        v_target_room_unit_id := v_existing.room_unit_id;
        v_target_room_unit_name := coalesce(
          v_existing.room_unit_name,
          ''
        );
        v_target_room_state := 'confirmed';
      end if;

    elsif v_source = 'manual_override' then
      if v_preserve_therapist
         and v_input_therapist_id is not null
         and v_existing.therapist_id is distinct from
             v_input_therapist_id then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'PROTECTED_THERAPIST_CONFLICT',
          'A protected therapist cannot be silently replaced.';
        return;
      end if;

      if v_preserve_room
         and v_input_room_id is not null
         and v_existing.room_id is distinct from v_input_room_id then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'PROTECTED_ROOM_CONFLICT',
          'A protected room cannot be silently replaced.';
        return;
      end if;

      v_target_therapist_id := coalesce(
        case
          when v_preserve_therapist then v_existing.therapist_id
        end,
        v_input_therapist_id
      );

      v_target_room_id := coalesce(
        case
          when v_preserve_room then v_existing.room_id
        end,
        v_input_room_id
      );

      if v_target_therapist_id is null
         and v_target_room_id is null then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'MANUAL_RESOURCE_REQUIRED',
          'A manual override must lock a therapist, a room, or both.';
        return;
      end if;

      if v_target_therapist_id is not null then
        v_target_therapist_state := 'confirmed';
      end if;

      if v_target_room_id is not null then
        v_target_room_state := 'confirmed';

        if v_preserve_room
           and v_existing.room_id = v_target_room_id then
          v_target_room_unit_id := v_existing.room_unit_id;
          v_target_room_unit_name := coalesce(
            v_existing.room_unit_name,
            ''
          );
        else
          v_target_room_unit_id := v_input_room_unit_id;
        end if;
      end if;

      v_requested_therapist_id := coalesce(
        case
          when v_has_existing then v_existing.requested_therapist_id
        end,
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid
      );

    else
      -- queue / gender_preference remain anonymous unless a pre-existing
      -- independently confirmed dimension must be preserved.
      if v_preserve_therapist then
        v_target_therapist_id := v_existing.therapist_id;
        v_target_therapist_state := 'confirmed';
      end if;

      if v_preserve_room then
        v_target_room_id := v_existing.room_id;
        v_target_room_unit_id := v_existing.room_unit_id;
        v_target_room_unit_name := coalesce(
          v_existing.room_unit_name,
          ''
        );
        v_target_room_state := 'confirmed';
      end if;

      v_requested_therapist_id := case
        when v_preserve_therapist
          then v_existing.requested_therapist_id
        else null
      end;
    end if;

    if v_target_therapist_id is not null
       and not exists (
         select 1
         from public.therapists t
         where t.id = v_target_therapist_id
           and t.outlet_id = v_old_outlet_id
           and coalesce(t.availability_status, true)
           and lower(coalesce(t.role, 'therapist')) = 'therapist'
       ) then
      return query select
        false,
        p_appointment_group_id,
        v_ids,
        'INVALID_THERAPIST',
        'A preserved or requested therapist is not active in this outlet.';
      return;
    end if;

    if v_target_room_id is not null then
      if not exists (
        select 1
        from public.rooms r
        where r.id = v_target_room_id
          and r.outlet_id = v_old_outlet_id
          and coalesce(r.is_active, true)
          and lower(
            trim(
              coalesce(
                nullif(r.room_type, ''),
                r.type::text,
                ''
              )
            )
          ) = v_room_type
      ) then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'INVALID_ROOM',
          'A preserved or manually selected room is invalid for the service.';
        return;
      end if;

      if v_target_room_unit_id is not null then
        select coalesce(u.name, '')
        into v_target_room_unit_name
        from public.room_units u
        where u.id = v_target_room_unit_id
          and u.zone_id = v_target_room_id
          and u.outlet_id = v_old_outlet_id
          and u.is_active;

        if not found then
          return query select
            false,
            p_appointment_group_id,
            v_ids,
            'INVALID_ROOM_UNIT',
            'The selected room unit is not active in the selected room zone.';
          return;
        end if;
      end if;
    else
      v_target_room_unit_id := null;
      v_target_room_unit_name := '';
      v_target_room_state := 'pending';
    end if;

    v_normalized := v_normalized || jsonb_build_array(
      v_allocation || jsonb_build_object(
        'appointment_id', v_existing_id,
        'service_id', v_service_id,
        'therapist_id', v_target_therapist_id,
        'room_id', v_target_room_id,
        'room_unit_id', v_target_room_unit_id,
        'room_unit_name', v_target_room_unit_name,
        'assignment_source', v_source,
        'requested_gender', v_requested_gender,
        'requested_therapist_id', v_requested_therapist_id,
        'therapist_assignment_state', v_target_therapist_state,
        'room_assignment_state', v_target_room_state,
        'buffer_after_minutes', v_buffer,
        'room_type', v_room_type,
        'start_at', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'end_at', to_char(v_end_at, 'YYYY-MM-DD HH24:MI:SS'),
        'block_end_at', to_char(v_block_end_at, 'YYYY-MM-DD HH24:MI:SS')
      )
    );

    v_demands := v_demands || jsonb_build_array(
      jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes',
          ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::integer,
        'buffer_after_minutes', v_buffer,
        'service_id', v_service_id::text,
        'room_type', v_room_type,
        'requested_gender', v_requested_gender,
        'requested_therapist_id',
          case
            when v_source = 'specific_customer_request'
              then v_target_therapist_id::text
            else null
          end,
        'manual_lock_id',
          case
            when v_target_therapist_id is not null
                 and v_source <> 'specific_customer_request'
              then v_target_therapist_id::text
            else null
          end,
        'pax_index', v_index
      )
    );

    v_index := v_index + 1;
  end loop;

  v_feasible := public.capacity_feasible(
    v_old_outlet_id,
    v_demands,
    'hard',
    null,
    p_appointment_group_id
  );

  if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
    return query select
      false,
      p_appointment_group_id,
      v_ids,
      case
        when v_feasible ->> 'dimension' = 'room'
          then 'ROOM_FULL'
        else 'THERAPIST_UNAVAILABLE'
      end,
      'The revised group exceeds available '
        || coalesce(v_feasible ->> 'dimension', 'therapist')
        || ' capacity.';
    return;
  end if;

  -- Exact room and same-resource checks. Proposed block_end_at includes each
  -- service's cleanup buffer.
  for v_allocation in
    select item.value
    from jsonb_array_elements(v_normalized) item
  loop
    if nullif(v_allocation ->> 'therapist_id', '') is not null then
      select count(*)
      into v_internal_therapist_usage
      from jsonb_array_elements(v_normalized) other
      where nullif(other.value ->> 'therapist_id', '')::uuid
              = (v_allocation ->> 'therapist_id')::uuid
        and (other.value ->> 'start_at')::timestamp
              < (v_allocation ->> 'block_end_at')::timestamp
        and (other.value ->> 'block_end_at')::timestamp
              > (v_allocation ->> 'start_at')::timestamp;

      if v_internal_therapist_usage > 1 then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'THERAPIST_UNAVAILABLE',
          'The same concrete therapist cannot cover overlapping service and cleanup windows.';
        return;
      end if;
    end if;

    if nullif(v_allocation ->> 'room_id', '') is not null then
      select greatest(coalesce(r.total_slots, 1), 1)
      into v_room_total_slots
      from public.rooms r
      where r.id = (v_allocation ->> 'room_id')::uuid;

      select
        (
          select count(*)
          from public.appointments a
          where a.room_id = (v_allocation ->> 'room_id')::uuid
            and a.appointment_group_id is distinct from
                p_appointment_group_id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a)
                  < (v_allocation ->> 'block_end_at')::timestamp
            and public.csp_appointment_block_end_at(a)
                  > (v_allocation ->> 'start_at')::timestamp
        )
        +
        (
          select count(*)
          from public.booking_holds h
          where h.assigned_room_id =
                (v_allocation ->> 'room_id')::uuid
            and h.status = 'pending_payment'
            and h.expires_at > now()
            and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
            and (h.start_at at time zone 'Asia/Kuala_Lumpur')
                  < (v_allocation ->> 'block_end_at')::timestamp
            and (
              (
                h.end_at
                + make_interval(
                    mins => greatest(
                      coalesce(h.buffer_after_minutes, 0),
                      0
                    )
                  )
              ) at time zone 'Asia/Kuala_Lumpur'
            ) > (v_allocation ->> 'start_at')::timestamp
        )
      into v_external_room_usage;

      select count(*)
      into v_internal_room_usage
      from jsonb_array_elements(v_normalized) other
      where nullif(other.value ->> 'room_id', '')::uuid
              = (v_allocation ->> 'room_id')::uuid
        and (other.value ->> 'start_at')::timestamp
              < (v_allocation ->> 'block_end_at')::timestamp
        and (other.value ->> 'block_end_at')::timestamp
              > (v_allocation ->> 'start_at')::timestamp;

      if coalesce(v_external_room_usage, 0)
           + coalesce(v_internal_room_usage, 0)
         > coalesce(v_room_total_slots, 1) then
        return query select
          false,
          p_appointment_group_id,
          v_ids,
          'ROOM_FULL',
          'A preserved or manually selected room lacks enough slots for the full service and cleanup window.';
        return;
      end if;
    end if;
  end loop;

  -- No writes occur before this point.
  update public.appointment_groups g
  set
    customer_id = p_customer_id,
    group_name = coalesce(p_group_name, ''),
    pax_count = jsonb_array_length(v_normalized),
    appointment_date = p_appointment_date,
    status = coalesce(nullif(p_status, ''), 'confirmed'),
    notes = coalesce(p_notes, '')
  where g.id = p_appointment_group_id
    and (
      g.customer_id,
      g.group_name,
      g.pax_count,
      g.appointment_date,
      g.status,
      g.notes
    ) is distinct from (
      p_customer_id,
      coalesce(p_group_name, ''),
      jsonb_array_length(v_normalized),
      p_appointment_date,
      coalesce(nullif(p_status, ''), 'confirmed'),
      coalesce(p_notes, '')
    );

  for v_allocation in
    select item.value
    from jsonb_array_elements(v_normalized) item
  loop
    v_existing_id :=
      nullif(v_allocation ->> 'appointment_id', '')::uuid;

    if v_existing_id is not null then
      update public.appointments a
      set
        customer_id = p_customer_id,
        therapist_id =
          nullif(v_allocation ->> 'therapist_id', '')::uuid,
        room_id =
          nullif(v_allocation ->> 'room_id', '')::uuid,
        room_unit_id =
          nullif(v_allocation ->> 'room_unit_id', '')::uuid,
        room_unit_name =
          coalesce(v_allocation ->> 'room_unit_name', ''),
        service_id =
          (v_allocation ->> 'service_id')::uuid,
        appointment_date = p_appointment_date,
        start_time =
          (v_allocation ->> 'start_time')::time,
        end_time =
          (v_allocation ->> 'end_time')::time,
        start_at =
          (v_allocation ->> 'start_at')::timestamp,
        end_at =
          (v_allocation ->> 'end_at')::timestamp,
        buffer_after_minutes =
          (v_allocation ->> 'buffer_after_minutes')::integer,
        booked_date = p_appointment_date,
        booked_start_time =
          (v_allocation ->> 'start_time')::time,
        booked_end_time =
          (v_allocation ->> 'end_time')::time,
        booked_start_at =
          (v_allocation ->> 'start_at')::timestamp
            at time zone 'Asia/Kuala_Lumpur',
        booked_end_at =
          (v_allocation ->> 'end_at')::timestamp
            at time zone 'Asia/Kuala_Lumpur',
        total_price =
          coalesce((v_allocation ->> 'total_price')::numeric, 0),
        type =
          coalesce(
            nullif(p_type, ''),
            'appointment'
          )::public.appointment_type,
        service_name =
          coalesce(v_allocation ->> 'service_name', ''),
        service_items =
          coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        item_count =
          greatest(
            coalesce((v_allocation ->> 'item_count')::integer, 1),
            1
          ),
        notes =
          coalesce(v_allocation ->> 'notes', ''),
        assignment_source =
          v_allocation ->> 'assignment_source',
        requested_therapist_id =
          nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        requested_gender =
          nullif(v_allocation ->> 'requested_gender', ''),
        therapist_assignment_state =
          v_allocation ->> 'therapist_assignment_state',
        room_assignment_state =
          v_allocation ->> 'room_assignment_state',
        therapist_auto_assigned_at =
          case
            when v_allocation ->> 'therapist_assignment_state'
                   = 'auto_assigned'
              then a.therapist_auto_assigned_at
            else null
          end,
        updated_at = now(),
        updated_by = p_updated_by
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id
        and (
          a.customer_id is distinct from p_customer_id
          or a.therapist_id is distinct from
             nullif(v_allocation ->> 'therapist_id', '')::uuid
          or a.room_id is distinct from
             nullif(v_allocation ->> 'room_id', '')::uuid
          or a.room_unit_id is distinct from
             nullif(v_allocation ->> 'room_unit_id', '')::uuid
          or a.room_unit_name is distinct from
             coalesce(v_allocation ->> 'room_unit_name', '')
          or a.service_id is distinct from
             (v_allocation ->> 'service_id')::uuid
          or a.appointment_date is distinct from p_appointment_date
          or a.start_time is distinct from
             (v_allocation ->> 'start_time')::time
          or a.end_time is distinct from
             (v_allocation ->> 'end_time')::time
          or a.buffer_after_minutes is distinct from
             (v_allocation ->> 'buffer_after_minutes')::integer
          or a.total_price is distinct from
             coalesce((v_allocation ->> 'total_price')::numeric, 0)
          or a.type is distinct from
             coalesce(
               nullif(p_type, ''),
               'appointment'
             )::public.appointment_type
          or a.service_name is distinct from
             coalesce(v_allocation ->> 'service_name', '')
          or a.service_items is distinct from
             coalesce(v_allocation -> 'service_items', '[]'::jsonb)
          or a.item_count is distinct from
             greatest(
               coalesce(
                 (v_allocation ->> 'item_count')::integer,
                 1
               ),
               1
             )
          or a.notes is distinct from
             coalesce(v_allocation ->> 'notes', '')
          or a.assignment_source is distinct from
             (v_allocation ->> 'assignment_source')
          or a.requested_therapist_id is distinct from
             nullif(
               v_allocation ->> 'requested_therapist_id',
               ''
             )::uuid
          or a.requested_gender is distinct from
             nullif(v_allocation ->> 'requested_gender', '')
          or a.therapist_assignment_state is distinct from
             (v_allocation ->> 'therapist_assignment_state')
          or a.room_assignment_state is distinct from
             (v_allocation ->> 'room_assignment_state')
        )
      returning a.id into v_saved_id;

      if not found then
        v_saved_id := v_existing_id;
      end if;
    else
      insert into public.appointments (
        appointment_group_id,
        customer_id,
        therapist_id,
        room_id,
        room_unit_id,
        room_unit_name,
        service_id,
        appointment_date,
        start_time,
        end_time,
        start_at,
        end_at,
        buffer_after_minutes,
        status,
        total_price,
        booked_date,
        booked_start_time,
        booked_end_time,
        booked_start_at,
        booked_end_at,
        type,
        service_name,
        service_items,
        item_count,
        notes,
        created_at,
        created_by,
        assignment_source,
        requested_therapist_id,
        requested_gender,
        therapist_assignment_state,
        room_assignment_state,
        outlet_id
      )
      values (
        p_appointment_group_id,
        p_customer_id,
        nullif(v_allocation ->> 'therapist_id', '')::uuid,
        nullif(v_allocation ->> 'room_id', '')::uuid,
        nullif(v_allocation ->> 'room_unit_id', '')::uuid,
        coalesce(v_allocation ->> 'room_unit_name', ''),
        (v_allocation ->> 'service_id')::uuid,
        p_appointment_date,
        (v_allocation ->> 'start_time')::time,
        (v_allocation ->> 'end_time')::time,
        (v_allocation ->> 'start_at')::timestamp,
        (v_allocation ->> 'end_at')::timestamp,
        (v_allocation ->> 'buffer_after_minutes')::integer,
        'confirmed',
        coalesce((v_allocation ->> 'total_price')::numeric, 0),
        p_appointment_date,
        (v_allocation ->> 'start_time')::time,
        (v_allocation ->> 'end_time')::time,
        (v_allocation ->> 'start_at')::timestamp
          at time zone 'Asia/Kuala_Lumpur',
        (v_allocation ->> 'end_at')::timestamp
          at time zone 'Asia/Kuala_Lumpur',
        coalesce(
          nullif(p_type, ''),
          'appointment'
        )::public.appointment_type,
        coalesce(v_allocation ->> 'service_name', ''),
        coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        greatest(
          coalesce((v_allocation ->> 'item_count')::integer, 1),
          1
        ),
        coalesce(v_allocation ->> 'notes', ''),
        now(),
        p_updated_by,
        v_allocation ->> 'assignment_source',
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        nullif(v_allocation ->> 'requested_gender', ''),
        v_allocation ->> 'therapist_assignment_state',
        v_allocation ->> 'room_assignment_state',
        v_old_outlet_id
      )
      returning id into v_saved_id;
    end if;

    v_ids := array_append(v_ids, v_saved_id);
  end loop;

  delete from public.appointments a
  where a.appointment_group_id = p_appointment_group_id
    and not (a.id = any(v_ids));

  return query select
    true,
    p_appointment_group_id,
    v_ids,
    null::text,
    null::text;
end;
$function$;

-- Restore exactly the deployed wrapper ACL (postgres + authenticated). The
-- deployed function did NOT grant service_role, and this migration must not
-- widen the surface as a side effect.
revoke all on function public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) from public, anon, service_role;

grant execute on function public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) to authenticated;
