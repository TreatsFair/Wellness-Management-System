-- Phase 6B.1 TRANSACTIONAL smoke test.
--
-- Every write is rolled back. The script ends with ROLLBACK and, on any failed
-- assertion, aborts the transaction via RAISE EXCEPTION, so a failure also
-- leaves nothing behind.
--
-- Scenario construction rules (Step 2F):
--   * the room is chosen to match the selected service's room_type;
--   * the therapist is chosen to be active, allowed to perform the service
--     (service_commissions = '{}' means "all services"), and working for the
--     FULL requested window including the after-service buffer;
--   * the four scenarios are placed at four non-overlapping start times so they
--     never compete with each other for capacity;
--   * each scenario asserts BOTH dimensions explicitly, not just the one it is
--     about.

begin;

do $test$
declare
  v_outlet uuid;
  v_service uuid;
  v_service_name text;
  v_room_type text;
  v_buffer integer;
  v_duration integer;
  v_therapist uuid;
  v_room uuid;
  v_date date;
  v_slot0 time; v_slot0_end time;
  v_slot1 time; v_slot1_end time;
  v_slot2 time; v_slot2_end time;
  v_slot3 time; v_slot3_end time;
  v_group uuid;
  v_appt uuid;
  v_appt_scr uuid;
  v_appt_mo uuid;
  v_allocations jsonb;
  v_result record;
  v_single record;
  v_audit_before bigint;
  v_audit_after bigint;
  v_candidate record;
  v_flag_before boolean;
  v_appt_count_before bigint;
  v_txn_count_before bigint;
  v_row public.appointments%rowtype;
  v_stride integer;
