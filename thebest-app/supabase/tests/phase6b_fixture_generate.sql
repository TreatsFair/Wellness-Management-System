-- Phase 6B concurrency fixture GENERATOR.
--
-- Replaces the previous phase6b_fixture.example.json, which was invalid: it
-- contained invented identifiers ('group-uuid-1', 'room-u-1', placeholder
-- therapist/service/room UUIDs) and cleaned up by deleting appointments on a
-- general date/time, which would have destroyed unrelated rows.
--
-- This script creates DISPOSABLE records, every one of them carrying a single
-- unique scenario marker, and prints the harness config JSON with the real
-- generated UUIDs substituted in. Cleanup is expressed against the marker and
-- the generated ids only — never against a bare date or time.
--
-- =====================================================================
-- SAFETY CONTRACT — read before running
-- =====================================================================
--   * Intended for a disposable/staging project only. It COMMITS.
--   * It does NOT enable capacity_first_enabled. The harness scenarios that
--     need the flag must set and reset it explicitly, per outlet.
--   * Every row it writes has notes / group_name / customer.name beginning
--     with the marker, so teardown is exact.
--   * Run phase6b_fixture_teardown.sql (printed at the end) afterwards.
--   * The concurrency harness has NOT been executed. Nothing in this repo
--     may claim concurrency verification until it has been, against a
--     fixture produced by this script, using two genuine parallel sessions.
-- =====================================================================
--
-- Usage:
--   psql "$CONN" -v ON_ERROR_STOP=1 -f phase6b_fixture_generate.sql \
--     > phase6b_fixture.local.json
--   (then hand-insert your connection_string into the emitted JSON, or set
--    PGHARNESS_CONN below)
--
-- The emitted JSON matches the contract phase6b_concurrency_harness.ps1
-- expects: connection_string, staff_user_id, scenarios[{name, action_a,
-- action_b, verify_sql, cleanup_sql}] with all six required scenario names.

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

do $gen$
declare
  v_marker text := 'PH6B_' || replace(gen_random_uuid()::text, '-', '');
  v_outlet uuid;
  v_service uuid;
  v_service_name text;
  v_duration integer;
  v_buffer integer;
  v_room_type text;
  v_therapist uuid;
  v_room uuid;
  v_room_unit uuid;
  v_customer uuid;
  v_staff uuid;
  v_date date;
  v_start time;
  v_end time;
  v_appt_single uuid;
  v_group uuid;
  v_group_a uuid;
  v_group_b uuid;
  v_cand record;
