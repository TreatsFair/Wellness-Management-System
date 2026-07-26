-- phase6a_tests.sql
-- Forward + rollback + correctness tests for Migrations 118, 119, 120.
-- RUN IN A SCRATCH / LOCAL DATABASE ONLY (never production). Assumes the baseline
-- schema (through 116) is present. Each block raises an exception on failure and
-- is otherwise silent. Wrap the data-mutating blocks in a transaction you roll
-- back if you want to leave the scratch DB pristine.

-- =====================================================================
-- 119 — Kuhn matcher correctness (data-free; the false-feasible trap)
-- =====================================================================
do $$
begin
  -- Saturable: two demands, disjoint single eligible therapists.
  if not public.capacity_bipartite_saturates(
       '{"d0":["T1"],"d1":["T2"]}'::jsonb) then
    raise exception 'FAIL: disjoint 1-1 adjacency should saturate';
  end if;

  -- Saturable: cross eligibility.
  if not public.capacity_bipartite_saturates(
       '{"d0":["T1","T2"],"d1":["T1","T2"]}'::jsonb) then
    raise exception 'FAIL: 2x2 complete adjacency should saturate';
  end if;

  -- FALSE-FEASIBLE TRAP: two demands, both only eligible for the SAME single
  -- therapist. A greedy per-bucket count ("2 therapists present") would wrongly
  -- pass; exact matching must report NOT saturable.
  if public.capacity_bipartite_saturates(
       '{"d0":["T1"],"d1":["T1"]}'::jsonb) then
    raise exception 'FAIL: two demands needing the same sole therapist must NOT saturate';
  end if;

  -- Three demands, three therapists, one shared bottleneck -> not saturable.
  if public.capacity_bipartite_saturates(
       '{"d0":["T1"],"d1":["T1"],"d2":["T2","T3"]}'::jsonb) then
    raise exception 'FAIL: bottleneck on T1 must NOT saturate';
  end if;

  -- Empty demand set is trivially feasible.
  if not public.capacity_bipartite_saturates('{}'::jsonb) then
    raise exception 'FAIL: empty adjacency should saturate';
  end if;

  raise notice 'PASS: Kuhn matcher (incl. false-feasible trap)';
end;
$$;

-- =====================================================================
-- 118 — nullability + started/confirmed CHECK + no anonymous rows
-- =====================================================================
do $$
declare
  v_notnull_therapist boolean;
  v_notnull_room boolean;
  v_anon integer;
begin
  select attnotnull into v_notnull_therapist
  from pg_attribute where attrelid='public.appointments'::regclass and attname='therapist_id';
  select attnotnull into v_notnull_room
  from pg_attribute where attrelid='public.appointments'::regclass and attname='room_id';

  if v_notnull_therapist or v_notnull_room then
    raise exception 'FAIL: therapist_id/room_id should be nullable after 118';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='appointments_started_requires_concrete'
      and conrelid='public.appointments'::regclass
      and convalidated
  ) then
    raise exception 'FAIL: started/confirmed CHECK missing or not validated';
  end if;

  -- 118 must not have created any anonymous rows.
  select count(*) into v_anon
  from public.appointments where therapist_id is null or room_id is null;
  if v_anon <> 0 then
    raise exception 'FAIL: 118 must create no anonymous rows, found %', v_anon;
  end if;

  raise notice 'PASS: 118 nullability + validated CHECK + zero anonymous rows';
end;
$$;

-- 118 precise-constraint behaviour (all six rules). REQUIRES 118 + 120 applied
-- (inserting anonymous rows exercises the 120-guarded assign_appointment_room_unit
-- trigger). WHEN RUN AGAINST A NON-SCRATCH DB, WRAP THE WHOLE BLOCK IN
-- `begin; ... rollback;` so no test rows or audit entries persist.
-- Helper: assert a statement is rejected by a specific constraint.
do $$
declare
  v_outlet uuid;
  v_service uuid;
  v_therapist uuid;
  v_room uuid;
  v_id uuid;
  v_c text;
  v_ok boolean;
