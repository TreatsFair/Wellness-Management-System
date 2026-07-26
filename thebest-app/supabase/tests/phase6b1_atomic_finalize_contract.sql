\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_single regprocedure;
  v_group regprocedure;
  v_core regprocedure;
  v_walkin regprocedure;
  v_walkin_group regprocedure;
  v_legacy_core regprocedure;
  v_legacy_single regprocedure;
  v_legacy_group regprocedure;
  v_group_matcher regprocedure;
  v_single_body text;
  v_legacy_single_body text;
  v_group_body text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'appointments'
      and column_name = 'guest_name'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'appointments'
      and column_name = 'guest_phone'
  ) then
    raise exception '122q guest fields are missing';
  end if;

  v_single := to_regprocedure(
    'public.finalize_and_start_appointment(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );
  v_group := to_regprocedure(
    'public.finalize_and_start_appointment_group(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );
  v_core := to_regprocedure(
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  );
  v_walkin := to_regprocedure(
    'public.create_staff_walkin_and_start_with_payment(uuid,uuid,uuid,uuid,uuid,date,time without time zone,time without time zone,numeric,text,jsonb,integer,text,text,text,uuid,text,numeric,numeric,text,text,text,text,text,uuid,text,timestamp with time zone)'
  );
  v_walkin_group := to_regprocedure(
    'public.create_staff_walkin_group_and_start_with_payment(uuid,text,integer,date,jsonb,text,text,text,uuid,text,numeric,numeric,numeric,text,text,text,text,timestamp with time zone)'
  );
  if v_single is null or v_group is null or v_core is null
     or v_walkin is null or v_walkin_group is null then
    raise exception '122q finalisation functions are missing';
  end if;

  select pg_get_functiondef(v_single) into v_single_body;
  select pg_get_functiondef(v_group) into v_group_body;
  v_legacy_core := to_regprocedure(
    'public.finalize_and_start_appointment_core_122q_legacy(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  );
  v_legacy_single := to_regprocedure(
    'public.finalize_and_start_appointment_122q_legacy(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );
  v_legacy_group := to_regprocedure(
    'public.finalize_and_start_appointment_group_122q_legacy(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );
  v_group_matcher := to_regprocedure(
    'public.match_finalize_start_group_therapists(uuid,jsonb,timestamptz)'
  );

  if v_group_matcher is null then
    if v_single_body not ilike '%actual_started_at%'
       or v_single_body not ilike '%payment_status%'
       or v_single_body not ilike '%room_unit_id%'
       or v_single_body not ilike
          '%finalize_and_start_appointment_core%' then
      raise exception '122q single finalisation body is incomplete';
    end if;
    if v_group_body not ilike '%partial_start%'
       or v_group_body not ilike '%pax_updates%'
       or v_group_body not ilike '%finalize_and_start_appointment_core%' then
      raise exception '122q group finalisation body is incomplete';
    end if;
  else
    if v_legacy_core is null
       or v_legacy_single is null
       or v_legacy_group is null
       or v_single_body not ilike '%pg_advisory_xact_lock%'
       or v_single_body not ilike
          '%finalize_and_start_appointment_122q_legacy%'
       or v_group_body not ilike '%match_finalize_start_group_therapists%'
       or v_group_body not ilike
          '%finalize_and_start_appointment_group_122q_legacy%'
       or v_group_body not ilike '%NO_THERAPIST_COMBINATION%' then
      raise exception '122t flexible group finalisation wrapper is incomplete';
    end if;
    select pg_get_functiondef(v_legacy_single) into v_legacy_single_body;
    if v_legacy_single_body not ilike '%actual_started_at%'
       or v_legacy_single_body not ilike '%payment_status%'
       or v_legacy_single_body not ilike '%room_unit_id%'
       or v_legacy_single_body not ilike
          '%finalize_and_start_appointment_core%' then
      raise exception '122t preserved single finalisation body is incomplete';
    end if;
    if has_function_privilege('authenticated', v_legacy_core, 'EXECUTE')
       or has_function_privilege('authenticated', v_legacy_single, 'EXECUTE')
       or has_function_privilege('authenticated', v_legacy_group, 'EXECUTE')
       or has_function_privilege('anon', v_legacy_core, 'EXECUTE')
       or has_function_privilege('anon', v_legacy_single, 'EXECUTE')
       or has_function_privilege('anon', v_legacy_group, 'EXECUTE') then
      raise exception '122t legacy finalisation bodies must remain owner-only';
    end if;
  end if;

  if has_function_privilege(
    'anon',
    v_single,
    'EXECUTE'
  ) or has_function_privilege(
    'anon',
    v_group,
    'EXECUTE'
  ) then
    raise exception 'anonymous role must not execute staff finalisation RPCs';
  end if;
  if not has_function_privilege(
    'authenticated',
    v_single,
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    v_group,
    'EXECUTE'
  ) then
    raise exception 'authenticated staff execution grant is missing';
  end if;
  if has_function_privilege(
    'authenticated',
    v_core,
    'EXECUTE'
  ) then
    raise exception 'authenticated role must not bypass finalisation core';
  end if;
  if not has_function_privilege('authenticated', v_walkin, 'EXECUTE')
     or not has_function_privilege(
       'authenticated',
       v_walkin_group,
       'EXECUTE'
     ) then
    raise exception 'authenticated walk-in start grants are missing';
  end if;
end
$test$;

do $early_specific_room$
declare
  v_outlet uuid;
  v_service uuid;
  v_therapist uuid;
  v_room uuid;
  v_room_unit uuid;
  v_appointment uuid;
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date + 370;
  v_scheduled_start timestamp;
  v_scheduled_end timestamp;
  v_actual_start timestamp;
  v_actual_start_tz timestamptz;
  v_operational_end timestamp;
  v_row public.appointments%rowtype;
begin
  select r.outlet_id, s.id, t.id, r.id, u.id
  into v_outlet, v_service, v_therapist, v_room, v_room_unit
  from public.rooms r
  join public.room_units u
    on u.zone_id = r.id
   and u.outlet_id = r.outlet_id
   and u.is_active
  join public.services s
    on s.outlet_id = r.outlet_id
   and s.is_active
   and lower(s.room_type::text) = lower(r.room_type::text)
  join public.therapists t
    on t.outlet_id = r.outlet_id
   and coalesce(t.availability_status, true)
   and lower(coalesce(t.role, 'therapist')) = 'therapist'
  where r.allocation_mode = 'specific_room'
    and coalesce(r.is_active, true)
  order by r.id, u.unit_number, t.id, s.id
  limit 1;

  if v_room_unit is null then
    raise exception
      '122q regression setup requires an active specific_room unit';
  end if;

  v_scheduled_start := v_date + time '15:00';
  v_scheduled_end := v_date + time '16:00';
  v_actual_start := v_date + time '12:00';
  v_actual_start_tz :=
    v_actual_start at time zone 'Asia/Kuala_Lumpur';
  v_operational_end := v_actual_start + interval '1 hour';

  insert into public.appointments (
    therapist_id, room_id, room_unit_id, service_id,
    appointment_date, start_time, end_time, start_at, end_at,
    booked_date, booked_start_time, booked_end_time,
    booked_start_at, booked_end_at,
    status, payment_status, total_price, type, outlet_id,
    service_name, service_items, item_count, assignment_source,
    requested_therapist_id,
    therapist_assignment_state, room_assignment_state
  ) values (
    v_therapist, v_room, v_room_unit, v_service,
    v_date, time '15:00', time '16:00',
    v_scheduled_start, v_scheduled_end,
    v_date, time '15:00', time '16:00',
    v_scheduled_start at time zone 'Asia/Kuala_Lumpur',
    v_scheduled_end at time zone 'Asia/Kuala_Lumpur',
    'confirmed', 'paid', 0, 'appointment', v_outlet,
    '122q early specific-room regression', '[]'::jsonb, 1,
    'specific_customer_request', v_therapist, 'confirmed', 'confirmed'
  )
  returning id into v_appointment;

  begin
    update public.appointments a
    set status = 'in_progress',
        actual_started_at = v_actual_start_tz,
        -- Deliberately stale here: the room-unit trigger runs before the
        -- actual-start projection trigger corrects this value.
        start_at = v_scheduled_start,
        end_at = v_operational_end
    where a.id = v_appointment;
  exception
    when sqlstate '22023' then
      raise exception
        '122q regression failed with 22023 Invalid room reservation window';
  end;

  select *
  into v_row
  from public.appointments a
  where a.id = v_appointment;

  if v_row.room_unit_id is distinct from v_room_unit then
    raise exception
      '122q regression changed existing room unit: expected %, got %',
      v_room_unit, v_row.room_unit_id;
  end if;
  if v_row.end_at <= v_row.start_at then
    raise exception
      '122q regression produced non-positive operational window: % to %',
      v_row.start_at, v_row.end_at;
  end if;
  if v_row.start_at is distinct from v_actual_start then
    raise exception
      '122q regression did not project actual start: expected %, got %',
      v_actual_start, v_row.start_at;
  end if;
  if v_row.end_at - v_row.start_at <> interval '1 hour' then
    raise exception
      '122q regression changed operational duration: expected 1 hour, got %',
      v_row.end_at - v_row.start_at;
  end if;
end
$early_specific_room$;

rollback;