begin
  -- ---------------------------------------------------------------
  -- Pick a real, self-consistent outlet / service / therapist / room.
  -- ---------------------------------------------------------------
  select
    s.outlet_id, s.id, s.name,
    greatest(s.duration, 30), coalesce(s.buffer_after_minutes, 0),
    lower(trim(s.room_type::text)), t.id, d::date, wh.start_time
  into
    v_outlet, v_service, v_service_name,
    v_duration, v_buffer, v_room_type, v_therapist, v_date, v_start
  from public.services s
  join public.therapists t
    on t.outlet_id = s.outlet_id
   and coalesce(t.availability_status, true)
   and lower(coalesce(t.role, 'therapist')) = 'therapist'
   and (t.service_commissions = '{}'::jsonb or t.service_commissions ? s.id::text)
  join public.therapist_working_hours wh
    on wh.therapist_id = t.id
  cross join lateral generate_series(
    current_date + 2, current_date + 21, interval '1 day'
  ) d
  where s.is_active
    and wh.day_of_week = extract(dow from d)::integer
    and (
      d::date + wh.start_time
      + make_interval(mins => 3 * (greatest(s.duration, 30)
                                   + greatest(coalesce(s.buffer_after_minutes, 0), 0)))
    ) <= (
      d::date + wh.end_time
      + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
    )
    and exists (
      select 1 from public.rooms r
      where r.outlet_id = s.outlet_id
        and coalesce(r.is_active, true)
        and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, '')))
            = lower(trim(s.room_type::text))
    )
  order by d, s.id, t.id
  limit 1;

  if v_outlet is null then
    raise exception
      'Fixture generation failed: no viable outlet/service/therapist/room/date';
  end if;

  v_end := (v_start + make_interval(mins => v_duration))::time;

  select r.id into v_room
  from public.rooms r
  where r.outlet_id = v_outlet
    and coalesce(r.is_active, true)
    and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type
  order by r.total_slots desc, r.id
  limit 1;

  select u.id into v_room_unit
  from public.room_units u
  where u.zone_id = v_room and u.outlet_id = v_outlet and u.is_active
  order by u.id
  limit 1;

  select p.id into v_staff
  from public.profiles p
  order by case when p.role = 'admin' then 0 else 1 end, p.id
  limit 1;

  if v_staff is null then
    raise exception 'Fixture generation failed: no profiles row to act as staff';
  end if;

  -- ---------------------------------------------------------------
  -- Disposable customer, marked.
  -- ---------------------------------------------------------------
  insert into public.customers (name, phone, outlet_id)
  values (v_marker || '_customer', '0' || substr(replace(v_marker, 'PH6B_', ''), 1, 9), v_outlet)
  returning id into v_customer;

  -- ---------------------------------------------------------------
  -- Scenario subject 1: a single confirmed future appointment.
  -- ---------------------------------------------------------------
  insert into public.appointments (
    customer_id, therapist_id, room_id, service_id, appointment_date,
    start_time, end_time, start_at, end_at, buffer_after_minutes,
    status, total_price, type, service_name, service_items, item_count,
    notes, assignment_source, outlet_id
  ) values (
    v_customer, v_therapist, v_room, v_service, v_date,
    v_start, v_end,
    public.csp_start_at(v_date, v_start),
    public.csp_end_at(v_date, v_start, v_end),
    v_buffer, 'confirmed', 100.00, 'appointment', v_service_name,
    '[]'::jsonb, 1, v_marker, 'manual_override', v_outlet
  ) returning id into v_appt_single;

  -- ---------------------------------------------------------------
  -- Scenario subject 2: a two-pax group, staggered so one therapist
  -- can legitimately cover both.
  -- ---------------------------------------------------------------
  insert into public.appointment_groups (
    customer_id, group_name, pax_count, appointment_date, status, notes, outlet_id
  ) values (
    v_customer, v_marker || '_group', 2, v_date, 'confirmed', v_marker, v_outlet
  ) returning id into v_group;

  insert into public.appointments (
    appointment_group_id, customer_id, therapist_id, room_id, service_id,
    appointment_date, start_time, end_time, start_at, end_at,
    buffer_after_minutes, status, total_price, type, service_name,
    service_items, item_count, notes, assignment_source, outlet_id
  ) values (
    v_group, v_customer, v_therapist, v_room, v_service, v_date,
    (v_start + make_interval(mins => v_duration + v_buffer))::time,
    (v_start + make_interval(mins => 2 * v_duration + v_buffer))::time,
    public.csp_start_at(v_date, (v_start + make_interval(mins => v_duration + v_buffer))::time),
    public.csp_end_at(v_date,
      (v_start + make_interval(mins => v_duration + v_buffer))::time,
      (v_start + make_interval(mins => 2 * v_duration + v_buffer))::time),
    v_buffer, 'confirmed', 100.00, 'appointment', v_service_name,
    '[]'::jsonb, 1, v_marker, 'manual_override', v_outlet
  ) returning id into v_group_a;

  insert into public.appointments (
    appointment_group_id, customer_id, therapist_id, room_id, service_id,
    appointment_date, start_time, end_time, start_at, end_at,
    buffer_after_minutes, status, total_price, type, service_name,
    service_items, item_count, notes, assignment_source, outlet_id
  ) values (
    v_group, v_customer, v_therapist, v_room, v_service, v_date,
    (v_start + make_interval(mins => 2 * (v_duration + v_buffer)))::time,
    (v_start + make_interval(mins => 3 * v_duration + 2 * v_buffer))::time,
    public.csp_start_at(v_date, (v_start + make_interval(mins => 2 * (v_duration + v_buffer)))::time),
    public.csp_end_at(v_date,
      (v_start + make_interval(mins => 2 * (v_duration + v_buffer)))::time,
      (v_start + make_interval(mins => 3 * v_duration + 2 * v_buffer))::time),
    v_buffer, 'confirmed', 100.00, 'appointment', v_service_name,
    '[]'::jsonb, 1, v_marker, 'manual_override', v_outlet
  ) returning id into v_group_b;

  -- ---------------------------------------------------------------
  -- Emit the harness config. Every id below is real; every cleanup is
  -- scoped to this run's marker or to an id generated above.
  -- ---------------------------------------------------------------
  raise notice E'\n%', jsonb_pretty(jsonb_build_object(
    'connection_string', '<<FILL IN: postgresql://... for the disposable project>>',
    'staff_user_id', v_staff::text,
    'marker', v_marker,
    'teardown_sql', format(
      $t$delete from public.transactions t using public.appointments a
           where t.appointment_id = a.id and a.notes = %L;
         delete from public.transactions where appointment_group_id = %L;
         delete from public.appointments where notes = %L;
         delete from public.appointment_groups where id = %L;
         delete from public.customers where id = %L;$t$,
      v_marker, v_group, v_marker, v_group, v_customer),
    'scenarios', jsonb_build_array(

      jsonb_build_object(
        'name', 'double-confirm-appointment',
        'action_a', format(
          $a$select * from public.confirm_and_start_appointment(%L, %L, null, null, false, %L, %L, %L, %L, %L, 100.0, 6.0, 106.0, 'cash', %L, %L);$a$,
          v_appt_single, v_marker || '_A', v_room, v_room_unit, v_marker || '_clientA',
          v_customer, v_staff, v_marker || '_RA', v_marker),
        'action_b', format(
          $a$select * from public.confirm_and_start_appointment(%L, %L, null, null, false, %L, %L, %L, %L, %L, 100.0, 6.0, 106.0, 'cash', %L, %L);$a$,
          v_appt_single, v_marker || '_B', v_room, v_room_unit, v_marker || '_clientB',
          v_customer, v_staff, v_marker || '_RB', v_marker),
        'verify_sql', format(
          $v$do $chk$ begin
               if (select count(*) from public.appointments where id = %L
                     and status::text = 'in_progress' and actual_started_at is not null) <> 1
               then raise exception 'INVARIANT: appointment did not start exactly once'; end if;
               if (select count(*) from public.transactions where appointment_id = %L) <> 1
               then raise exception 'INVARIANT: expected exactly one payment transaction'; end if;
             end $chk$;$v$,
          v_appt_single, v_appt_single),
        'cleanup_sql', format(
          $c$delete from public.transactions where appointment_id = %L;
             update public.appointments set status = 'confirmed', actual_started_at = null,
               actual_completed_at = null, payment_status = 'unpaid',
               resources_confirmed_at = null, resources_confirmed_by = null
             where id = %L;$c$,
          v_appt_single, v_appt_single)
      ),

      jsonb_build_object(
        'name', 'double-confirm-group',
        'action_a', format(
          $a$select * from public.confirm_and_start_group(%L, %L, %L, %L, %L, %L, %L, 200.0, 12.0, 212.0, 'cash', %L, %L);$a$,
          v_group, v_marker || '_GA', v_customer, v_marker || '_clientGA', '0000000000',
          v_staff, v_marker, v_marker || '_RGA', v_marker),
        'action_b', format(
          $a$select * from public.confirm_and_start_group(%L, %L, %L, %L, %L, %L, %L, 200.0, 12.0, 212.0, 'cash', %L, %L);$a$,
          v_group, v_marker || '_GB', v_customer, v_marker || '_clientGB', '0000000000',
          v_staff, v_marker, v_marker || '_RGB', v_marker),
        'verify_sql', format(
          $v$do $chk$ begin
               if (select count(*) from public.appointments where appointment_group_id = %L
                     and status::text = 'in_progress') <> 2
               then raise exception 'INVARIANT: both group pax must be started'; end if;
               if (select count(*) from public.transactions where appointment_group_id = %L) <> 1
               then raise exception 'INVARIANT: expected exactly one group payment'; end if;
             end $chk$;$v$,
          v_group, v_group),
        'cleanup_sql', format(
          $c$delete from public.transactions where appointment_group_id = %L;
             update public.appointments set status = 'confirmed', actual_started_at = null,
               actual_completed_at = null, payment_status = 'unpaid',
               resources_confirmed_at = null, resources_confirmed_by = null
             where id in (%L, %L);$c$,
          v_group, v_group_a, v_group_b)
      ),

      jsonb_build_object(
        'name', 'final-therapist-future-booking',
        'action_a', format(
          $a$select * from public.create_appointment_with_csp(%L, %L, null, %L, %L, %L, %L, 100.0, 'appointment', %L, %L, '[]'::jsonb, 1, %L, null, 'specific_customer_request', %L, null, false);$a$,
          v_customer, v_therapist, v_service, v_date,
          (v_start + make_interval(mins => 3 * (v_duration + v_buffer)))::time,
          (v_start + make_interval(mins => 4 * v_duration + 3 * v_buffer))::time,
          v_staff, v_service_name, v_marker || '_T', v_therapist),
        'action_b', format(
          $a$select * from public.create_appointment_with_csp(%L, %L, null, %L, %L, %L, %L, 100.0, 'appointment', %L, %L, '[]'::jsonb, 1, %L, null, 'specific_customer_request', %L, null, false);$a$,
          v_customer, v_therapist, v_service, v_date,
          (v_start + make_interval(mins => 3 * (v_duration + v_buffer)))::time,
          (v_start + make_interval(mins => 4 * v_duration + 3 * v_buffer))::time,
          v_staff, v_service_name, v_marker || '_T', v_therapist),
        'verify_sql', format(
          $v$do $chk$ begin
               if (select count(*) from public.appointments where notes = %L) <> 1
               then raise exception 'INVARIANT: exactly one of the two racing therapist bookings must win'; end if;
             end $chk$;$v$,
          v_marker || '_T'),
        'cleanup_sql', format(
          $c$delete from public.appointments where notes = %L;$c$, v_marker || '_T')
      ),

      jsonb_build_object(
        'name', 'final-room-future-booking',
        'action_a', format(
          $a$select * from public.create_appointment_with_csp(%L, null, %L, %L, %L, %L, %L, 100.0, 'appointment', %L, %L, '[]'::jsonb, 1, %L, null, 'manual_override', null, null, false);$a$,
          v_customer, v_room, v_service, v_date,
          (v_start + make_interval(mins => 4 * (v_duration + v_buffer)))::time,
          (v_start + make_interval(mins => 5 * v_duration + 4 * v_buffer))::time,
          v_staff, v_service_name, v_marker || '_R'),
        'action_b', format(
          $a$select * from public.create_appointment_with_csp(%L, null, %L, %L, %L, %L, %L, 100.0, 'appointment', %L, %L, '[]'::jsonb, 1, %L, null, 'manual_override', null, null, false);$a$,
          v_customer, v_room, v_service, v_date,
          (v_start + make_interval(mins => 4 * (v_duration + v_buffer)))::time,
          (v_start + make_interval(mins => 5 * v_duration + 4 * v_buffer))::time,
          v_staff, v_service_name, v_marker || '_R'),
        'verify_sql', format(
          $v$do $chk$
             declare v_slots integer; v_made integer;
             begin
               select greatest(coalesce(total_slots, 1), 1) into v_slots from public.rooms where id = %L;
               select count(*) into v_made from public.appointments where notes = %L;
               if v_made > v_slots
               then raise exception 'INVARIANT: room overbooked (% made, % slots)', v_made, v_slots; end if;
               if v_made < 1
               then raise exception 'INVARIANT: at least one racing room booking must succeed'; end if;
             end $chk$;$v$,
          v_room, v_marker || '_R'),
        'cleanup_sql', format(
          $c$delete from public.appointments where notes = %L;$c$, v_marker || '_R')
      ),

      jsonb_build_object(
        'name', 'confirm-versus-walkin',
        'action_a', format(
          $a$select * from public.confirm_and_start_appointment(%L, %L, null, null, false, %L, %L, %L, %L, %L, 100.0, 6.0, 106.0, 'cash', %L, %L);$a$,
          v_appt_single, v_marker || '_CW', v_room, v_room_unit, v_marker || '_clientCW',
          v_customer, v_staff, v_marker || '_RCW', v_marker),
        'action_b', format(
          $a$select * from public.create_appointment_with_csp(%L, %L, %L, %L, %L, %L, %L, 100.0, 'walkin', %L, %L, '[]'::jsonb, 1, %L, null, 'manual_override', %L, null, false);$a$,
          v_customer, v_therapist, v_room, v_service, v_date, v_start, v_end,
          v_staff, v_service_name, v_marker || '_W', v_therapist),
        'verify_sql', format(
          $v$do $chk$ begin
               -- The walk-in must not be able to double-book the same therapist
               -- and window that the confirm-and-start is occupying.
               if (select count(*) from public.appointments
                     where therapist_id = %L and appointment_date = %L
                       and start_time = %L and public.csp_blocks_schedule(status::text)) <> 1
               then raise exception 'INVARIANT: therapist double-booked across confirm vs walk-in'; end if;
             end $chk$;$v$,
          v_therapist, v_date, v_start),
        'cleanup_sql', format(
          $c$delete from public.transactions where appointment_id in
               (select id from public.appointments where notes = %L);
             delete from public.appointments where notes = %L;
             delete from public.transactions where appointment_id = %L;
             update public.appointments set status = 'confirmed', actual_started_at = null,
               actual_completed_at = null, payment_status = 'unpaid',
               resources_confirmed_at = null, resources_confirmed_by = null
             where id = %L;$c$,
          v_marker || '_W', v_marker || '_W', v_appt_single, v_appt_single)
      ),

      jsonb_build_object(
        'name', 'post-commit-timeout-retry',
        'action_a', format(
          $a$select * from public.confirm_and_start_appointment(%L, %L, null, null, false, %L, %L, %L, %L, %L, 100.0, 6.0, 106.0, 'cash', %L, %L);$a$,
          v_appt_single, v_marker || '_IDEMP', v_room, v_room_unit, v_marker || '_clientR',
          v_customer, v_staff, v_marker || '_RR', v_marker),
        'action_b', format(
          $a$select * from public.confirm_and_start_appointment(%L, %L, null, null, false, %L, %L, %L, %L, %L, 100.0, 6.0, 106.0, 'cash', %L, %L);$a$,
          v_appt_single, v_marker || '_IDEMP', v_room, v_room_unit, v_marker || '_clientR',
          v_customer, v_staff, v_marker || '_RR', v_marker),
        'verify_sql', format(
          $v$do $chk$ begin
               if (select count(*) from public.appointments where id = %L
                     and status::text = 'in_progress' and actual_started_at is not null) <> 1
               then raise exception 'INVARIANT: retry must be idempotent on the appointment'; end if;
               if (select count(*) from public.transactions where appointment_id = %L) <> 1
               then raise exception 'INVARIANT: retry created a duplicate transaction'; end if;
             end $chk$;$v$,
          v_appt_single, v_appt_single),
        'cleanup_sql', format(
          $c$delete from public.transactions where appointment_id = %L;
             update public.appointments set status = 'confirmed', actual_started_at = null,
               actual_completed_at = null, payment_status = 'unpaid',
               resources_confirmed_at = null, resources_confirmed_by = null
             where id = %L;$c$,
          v_appt_single, v_appt_single)
      )
    )
  ));

  raise notice 'Fixture marker: % — tear down with the teardown_sql above.', v_marker;
end;
$gen$;