begin
  select count(*) into v_appt_count_before from public.appointments;
  select count(*) into v_txn_count_before from public.transactions;

  -- ------------------------------------------------------------------
  -- Fixture selection: one outlet / service / therapist / room / date
  -- with four consecutive non-overlapping windows inside working hours.
  -- ------------------------------------------------------------------
  for v_candidate in
    select
      s.outlet_id,
      s.id                                            as service_id,
      s.name                                          as service_name,
      lower(trim(s.room_type::text))                  as room_type,
      coalesce(s.buffer_after_minutes, 0)             as buffer_minutes,
      greatest(s.duration, 30)                        as duration_minutes,
      t.id                                            as therapist_id,
      d::date                                         as test_date,
      wh.start_time                                   as window_start,
      wh.end_time                                     as window_end,
      (wh.end_time <= wh.start_time)                  as overnight
    from public.services s
    join public.therapists t
      on t.outlet_id = s.outlet_id
     and coalesce(t.availability_status, true)
     and lower(coalesce(t.role, 'therapist')) = 'therapist'
     and (t.service_commissions = '{}'::jsonb
          or t.service_commissions ? s.id::text)
    join public.therapist_working_hours wh
      on wh.therapist_id = t.id
    cross join lateral generate_series(
      current_date + 1, current_date + 14, interval '1 day'
    ) d
    where s.is_active
      and wh.day_of_week = extract(dow from d)::integer
      -- The therapist must be free of unavailability for the whole day.
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = t.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur')::date <= d::date
          and (u.ends_at   at time zone 'Asia/Kuala_Lumpur')::date >= d::date
      )
      -- Four back-to-back windows (service + buffer) must fit inside the shift.
      and (
        d::date + wh.start_time
        + make_interval(mins => 4 * (greatest(s.duration, 30)
                                     + greatest(coalesce(s.buffer_after_minutes, 0), 0)))
      ) <= (
        d::date + wh.end_time
        + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
      )
      -- A room of the service's own room_type must exist in the outlet.
      and exists (
        select 1 from public.rooms r
        where r.outlet_id = s.outlet_id
          and coalesce(r.is_active, true)
          and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, '')))
              = lower(trim(s.room_type::text))
      )
    order by d, s.outlet_id, s.id, t.id
    limit 1
  loop
    v_outlet       := v_candidate.outlet_id;
    v_service      := v_candidate.service_id;
    v_service_name := v_candidate.service_name;
    v_room_type    := v_candidate.room_type;
    v_buffer       := v_candidate.buffer_minutes;
    v_duration     := v_candidate.duration_minutes;
    v_therapist    := v_candidate.therapist_id;
    v_date         := v_candidate.test_date;
    v_slot0        := v_candidate.window_start;
  end loop;

  if v_outlet is null then
    raise exception
      'Smoke test fixture failed: no outlet/service/therapist/room/date combination satisfies the constraints';
  end if;

  select r.id into v_room
  from public.rooms r
  where r.outlet_id = v_outlet
    and coalesce(r.is_active, true)
    and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type
  order by r.total_slots desc, r.id
  limit 1;

  if v_room is null then
    raise exception 'Smoke test fixture failed: no room matches room_type %', v_room_type;
  end if;

  -- Non-overlapping windows: each stride is service duration + buffer.
  v_stride := v_duration + greatest(v_buffer, 0);
  v_slot0_end := (v_slot0 + make_interval(mins => v_duration))::time;
  v_slot1     := (v_slot0 + make_interval(mins => 1 * v_stride))::time;
  v_slot1_end := (v_slot1 + make_interval(mins => v_duration))::time;
  v_slot2     := (v_slot0 + make_interval(mins => 2 * v_stride))::time;
  v_slot2_end := (v_slot2 + make_interval(mins => v_duration))::time;
  v_slot3     := (v_slot0 + make_interval(mins => 3 * v_stride))::time;
  v_slot3_end := (v_slot3 + make_interval(mins => v_duration))::time;

  -- ------------------------------------------------------------------
  -- Turn the flag ON for this outlet only, inside the transaction.
  -- ------------------------------------------------------------------
  select bs.capacity_first_enabled into v_flag_before
  from public.business_settings bs where bs.outlet_id = v_outlet;

  if coalesce(v_flag_before, false) then
    raise exception
      'Smoke test refuses to run: capacity_first_enabled is already ON for outlet %', v_outlet;
  end if;

  update public.business_settings
  set capacity_first_enabled = true
  where outlet_id = v_outlet;

  if not public.capacity_first_enabled(v_outlet) then
    raise exception 'Smoke test setup failed: flag did not turn ON';
  end if;

  -- ==================================================================
  -- Scenario A (slot 0) — 122d: an ordinary queue group pax stays
  -- anonymous on BOTH dimensions after a group update.
  -- ==================================================================
  insert into public.appointment_groups (
    customer_id, group_name, pax_count, appointment_date, status, notes, outlet_id
  ) values (
    null, 'PHASE6B1_ROLLBACK_TEST', 1, v_date, 'confirmed',
    'transactional smoke test', v_outlet
  ) returning id into v_group;

  insert into public.appointments (
    appointment_group_id, customer_id, therapist_id, room_id, room_unit_id,
    service_id, appointment_date, start_time, end_time, start_at, end_at,
    buffer_after_minutes, status, total_price, type, service_name,
    service_items, item_count, notes, assignment_source,
    therapist_assignment_state, room_assignment_state, outlet_id
  ) values (
    v_group, null, null, null, null,
    v_service, v_date, v_slot0, v_slot0_end,
    public.csp_start_at(v_date, v_slot0),
    public.csp_end_at(v_date, v_slot0, v_slot0_end),
    v_buffer, 'confirmed', 0, 'appointment', v_service_name,
    '[]'::jsonb, 1, 'transactional smoke test', 'queue',
    'pending', 'pending', v_outlet
  ) returning id into v_appt;

  v_allocations := jsonb_build_array(jsonb_build_object(
    'appointment_id', v_appt,
    'service_id', v_service,
    'start_time', v_slot0::text,
    'end_time', v_slot0_end::text,
    'total_price', 0,
    'service_name', v_service_name,
    'service_items', '[]'::jsonb,
    'item_count', 1,
    'notes', 'transactional smoke test',
    'assignment_source', 'queue',
    'requested_gender', null
  ));

  select * into v_result
  from public.update_appointment_group_with_csp(
    v_group, null, 'PHASE6B1_ROLLBACK_TEST', 1, v_date, v_allocations,
    'appointment', 'confirmed', 'transactional smoke test', auth.uid()
  );

  if not coalesce(v_result.success, false) then
    raise exception 'A/122d group update failed: % %',
      v_result.error_code, v_result.error_message;
  end if;

  select * into v_row from public.appointments where id = v_appt;
  if v_row.therapist_id is not null
     or v_row.room_id is not null
     or v_row.room_unit_id is not null
     or coalesce(v_row.room_unit_name, '') <> ''
     or v_row.therapist_assignment_state <> 'pending'
     or v_row.room_assignment_state <> 'pending'
     or v_row.resources_confirmed_at is not null then
    raise exception 'A/122d failed: queue group pax did not stay fully anonymous';
  end if;

  -- ==================================================================
  -- Scenario B (slot 1) — create validation must reject bad input.
  -- ==================================================================
  select * into v_single from public.create_appointment_with_csp(
    null, null, null, v_service, v_date, v_slot1, v_slot1_end, 0, 'appointment',
    auth.uid(), v_service_name, '[]'::jsonb, 1, 'B1', null,
    'specific_customer_request', null, null, false
  );
  if coalesce(v_single.success, false)
     or v_single.error_code <> 'REQUESTED_THERAPIST_REQUIRED' then
    raise exception 'B/122e failed: specific_customer_request without a therapist was accepted (%)',
      v_single.error_code;
  end if;

  select * into v_single from public.create_appointment_with_csp(
    null, null, null, v_service, v_date, v_slot1, v_slot1_end, 0, 'appointment',
    auth.uid(), v_service_name, '[]'::jsonb, 1, 'B2', null,
    'manual_override', null, null, false
  );
  if coalesce(v_single.success, false)
     or v_single.error_code <> 'MANUAL_RESOURCE_REQUIRED' then
    raise exception 'B/122e failed: manual_override with both resources NULL was accepted (%)',
      v_single.error_code;
  end if;

  -- ==================================================================
  -- Scenario C (slot 1) — exact therapist + ANONYMOUS room.
  -- ==================================================================
  select * into v_single from public.create_appointment_with_csp(
    null, v_therapist, v_room, v_service, v_date, v_slot1, v_slot1_end, 0, 'appointment',
    auth.uid(), v_service_name, '[]'::jsonb, 1, 'C', null,
    'specific_customer_request', v_therapist, null, false
  );
  if not coalesce(v_single.success, false) then
    raise exception 'C/122e specific_customer_request create failed: % %',
      v_single.error_code, v_single.error_message;
  end if;
  v_appt_scr := v_single.appointment_id;

  select * into v_row from public.appointments where id = v_appt_scr;
  if v_row.therapist_id is distinct from v_therapist then
    raise exception 'C failed: exact therapist was not persisted';
  end if;
  if v_row.room_id is not null then
    raise exception 'C failed: room_id is NOT NULL (%) — the room must stay anonymous',
      v_row.room_id;
  end if;
  if v_row.room_unit_id is not null or coalesce(v_row.room_unit_name, '') <> '' then
    raise exception 'C failed: room unit was not cleared for an anonymous room';
  end if;
  if v_row.therapist_assignment_state <> 'confirmed' then
    raise exception 'C failed: therapist_assignment_state is % (expected confirmed)',
      v_row.therapist_assignment_state;
  end if;
  if v_row.room_assignment_state <> 'pending' then
    raise exception 'C failed: room_assignment_state is % (expected pending)',
      v_row.room_assignment_state;
  end if;
  if v_row.resources_confirmed_at is not null then
    raise exception 'C failed: resources_confirmed_at set while the room is still anonymous';
  end if;

  -- ------------------------------------------------------------------
  -- C2 — a genuinely identical update must be a no-op and write no audit row.
  -- ------------------------------------------------------------------
  select count(*) into v_audit_before from public.audit_log;

  select * into v_single from public.update_appointment_with_csp(
    v_appt_scr, v_therapist, null, v_date, v_slot1, v_slot1_end,
    'specific_customer_request', v_therapist, null, false
  );
  if not coalesce(v_single.success, false) then
    raise exception 'C2/122e no-op update failed: % %',
      v_single.error_code, v_single.error_message;
  end if;

  select count(*) into v_audit_after from public.audit_log;
  if v_audit_after <> v_audit_before then
    raise exception 'C2 failed: no-op update wrote % audit row(s)',
      v_audit_after - v_audit_before;
  end if;

  -- ==================================================================
  -- Scenario D (slot 2) — manual ROOM lock + ANONYMOUS therapist.
  -- Created directly as room-only; the RPC signature cannot express
  -- "release the therapist" on an existing manual_override row (see the
  -- limitation documented in migration 122e), so this is created fresh
  -- rather than converted from scenario C.
  -- ==================================================================
  select * into v_single from public.create_appointment_with_csp(
    null, null, v_room, v_service, v_date, v_slot2, v_slot2_end, 0, 'appointment',
    auth.uid(), v_service_name, '[]'::jsonb, 1, 'D', null,
    'manual_override', null, null, false
  );
  if not coalesce(v_single.success, false) then
    raise exception 'D/122e room-only manual_override create failed: % %',
      v_single.error_code, v_single.error_message;
  end if;
  v_appt_mo := v_single.appointment_id;

  select * into v_row from public.appointments where id = v_appt_mo;
  if v_row.therapist_id is not null then
    raise exception 'D failed: therapist_id is NOT NULL (%) — it must stay anonymous',
      v_row.therapist_id;
  end if;
  if v_row.room_id is distinct from v_room then
    raise exception 'D failed: the manually locked room was not persisted';
  end if;
  if v_row.therapist_assignment_state <> 'pending' then
    raise exception 'D failed: therapist_assignment_state is % (expected pending)',
      v_row.therapist_assignment_state;
  end if;
  if v_row.room_assignment_state <> 'confirmed' then
    raise exception 'D failed: room_assignment_state is % (expected confirmed)',
      v_row.room_assignment_state;
  end if;
  if v_row.therapist_auto_assigned_at is not null then
    raise exception 'D failed: therapist_auto_assigned_at set for an anonymous therapist';
  end if;
  if v_row.resources_confirmed_at is not null then
    raise exception 'D failed: resources_confirmed_at set while the therapist is anonymous';
  end if;

  -- ------------------------------------------------------------------
  -- D2 — releasing BOTH dimensions via queue must clear room + room unit.
  -- ------------------------------------------------------------------
  select * into v_single from public.update_appointment_with_csp(
    v_appt_mo, null, null, v_date, v_slot3, v_slot3_end,
    'queue', null, null, false
  );
  if not coalesce(v_single.success, false) then
    raise exception 'D2/122e release-to-queue failed: % %',
      v_single.error_code, v_single.error_message;
  end if;

  select * into v_row from public.appointments where id = v_appt_mo;
  if v_row.therapist_id is not null or v_row.room_id is not null then
    raise exception 'D2 failed: resources were not released to anonymous capacity';
  end if;
  if v_row.room_unit_id is not null or coalesce(v_row.room_unit_name, '') <> '' then
    raise exception 'D2 failed: room unit was not cleared when the room became anonymous';
  end if;
  if v_row.therapist_assignment_state <> 'pending'
     or v_row.room_assignment_state <> 'pending' then
    raise exception 'D2 failed: assignment states were not reset to pending';
  end if;
  if v_row.start_time is distinct from v_slot3 then
    raise exception 'D2 failed: the reschedule did not take effect';
  end if;
  if v_row.booked_start_time is distinct from v_slot3 then
    raise exception 'D2 failed: booked_start_time went stale after the reschedule';
  end if;

  -- ==================================================================
  -- Scenario E — a protected therapist cannot be silently swapped.
  -- ==================================================================
  select * into v_single from public.update_appointment_with_csp(
    v_appt_scr, v_therapist, v_room, v_date, v_slot1, v_slot1_end,
    'manual_override', null, null, false
  );
  if not coalesce(v_single.success, false) then
    raise exception 'E/122e manual_override on a protected therapist failed: % %',
      v_single.error_code, v_single.error_message;
  end if;

  select * into v_row from public.appointments where id = v_appt_scr;
  if v_row.therapist_id is distinct from v_therapist then
    raise exception 'E failed: the protected therapist was not preserved';
  end if;
  if v_row.room_id is distinct from v_room then
    raise exception 'E failed: the newly locked room was not applied to the unprotected dimension';
  end if;
  if v_row.therapist_assignment_state <> 'confirmed'
     or v_row.room_assignment_state <> 'confirmed' then
    raise exception 'E failed: both dimensions should now be confirmed';
  end if;
  if v_row.resources_confirmed_at is null then
    raise exception 'E failed: resources_confirmed_at not stamped once both dimensions are confirmed';
  end if;

  -- E2 — the now fully-confirmed row must be rejected by the edit RPC.
  select * into v_single from public.update_appointment_with_csp(
    v_appt_scr, v_therapist, v_room, v_date, v_slot2, v_slot2_end,
    'manual_override', null, null, false
  );
  if coalesce(v_single.success, false)
     or v_single.error_code <> 'APPOINTMENT_NOT_EDITABLE' then
    raise exception 'E2 failed: a fully resource-confirmed appointment was editable (%)',
      v_single.error_code;
  end if;

  raise notice 'Phase 6B.1 smoke test: all scenarios passed (appointments before=%, transactions before=%)',
    v_appt_count_before, v_txn_count_before;