begin
  select id into v_outlet from public.outlets limit 1;
  select id into v_service from public.services where outlet_id = v_outlet limit 1;
  select id into v_therapist from public.therapists where outlet_id = v_outlet limit 1;
  select id into v_room from public.rooms where outlet_id = v_outlet limit 1;
  if v_outlet is null or v_service is null or v_therapist is null or v_room is null then
    raise notice 'SKIP: need outlet/service/therapist/room for 118 precise tests';
    return;
  end if;

  ------------------------------------------------------------------
  -- RULE-target A (ALLOWED): FUTURE status='confirmed', fully anonymous.
  -- Proves appointment-confirmed != resources-confirmed.
  ------------------------------------------------------------------
  insert into public.appointments (
    id, therapist_id, room_id, service_id, appointment_date, start_time, end_time,
    status, total_price, type, outlet_id, service_name, service_items,
    therapist_assignment_state, room_assignment_state
  ) values (
    gen_random_uuid(), null, null, v_service,
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1, '10:00', '11:00',
    'confirmed', 0, 'appointment', v_outlet, 'test', '[]'::jsonb,
    'pending', 'pending'
  ) returning id into v_id;
  delete from public.appointments where id = v_id;
  raise notice 'PASS: future status=confirmed can be fully anonymous';

  ------------------------------------------------------------------
  -- RULE 1 (REJECTED): therapist_assignment_state='confirmed' + NULL therapist.
  ------------------------------------------------------------------
  v_c := null;
  begin
    insert into public.appointments (
      id, therapist_id, room_id, service_id, appointment_date, start_time, end_time,
      status, total_price, type, outlet_id, service_name, service_items,
      therapist_assignment_state, room_assignment_state, assignment_source
    ) values (
      gen_random_uuid(), null, null, v_service,
      (now() at time zone 'Asia/Kuala_Lumpur')::date + 1, '10:00', '11:00',
      'confirmed', 0, 'appointment', v_outlet, 'test', '[]'::jsonb,
      'confirmed', 'pending', 'queue'
    ) returning id into v_id;
    delete from public.appointments where id = v_id;
  exception when others then
    get stacked diagnostics v_c = constraint_name;
  end;
  if v_c is distinct from 'appointments_confirmed_therapist_concrete' then
    raise exception 'FAIL rule1: expected confirmed-therapist constraint, got %', coalesce(v_c,'<none/allowed>');
  end if;
  raise notice 'PASS: confirmed therapist state requires therapist_id';

  ------------------------------------------------------------------
  -- RULE 2 (REJECTED): room_assignment_state='confirmed' + NULL room.
  ------------------------------------------------------------------
  v_c := null;
  begin
    insert into public.appointments (
      id, therapist_id, room_id, service_id, appointment_date, start_time, end_time,
      status, total_price, type, outlet_id, service_name, service_items,
      therapist_assignment_state, room_assignment_state, assignment_source
    ) values (
      gen_random_uuid(), null, null, v_service,
      (now() at time zone 'Asia/Kuala_Lumpur')::date + 1, '10:00', '11:00',
      'confirmed', 0, 'appointment', v_outlet, 'test', '[]'::jsonb,
      'pending', 'confirmed', 'queue'
    ) returning id into v_id;
    delete from public.appointments where id = v_id;
  exception when others then
    get stacked diagnostics v_c = constraint_name;
  end;
  if v_c is distinct from 'appointments_confirmed_room_concrete' then
    raise exception 'FAIL rule2: expected confirmed-room constraint, got %', coalesce(v_c,'<none/allowed>');
  end if;
  raise notice 'PASS: confirmed room state requires room_id';

  ------------------------------------------------------------------
  -- RULE 3 (REJECTED): started/in_progress with NULL resources.
  -- TODAY's date so enforce_no_future_service_progress does not pre-empt.
  ------------------------------------------------------------------
  v_c := null; v_ok := false;
  begin
    insert into public.appointments (
      id, therapist_id, room_id, service_id, appointment_date, start_time, end_time,
      status, total_price, type, outlet_id, service_name, service_items,
      therapist_assignment_state, room_assignment_state
    ) values (
      gen_random_uuid(), null, null, v_service,
      (now() at time zone 'Asia/Kuala_Lumpur')::date, '10:00', '11:00',
      'in_progress', 0, 'appointment', v_outlet, 'test', '[]'::jsonb,
      'pending', 'pending'
    ) returning id into v_id;
    delete from public.appointments where id = v_id;
  exception when others then
    v_ok := true;  -- rejected (by started_requires_concrete or a normalized state constraint)
    get stacked diagnostics v_c = constraint_name;
  end;
  if not v_ok then
    raise exception 'FAIL rule3: in_progress with NULL resources was allowed';
  end if;
  raise notice 'PASS: in_progress/started with NULL resources rejected (%).', coalesce(v_c,'constraint');

  ------------------------------------------------------------------
  -- RULE 5 (ALLOWED): exact requested therapist concrete, room anonymous.
  ------------------------------------------------------------------
  insert into public.appointments (
    id, therapist_id, room_id, service_id, appointment_date, start_time, end_time,
    status, total_price, type, outlet_id, service_name, service_items,
    therapist_assignment_state, room_assignment_state,
    assignment_source, requested_therapist_id
  ) values (
    gen_random_uuid(), v_therapist, null, v_service,
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1, '10:00', '11:00',
    'confirmed', 0, 'appointment', v_outlet, 'test', '[]'::jsonb,
    'confirmed', 'pending', 'specific_customer_request', v_therapist
  ) returning id into v_id;
  delete from public.appointments where id = v_id;
  raise notice 'PASS: requested therapist concrete + anonymous room allowed';

  ------------------------------------------------------------------
  -- RULE 6 (ALLOWED): manual room concrete, therapist anonymous.
  ------------------------------------------------------------------
  insert into public.appointments (
    id, therapist_id, room_id, service_id, appointment_date, start_time, end_time,
    status, total_price, type, outlet_id, service_name, service_items,
    therapist_assignment_state, room_assignment_state, assignment_source
  ) values (
    gen_random_uuid(), null, v_room, v_service,
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1, '10:00', '11:00',
    'confirmed', 0, 'appointment', v_outlet, 'test', '[]'::jsonb,
    'pending', 'confirmed', 'queue'
  ) returning id into v_id;
  delete from public.appointments where id = v_id;
  raise notice 'PASS: manual room concrete + anonymous therapist allowed';
