-- Phase 6B.1 Priority 3 regression tests — check-in / start separation and
-- timestamp handling. Fully transactional: ends by raising, so nothing commits.
--
-- Run with:  (paste into the SQL editor, or execute as one statement)
-- A pass raises  'P3_REGRESSION_PASS >>> ...'
-- A failure raises the specific assertion that failed.
--
-- Covers, per the Priority 3 brief:
--   1. 3-minute service started early           (short-service inversion)
--   2. 50-minute service started early          (early-start gap)
--   3. start_at / end_at are timestamp WITHOUT time zone -- no 8h shift
--   4. booked_* and actual_started_at are timestamptz -- correct conversion
--   5. check-in does not start, does not move the window, does not re-charge
--   6. start after check-in preserves checked_in_at and booked_*

do $regression$
declare
  v_outlet uuid := '00000000-0000-0000-0000-000000000002';
  v_staff uuid;
  v_service uuid; v_sname text; v_ther uuid; v_room uuid;
  v_appt uuid; v_row public.appointments%rowtype; v_now timestamp;
  v_ci record; v_t0 bigint; v_t1 bigint; v_block numeric;
  v_addons jsonb; v_sched_start time; v_sched_end time;

  procedure_note text := '';
begin
  select id into v_staff from public.profiles
  order by case when role::text = 'admin' then 0 else 1 end, id limit 1;
  if v_staff is null then raise exception 'REGRESSION SETUP: no profiles row'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);

  select s.id, s.name into v_service, v_sname from public.services s
  where s.outlet_id = v_outlet and s.is_active
    and lower(trim(s.room_type::text)) = 'body_room'
  order by s.display_order limit 1;
  select t.id into v_ther from public.therapists t
  where t.outlet_id = v_outlet and coalesce(t.availability_status, true)
    and lower(coalesce(t.role, 'therapist')) = 'therapist' order by t.id limit 1;
  select r.id into v_room from public.rooms r
  where r.outlet_id = v_outlet and r.is_active
    and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = 'body_room'
  limit 1;
  if v_service is null or v_ther is null or v_room is null then
    raise exception 'REGRESSION SETUP: missing service/therapist/room fixture';
  end if;

  v_now := now() at time zone 'Asia/Kuala_Lumpur';
  v_addons := jsonb_build_array(
    jsonb_build_object('id', v_service::text, 'name', 'Addon', 'price', 50));

  -- ================================================================
  -- CASE 1 — 3-minute service, checked in and started 2 hours EARLY.
  -- Historically produced a ~22h phantom block via the overnight
  -- reinterpretation of end_time < start_time.
  -- ================================================================
  v_sched_start := (v_now + interval '2 hours')::time;
  v_sched_end   := (v_now + interval '2 hours 3 minutes')::time;

  insert into public.appointments (
    customer_id, therapist_id, room_id, service_id, appointment_date,
    start_time, end_time, status, total_price, type, service_name,
    service_items, item_count, notes, assignment_source, payment_status,
    outlet_id, created_by)
  values (null, v_ther, v_room, v_service, v_now::date,
    v_sched_start, v_sched_end, 'confirmed', 100, 'appointment', v_sname,
    '[]'::jsonb, 1, 'REG_C1', 'manual_override', 'paid', v_outlet, v_staff)
  returning id into v_appt;

  perform public.start_appointment_service(v_appt, now(), null, false);
  select * into v_row from public.appointments where id = v_appt;

  v_block := extract(epoch from (public.csp_appointment_block_end_at(v_row)
             - public.csp_appointment_start_at(v_row))) / 3600.0;

  if v_block <= 0 then
    raise exception 'CASE1 FAIL: non-positive block % h (inverted window)', v_block;
  end if;
  if v_block > 1 then
    raise exception 'CASE1 FAIL: phantom block % h for a 3-minute service', v_block;
  end if;
  if v_row.booked_start_time <> v_sched_start then
    raise exception 'CASE1 FAIL: booked_start_time drifted to %', v_row.booked_start_time;
  end if;
  procedure_note := procedure_note || format('C1 ok block=%sh sched=%s oper=%s | ',
    round(v_block, 3), v_row.booked_start_time, v_row.start_time);

  -- ================================================================
  -- CASE 2 — 50-minute service started 2 hours EARLY. Historically left
  -- a gap [actual_started_at, start_at) where the therapist read FREE.
  -- ================================================================
  v_sched_start := (v_now + interval '2 hours')::time;
  v_sched_end   := (v_now + interval '2 hours 50 minutes')::time;

  insert into public.appointments (
    customer_id, therapist_id, room_id, service_id, appointment_date,
    start_time, end_time, status, total_price, type, service_name,
    service_items, item_count, notes, assignment_source, payment_status,
    outlet_id, created_by)
  values (null, v_ther, v_room, v_service, v_now::date,
    v_sched_start, v_sched_end, 'confirmed', 100, 'appointment', v_sname,
    '[]'::jsonb, 1, 'REG_C2', 'manual_override', 'paid', v_outlet, v_staff)
  returning id into v_appt;

  perform public.start_appointment_service(v_appt, now(), null, false);
  select * into v_row from public.appointments where id = v_appt;

  v_block := extract(epoch from (public.csp_appointment_block_end_at(v_row)
             - public.csp_appointment_start_at(v_row))) / 3600.0;

  if v_block < 0.8 or v_block > 1.2 then
    raise exception 'CASE2 FAIL: 50-minute service produced a % h block', v_block;
  end if;

  -- CASE 3 — the operational window must start AT the actual start, so the
  -- working period is covered with no free gap.
  if public.csp_appointment_start_at(v_row)
     <> (v_row.actual_started_at at time zone 'Asia/Kuala_Lumpur') then
    raise exception 'CASE3 FAIL: start_at % <> actual start %',
      public.csp_appointment_start_at(v_row),
      (v_row.actual_started_at at time zone 'Asia/Kuala_Lumpur');
  end if;

  -- CASE 3b — no 8-hour timezone shift. start_at/end_at are
  -- `timestamp WITHOUT time zone` holding LOCAL values; if either had been
  -- round-tripped through timestamptz the delta below would be ~8h off.
  if abs(extract(epoch from (v_row.start_at
         - (v_row.actual_started_at at time zone 'Asia/Kuala_Lumpur')))) > 1 then
    raise exception 'CASE3b FAIL: start_at is shifted from the actual start by % s',
      extract(epoch from (v_row.start_at
        - (v_row.actual_started_at at time zone 'Asia/Kuala_Lumpur')));
  end if;
  if v_row.end_at <= v_row.start_at then
    raise exception 'CASE3b FAIL: end_at % is not after start_at %',
      v_row.end_at, v_row.start_at;
  end if;

  -- CASE 4 — booked_* are timestamptz and must still describe the SCHEDULE.
  if (v_row.booked_start_at at time zone 'Asia/Kuala_Lumpur')::time <> v_sched_start then
    raise exception 'CASE4 FAIL: booked_start_at reads % but was scheduled %',
      (v_row.booked_start_at at time zone 'Asia/Kuala_Lumpur')::time, v_sched_start;
  end if;
  if (v_row.booked_start_at at time zone 'Asia/Kuala_Lumpur') <= v_row.start_at then
    raise exception 'CASE4 FAIL: an EARLY start must leave booked_start_at later than start_at';
  end if;
  procedure_note := procedure_note || format('C2-C4 ok block=%sh | ', round(v_block, 3));

  -- ================================================================
  -- CASE 5 — check-in must not start, must not move the window, and must
  -- not charge twice.
  -- ================================================================
  v_sched_start := (v_now + interval '3 hours')::time;
  v_sched_end   := (v_now + interval '3 hours 50 minutes')::time;

  insert into public.appointments (
    customer_id, therapist_id, room_id, service_id, appointment_date,
    start_time, end_time, status, total_price, type, service_name,
    service_items, item_count, notes, assignment_source, payment_status,
    outlet_id, created_by)
  values (null, v_ther, v_room, v_service, v_now::date,
    v_sched_start, v_sched_end, 'confirmed', 100, 'appointment', v_sname,
    '[]'::jsonb, 1, 'REG_C5', 'manual_override', 'paid', v_outlet, v_staff)
  returning id into v_appt;

  select count(*) into v_t0 from public.transactions;
  select * into v_ci from public.check_in_appointment(
    v_appt, v_addons, null, null, 50, 3, 53, 'cash', 'REG1');
  select * into v_row from public.appointments where id = v_appt;
  select count(*) into v_t1 from public.transactions;

  if not v_ci.success then
    raise exception 'CASE5 FAIL: check-in failed % %', v_ci.error_code, v_ci.error_message;
  end if;
  if v_row.actual_started_at is not null then
    raise exception 'CASE5 FAIL: check-in set actual_started_at';
  end if;
  if v_row.status::text <> 'confirmed' then
    raise exception 'CASE5 FAIL: check-in changed status to %', v_row.status;
  end if;
  if v_row.start_time <> v_sched_start or v_row.end_time <> v_sched_end then
    raise exception 'CASE5 FAIL: check-in moved the operational window to %-%',
      v_row.start_time, v_row.end_time;
  end if;
  if v_row.checked_in_at is null or v_row.checked_in_by is distinct from v_staff then
    raise exception 'CASE5 FAIL: checked_in_at/by not stamped correctly';
  end if;
  if v_t1 - v_t0 <> 1 then
    raise exception 'CASE5 FAIL: expected exactly 1 transaction, got %', v_t1 - v_t0;
  end if;

  -- idempotent repeat
  select * into v_ci from public.check_in_appointment(
    v_appt, v_addons, null, null, 50, 3, 53, 'cash', 'REG2');
  select count(*) into v_t0 from public.transactions;
  if v_t0 <> v_t1 then
    raise exception 'CASE5 FAIL: repeated check-in charged again (delta %)', v_t0 - v_t1;
  end if;

  -- ================================================================
  -- CASE 6 — start after check-in preserves checked_in_at and booked_*.
  -- ================================================================
  perform public.start_appointment_service(v_appt, now(), null, false);
  select * into v_row from public.appointments where id = v_appt;

  if v_row.status::text <> 'in_progress' then
    raise exception 'CASE6 FAIL: start did not set in_progress (%)', v_row.status;
  end if;
  if v_row.actual_started_at is null then
    raise exception 'CASE6 FAIL: start did not set actual_started_at';
  end if;
  if v_row.checked_in_at is null then
    raise exception 'CASE6 FAIL: start cleared checked_in_at';
  end if;
  if v_row.booked_start_time <> v_sched_start then
    raise exception 'CASE6 FAIL: start rewrote booked_start_time to %', v_row.booked_start_time;
  end if;
  v_block := extract(epoch from (public.csp_appointment_block_end_at(v_row)
             - public.csp_appointment_start_at(v_row))) / 3600.0;
  if v_block <= 0 then
    raise exception 'CASE6 FAIL: non-positive block after start (% h)', v_block;
  end if;
  procedure_note := procedure_note || format('C5-C6 ok block=%sh', round(v_block, 3));

  raise exception 'P3_REGRESSION_PASS >>> %', procedure_note;
end;
$regression$;