end;
$test$;

-- Read-back inside the same (about to be rolled back) transaction.
select
  (select count(*) from public.appointments)                                   as appointments_in_tx,
  (select count(*) from public.transactions)                                   as transactions_in_tx,
  (select count(*) from public.business_settings where capacity_first_enabled) as flags_on_in_tx,
  (select count(*) from public.appointment_groups
    where group_name = 'PHASE6B1_ROLLBACK_TEST')                               as test_groups_in_tx;

rollback;

-- Post-rollback verification: nothing above may have survived.
do $verify$
declare
  v_flags integer;
  v_groups integer;
  v_appts integer;
begin
  select count(*) into v_flags from public.business_settings where capacity_first_enabled;
  if v_flags <> 0 then
    raise exception 'ROLLBACK VERIFICATION FAILED: capacity_first_enabled is ON for % outlet(s)', v_flags;
  end if;

  select count(*) into v_groups from public.appointment_groups
  where group_name = 'PHASE6B1_ROLLBACK_TEST';
  if v_groups <> 0 then
    raise exception 'ROLLBACK VERIFICATION FAILED: % test group(s) survived', v_groups;
  end if;

  select count(*) into v_appts from public.appointments
  where notes in ('transactional smoke test', 'B1', 'B2', 'C', 'D');
  if v_appts <> 0 then
    raise exception 'ROLLBACK VERIFICATION FAILED: % test appointment(s) survived', v_appts;
  end if;

  raise notice 'Rollback verified: no flag change, no test group, no test appointment survived.';
end;
$verify$;