end;
$$;

-- =====================================================================
-- 120 — NULL-resource tolerant paths (no trigger errors on anonymous rows)
-- =====================================================================
do $$
declare
  v_id uuid;
  v_outlet uuid;
  v_service uuid;
begin
  select id into v_outlet from public.outlets limit 1;
  select id into v_service from public.services where outlet_id = v_outlet limit 1;
  if v_outlet is null or v_service is null then
    raise notice 'SKIP: no outlet/service for 120 tolerance test';
    return;
  end if;

  -- Inserting + updating an anonymous future row must not error in any BEFORE/
  -- AFTER trigger (assign_appointment_room_unit / consume_queue / etc.).
  insert into public.appointments (
    id, therapist_id, room_id, room_unit_id, service_id,
    appointment_date, start_time, end_time, status, total_price, type,
    outlet_id, service_name, service_items,
    therapist_assignment_state, room_assignment_state
  ) values (
    gen_random_uuid(), null, null, null, v_service,
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1, '12:00', '13:00',
    'pending', 0, 'appointment', v_outlet, 'test', '[]'::jsonb,
    'pending', 'pending'
  ) returning id into v_id;

  update public.appointments
  set start_time = '12:30', end_time = '13:30'
  where id = v_id;   -- exercises BEFORE triggers again with NULL room_id

  delete from public.appointments where id = v_id;  -- cleanup
  raise notice 'PASS: 120 anonymous row insert/update triggers no errors';
end;
$$;

-- =====================================================================
-- 119 — shadow parity vs check_walkin_protects_future  (MANUAL / DATA-DEPENDENT)
-- =====================================================================
-- For a single proposed walk-in pinned to a specific therapist, capacity_feasible
-- in "hard" mode with one demand whose requested_therapist_id = that therapist
-- should agree with check_walkin_protects_future for the same window. Because
-- production/scratch has NO anonymous rows, existing appts reduce supply and the
-- only demand to match is the proposed one — the two must agree.
--
-- Fill in real scratch ids and compare, e.g.:
--   select public.check_walkin_protects_future(:outlet, :start_ts, 60, :therapist) as legacy,
--          (public.capacity_feasible(
--             :outlet,
--             jsonb_build_array(jsonb_build_object(
--               'start', to_char(:start_ts,'YYYY-MM-DD HH24:MI:SS'),
--               'duration_minutes', 60, 'buffer_after_minutes', 5,
--               'service_id', :service, 'room_type', :room_type,
--               'requested_therapist_id', :therapist, 'pax_index', 0)),
--             'hard') ->> 'feasible')::boolean as shadow;
--   -- assert legacy = shadow across several windows (free, exactly-full, over-by-one).
--
-- Also inspect the plan/time:
--   explain analyze select public.capacity_feasible(:outlet, :demands, 'hard');

-- =====================================================================
-- 116 preserved — Cron + key functions unchanged
-- =====================================================================
do $$
begin
  if not exists (
    select 1 from cron.job
    where jobname='reconcile-upcoming-appointment-assignments'
      and schedule='*/5 * * * *'
  ) then
    raise exception 'FAIL: Migration 116 cron job changed/removed';
  end if;
  raise notice 'PASS: 116 cron intact';
end;
$$;

-- ROLLBACK TESTS: after running 118/119/120 rollback scripts, re-run the
-- respective blocks above; expect 118 columns NOT NULL again (only when zero
-- anonymous rows exist), capacity_feasible absent, and the two trigger functions
-- back to their pre-120 bodies.
