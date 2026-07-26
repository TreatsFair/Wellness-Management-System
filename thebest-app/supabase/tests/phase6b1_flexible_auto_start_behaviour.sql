-- Phase 6B.1 122t BEHAVIOURAL validation (rolled back).
--
-- Static coverage lives in phase6b1_flexible_auto_start_contract.sql. This
-- script exercises the real RPCs against real fixtures and asserts what 122t
-- actually promises at the atomic service-start boundary:
--
--   1. a queue appointment carrying a stale provisional therapist,
--   2. that therapist made busy by a walk-in,
--   3. another eligible therapist existing,
--   4. the final start automatically selecting the replacement,
--   5. payment, status and queue updated exactly once,
--
-- plus: clear failure with no partial payment/start when no replacement
-- exists, gender preference never crossing gender, specific_customer_request
-- and manual_override never silently replaced, multi-pax receiving distinct
-- therapists atomically (and failing whole when infeasible), retry
-- idempotency, and positive timezone-safe windows.
--
-- Fixtures are placed 371 days out and every write is rolled back.

\set ON_ERROR_STOP on

begin;

-- Fixture builders. pg_temp objects disappear with the transaction/session.
create function pg_temp.mk_appt(
  p_outlet uuid,
  p_service uuid,
  p_service_name text,
  p_room uuid,
  p_therapist uuid,
  p_date date,
  p_start time,
  p_duration integer,
  p_source text,
  p_requested_gender text,
  p_status text,
  p_type text,
  p_payment text,
  p_actual_start timestamptz,
  p_items jsonb,
  p_group uuid
)
returns uuid
language plpgsql
as $mk$
declare
  v_id uuid;
  v_start timestamp := p_date + p_start;
  v_end timestamp := p_date + p_start + make_interval(mins => p_duration);
begin
  insert into public.appointments (
    therapist_id, room_id, room_unit_id, service_id,
    appointment_date, start_time, end_time, start_at, end_at,
    booked_date, booked_start_time, booked_end_time,
    booked_start_at, booked_end_at,
    status, payment_status, total_price, type, outlet_id,
    service_name, service_items, item_count, assignment_source,
    requested_therapist_id, requested_gender,
    therapist_assignment_state, room_assignment_state,
    actual_started_at, appointment_group_id, notes
  ) values (
    p_therapist, p_room, null, p_service,
    p_date, p_start, v_end::time, v_start, v_end,
    p_date, p_start, v_end::time,
    v_start at time zone 'Asia/Kuala_Lumpur',
    v_end at time zone 'Asia/Kuala_Lumpur',
    p_status::public.appointment_status,
    p_payment::public.payment_status,
    100, p_type::public.appointment_type, p_outlet,
    coalesce(p_service_name, 'Service'), p_items, 1, p_source,
    case when p_source = 'specific_customer_request' then p_therapist else null end,
    p_requested_gender,
    case when p_actual_start is null then 'provisional' else 'confirmed' end,
    case when p_actual_start is null then 'provisional' else 'confirmed' end,
    p_actual_start, p_group, 'ZZ 122t fixture'
  )
  returning id into v_id;
  return v_id;
end;
$mk$;

do $behaviour$
declare
  v_staff uuid;
  v_outlet uuid;
  v_service uuid;
  v_service_name text;
  v_duration integer;
  v_room uuid;
  v_date date;
  v_dow integer;
  v_ta uuid; v_tb uuid; v_tc uuid; v_td uuid; v_te uuid;
  v_stale uuid;
  v_items jsonb;
  v_pay jsonb := '[{"method": "cash", "amount": 100}]'::jsonb;
  v_appt uuid;
  v_group uuid;
  v_g1 uuid;
  v_g2 uuid;
  v_res record;
  v_res2 record;
  v_row public.appointments%rowtype;
  v_row2 public.appointments%rowtype;
  v_txn_count integer;
  v_txn_first uuid;
  v_started timestamptz;
  v_consumed_before integer;
  v_consumed_after integer;
  v_chosen_gender text;
  v_txn_total_before bigint;
  v_group_status text;
  v_q_before jsonb;
  v_q_after jsonb;
begin
  ---------------------------------------------------------------------------
  -- Fixture selection
  ---------------------------------------------------------------------------
  select p.id into v_staff
  from public.profiles p
  where p.role in ('staff', 'admin')
  order by case p.role when 'staff' then 0 else 1 end, p.id
  limit 1;
  if v_staff is null then
    raise exception '122t: no staff/admin profile to impersonate';
  end if;
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_staff::text, 'role', 'authenticated')::text,
    true
  );
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception '122t: could not establish a staff context';
  end if;

  select r.outlet_id, s.id, s.name, coalesce(s.duration, 60), r.id
  into v_outlet, v_service, v_service_name, v_duration, v_room
  from public.rooms r
  join public.services s
    on s.outlet_id = r.outlet_id
   and coalesce(s.is_active, true)
   and lower(coalesce(s.room_type::text, '')) = lower(coalesce(r.room_type::text, ''))
   and coalesce(s.duration, 0) > 0
  where coalesce(r.is_active, true)
    and coalesce(r.allocation_mode, 'capacity') <> 'specific_room'
    and coalesce(r.total_slots, 1) >= 3
  order by coalesce(r.total_slots, 1) desc, r.id, s.id
  limit 1;
  if v_room is null then
    raise exception
      '122t: need an active capacity room (total_slots >= 3) with a matching service';
  end if;

  v_date := (now() at time zone 'Asia/Kuala_Lumpur')::date + 371;
  if exists (
    select 1 from public.appointments a
    where a.outlet_id = v_outlet and a.appointment_date = v_date
  ) then
    raise exception '122t: fixture date % is not empty in outlet %', v_date, v_outlet;
  end if;
  v_dow := extract(dow from v_date)::integer;
  v_duration := least(v_duration, 60);

  v_items := jsonb_build_array(jsonb_build_object(
    'id', v_service::text,
    'name', coalesce(v_service_name, 'Service'),
    'duration', v_duration,
    'price', 100
  ));

  ---------------------------------------------------------------------------
  -- Fixture therapists. service_commissions = '{}' means "all services".
  ---------------------------------------------------------------------------
  insert into public.therapists (name, gender, availability_status, role,
    service_commissions, outlet_id, display_order)
  values
    ('ZZ 122t A', 'female', true, 'Therapist', '{}'::jsonb, v_outlet, 9001),
    ('ZZ 122t B', 'male',   true, 'Therapist', '{}'::jsonb, v_outlet, 9002),
    ('ZZ 122t C', 'female', true, 'Therapist', '{}'::jsonb, v_outlet, 9003),
    ('ZZ 122t D', 'female', true, 'Therapist', '{}'::jsonb, v_outlet, 9004),
    ('ZZ 122t E', 'male',   true, 'Therapist', '{}'::jsonb, v_outlet, 9005);

  select id into v_ta from public.therapists where name = 'ZZ 122t A';
  select id into v_tb from public.therapists where name = 'ZZ 122t B';
  select id into v_tc from public.therapists where name = 'ZZ 122t C';
  select id into v_td from public.therapists where name = 'ZZ 122t D';
  select id into v_te from public.therapists where name = 'ZZ 122t E';
  v_stale := v_td;

  insert into public.therapist_working_hours (
    outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
  )
  select v_outlet, t.id, v_dow, time '00:00', time '23:59', true
  from public.therapists t
  where t.outlet_id = v_outlet
    and not exists (
      select 1 from public.therapist_working_hours h
      where h.therapist_id = t.id and h.day_of_week = v_dow
    );

  ---------------------------------------------------------------------------
  -- CASES 1-5 (single, queue): stale provisional therapist is busy from a
  -- walk-in, another eligible therapist exists, the final start replaces the
  -- stale therapist, and payment/status/queue move exactly once.
  ---------------------------------------------------------------------------
  -- (2) the stale therapist becomes busy from a walk-in over 09:00-10:00
  perform pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room, v_stale,
    v_date, time '09:00', v_duration, 'queue', null, 'in_progress', 'walkin',
    'paid', (v_date + time '09:00') at time zone 'Asia/Kuala_Lumpur',
    v_items, null);

  -- (1) queue appointment still carrying the now-stale provisional therapist
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '09:00', v_duration, 'queue', null, 'pending',
    'appointment', 'unpaid', null, v_items, null);

  -- (3) other eligible therapists exist by construction (A, B, C, E are free)
  select count(*) into v_consumed_before
  from public.therapist_queue q
  where q.outlet_id = v_outlet and q.queue_date = v_date
    and q.turn_consumed_at is not null;
  select count(*) into v_txn_total_before from public.transactions;

  -- (4) final start: the app still sends the stale provisional therapist
  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000001', '', '',
    v_items, v_pay, v_stale, 'queue', null,
    v_room, null,
    (v_date + time '09:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '09:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-1'
  );

  if not coalesce(v_res.success, false) then
    raise exception
      '122t CASE 4 failed: queue start did not replace the stale therapist (% / %)',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;
  if v_res.therapist_id is null or v_res.therapist_id = v_stale then
    raise exception
      '122t CASE 4 failed: start kept the busy stale therapist %', v_res.therapist_id;
  end if;
  if not exists (
    select 1 from public.therapists t
    where t.id = v_res.therapist_id
      and t.outlet_id = v_outlet
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
  ) then
    raise exception
      '122t CASE 4 failed: replacement % is not an active outlet therapist',
      v_res.therapist_id;
  end if;

  select * into v_row from public.appointments a where a.id = v_appt;

  -- (5) payment exactly once
  select count(*), min(t.id) into v_txn_count, v_txn_first
  from public.transactions t where t.appointment_id = v_appt;
  if v_txn_count <> 1 then
    raise exception '122t CASE 5 failed: expected 1 transaction, found %', v_txn_count;
  end if;
  if v_row.payment_status::text <> 'paid' then
    raise exception '122t CASE 5 failed: payment_status is %', v_row.payment_status;
  end if;

  -- (5) status exactly once, and the actual start is the value we passed
  if v_row.status::text <> 'in_progress' then
    raise exception '122t CASE 5 failed: status is %', v_row.status;
  end if;
  v_started := (v_date + time '09:00') at time zone 'Asia/Kuala_Lumpur';
  if v_row.actual_started_at is distinct from v_started then
    raise exception
      '122t CASE 5 failed: actual_started_at % <> passed start %',
      v_row.actual_started_at, v_started;
  end if;
  if v_row.therapist_id is distinct from v_res.therapist_id then
    raise exception '122t CASE 5 failed: row therapist % <> returned %',
      v_row.therapist_id, v_res.therapist_id;
  end if;

  -- start_at/end_at positive and timezone-safe (naive local projection)
  if v_row.end_at <= v_row.start_at then
    raise exception '122t failed: inverted window % -> %',
      v_row.start_at, v_row.end_at;
  end if;
  if v_row.start_at is distinct from (v_date + time '09:00') then
    raise exception '122t failed: start_at % is not local 09:00 on %',
      v_row.start_at, v_date;
  end if;
  if v_row.end_at - v_row.start_at <> make_interval(mins => v_duration) then
    raise exception '122t failed: window length % <> % minutes',
      v_row.end_at - v_row.start_at, v_duration;
  end if;

  -- (5) queue consumed exactly once, for the replacement, not the stale one
  select count(*) into v_consumed_after
  from public.therapist_queue q
  where q.outlet_id = v_outlet and q.queue_date = v_date
    and q.turn_consumed_at is not null;
  if v_consumed_after <> v_consumed_before + 1 then
    raise exception
      '122t CASE 5 failed: queue consumption count moved % -> % (expected +1)',
      v_consumed_before, v_consumed_after;
  end if;
  if not exists (
    select 1 from public.therapist_queue q
    where q.outlet_id = v_outlet and q.queue_date = v_date
      and q.therapist_id = v_res.therapist_id
      and q.turn_consumed_at = v_started
  ) then
    raise exception
      '122t CASE 5 failed: replacement % did not consume its queue turn',
      v_res.therapist_id;
  end if;

  ---------------------------------------------------------------------------
  -- Retry: one transaction, one start timestamp, one queue consumption.
  ---------------------------------------------------------------------------
  select jsonb_agg(jsonb_build_object(
    'therapist', q.therapist_id, 'pos', q.queue_position,
    'consumed', q.turn_consumed_at) order by q.therapist_id)
  into v_q_before
  from public.therapist_queue q
  where q.outlet_id = v_outlet and q.queue_date = v_date;

  select * into v_res2
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000001', '', '',
    v_items, v_pay, v_stale, 'queue', null,
    v_room, null,
    (v_date + time '09:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '09:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-1'
  );
  if not coalesce(v_res2.success, false) then
    raise exception '122t RETRY failed: % / %',
      coalesce(v_res2.error_code, '<none>'), coalesce(v_res2.error_message, '<none>');
  end if;
  if v_res2.actual_started_at is distinct from v_started then
    raise exception '122t RETRY failed: second start timestamp % <> %',
      v_res2.actual_started_at, v_started;
  end if;
  if v_res2.transaction_id is distinct from v_txn_first then
    raise exception '122t RETRY failed: transaction % <> original %',
      v_res2.transaction_id, v_txn_first;
  end if;
  select count(*) into v_txn_count
  from public.transactions t where t.appointment_id = v_appt;
  if v_txn_count <> 1 then
    raise exception '122t RETRY failed: % transactions after retry', v_txn_count;
  end if;

  select jsonb_agg(jsonb_build_object(
    'therapist', q.therapist_id, 'pos', q.queue_position,
    'consumed', q.turn_consumed_at) order by q.therapist_id)
  into v_q_after
  from public.therapist_queue q
  where q.outlet_id = v_outlet and q.queue_date = v_date;
  if v_q_after is distinct from v_q_before then
    raise exception '122t RETRY failed: queue changed on retry';
  end if;

  ---------------------------------------------------------------------------
  -- No replacement exists: clear failure, no partial payment or start.
  ---------------------------------------------------------------------------
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '11:00', v_duration, 'queue', null, 'pending',
    'appointment', 'unpaid', null, v_items, null);

  insert into public.therapist_unavailability (
    outlet_id, therapist_id, starts_at, ends_at, internal_reason
  )
  select v_outlet, t.id,
    (v_date + time '10:30') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '12:30') at time zone 'Asia/Kuala_Lumpur',
    'ZZ 122t block all'
  from public.therapists t
  where t.outlet_id = v_outlet;

  select count(*) into v_txn_total_before from public.transactions;
  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000002', '', '',
    v_items, v_pay, v_stale, 'queue', null,
    v_room, null,
    (v_date + time '11:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '11:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-2'
  );
  if coalesce(v_res.success, false) then
    raise exception
      '122t NO-REPLACEMENT failed: start succeeded with therapist %',
      v_res.therapist_id;
  end if;
  if coalesce(v_res.error_message, '') not ilike '%no eligible therapist%' then
    raise exception
      '122t NO-REPLACEMENT failed: unclear failure (% / %)',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;

  select * into v_row from public.appointments a where a.id = v_appt;
  if v_row.actual_started_at is not null or v_row.status::text <> 'pending' then
    raise exception
      '122t NO-REPLACEMENT failed: partial start (status %, actual %)',
      v_row.status, v_row.actual_started_at;
  end if;
  if v_row.payment_status::text <> 'unpaid' then
    raise exception
      '122t NO-REPLACEMENT failed: partial payment (payment_status %)',
      v_row.payment_status;
  end if;
  if exists (
    select 1 from public.transactions t where t.appointment_id = v_appt
  ) then
    raise exception '122t NO-REPLACEMENT failed: a transaction was written';
  end if;
  if (select count(*) from public.transactions) <> v_txn_total_before then
    raise exception '122t NO-REPLACEMENT failed: transaction count changed';
  end if;

  delete from public.therapist_unavailability
  where internal_reason = 'ZZ 122t block all';

  ---------------------------------------------------------------------------
  -- Gender preference never crosses gender.
  ---------------------------------------------------------------------------
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '13:00', v_duration, 'gender_preference', 'male',
    'pending', 'appointment', 'unpaid', null, v_items, null);

  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000003', '', '',
    v_items, v_pay, v_stale, 'gender_preference', 'male',
    v_room, null,
    (v_date + time '13:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '13:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-3'
  );
  if not coalesce(v_res.success, false) then
    raise exception '122t GENDER failed: % / %',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;
  select lower(coalesce(t.gender, '')) into v_chosen_gender
  from public.therapists t where t.id = v_res.therapist_id;
  if v_chosen_gender <> 'male' then
    raise exception
      '122t GENDER failed: requested male, got therapist % with gender "%"',
      v_res.therapist_id, v_chosen_gender;
  end if;

  -- With every male blocked the start must fail rather than cross gender.
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '16:00', v_duration, 'gender_preference', 'male',
    'pending', 'appointment', 'unpaid', null, v_items, null);
  insert into public.therapist_unavailability (
    outlet_id, therapist_id, starts_at, ends_at, internal_reason
  )
  select v_outlet, t.id,
    (v_date + time '15:30') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '17:30') at time zone 'Asia/Kuala_Lumpur',
    'ZZ 122t block males'
  from public.therapists t
  where t.outlet_id = v_outlet and lower(coalesce(t.gender, '')) = 'male';

  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000004', '', '',
    v_items, v_pay, v_stale, 'gender_preference', 'male',
    v_room, null,
    (v_date + time '16:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '16:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-4'
  );
  if coalesce(v_res.success, false) then
    select lower(coalesce(t.gender, '')) into v_chosen_gender
    from public.therapists t where t.id = v_res.therapist_id;
    raise exception
      '122t GENDER failed: crossed gender to % therapist % when no male was free',
      v_chosen_gender, v_res.therapist_id;
  end if;
  select * into v_row from public.appointments a where a.id = v_appt;
  if v_row.actual_started_at is not null
     or v_row.payment_status::text <> 'unpaid' then
    raise exception '122t GENDER failed: partial start/payment on gender failure';
  end if;
  delete from public.therapist_unavailability
  where internal_reason = 'ZZ 122t block males';

  ---------------------------------------------------------------------------
  -- specific_customer_request is never silently replaced.
  ---------------------------------------------------------------------------
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_tb, v_date, time '18:00', v_duration, 'specific_customer_request', null,
    'pending', 'appointment', 'unpaid', null, v_items, null);
  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000005', '', '',
    v_items, v_pay, v_tb, 'specific_customer_request', null,
    v_room, null,
    (v_date + time '18:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '18:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-5'
  );
  if not coalesce(v_res.success, false) then
    raise exception '122t SPECIFIC failed: free requested therapist rejected (% / %)',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;
  if v_res.therapist_id is distinct from v_tb then
    raise exception
      '122t SPECIFIC failed: requested % was replaced by %', v_tb, v_res.therapist_id;
  end if;

  -- Busy requested therapist must fail, never be swapped for someone else.
  perform pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room, v_tc,
    v_date, time '19:30', v_duration, 'queue', null, 'in_progress', 'walkin',
    'paid', (v_date + time '19:30') at time zone 'Asia/Kuala_Lumpur',
    v_items, null);
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_tc, v_date, time '19:30', v_duration, 'specific_customer_request', null,
    'pending', 'appointment', 'unpaid', null, v_items, null);
  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000006', '', '',
    v_items, v_pay, v_tc, 'specific_customer_request', null,
    v_room, null,
    (v_date + time '19:30') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '19:30' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-6'
  );
  if coalesce(v_res.success, false) then
    raise exception
      '122t SPECIFIC failed: busy requested therapist silently replaced by %',
      v_res.therapist_id;
  end if;
  if coalesce(v_res.error_message, '') not ilike '%selected therapist is no longer available%'
  then
    raise exception '122t SPECIFIC failed: unclear failure (% / %)',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;
  select * into v_row from public.appointments a where a.id = v_appt;
  if v_row.therapist_id is distinct from v_tc
     or v_row.actual_started_at is not null
     or v_row.payment_status::text <> 'unpaid' then
    raise exception
      '122t SPECIFIC failed: row mutated on failure (therapist %, actual %, payment %)',
      v_row.therapist_id, v_row.actual_started_at, v_row.payment_status;
  end if;

  ---------------------------------------------------------------------------
  -- manual_override is never silently replaced.
  ---------------------------------------------------------------------------
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_td, v_date, time '21:00', v_duration, 'manual_override', null,
    'pending', 'appointment', 'unpaid', null, v_items, null);
  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000007', '', '',
    v_items, v_pay, v_td, 'manual_override', null,
    v_room, null,
    (v_date + time '21:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '21:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-7'
  );
  if not coalesce(v_res.success, false) then
    raise exception '122t OVERRIDE failed: free override therapist rejected (% / %)',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;
  if v_res.therapist_id is distinct from v_td then
    raise exception '122t OVERRIDE failed: override % replaced by %',
      v_td, v_res.therapist_id;
  end if;

  perform pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room, v_te,
    v_date, time '22:00', v_duration, 'queue', null, 'in_progress', 'walkin',
    'paid', (v_date + time '22:00') at time zone 'Asia/Kuala_Lumpur',
    v_items, null);
  v_appt := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_te, v_date, time '22:00', v_duration, 'manual_override', null,
    'pending', 'appointment', 'unpaid', null, v_items, null);
  select * into v_res
  from public.finalize_and_start_appointment(
    v_appt, 'ZZ 122t Customer', '0100000008', '', '',
    v_items, v_pay, v_te, 'manual_override', null,
    v_room, null,
    (v_date + time '22:00') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '22:00' + make_interval(mins => v_duration))
      at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 100, 0, 100, 'cash', 'ZZ122T-8'
  );
  if coalesce(v_res.success, false) then
    raise exception
      '122t OVERRIDE failed: busy override therapist silently replaced by %',
      v_res.therapist_id;
  end if;
  select * into v_row from public.appointments a where a.id = v_appt;
  if v_row.therapist_id is distinct from v_te
     or v_row.actual_started_at is not null then
    raise exception '122t OVERRIDE failed: row mutated on failure';
  end if;

  ---------------------------------------------------------------------------
  -- Multi-pax receives distinct therapists atomically.
  ---------------------------------------------------------------------------
  insert into public.appointment_groups (
    group_name, pax_count, appointment_date, status, outlet_id
  ) values ('ZZ 122t group', 2, v_date, 'confirmed', v_outlet)
  returning id into v_group;

  -- both pax carry the same stale provisional therapist
  v_g1 := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '07:00', v_duration, 'queue', null, 'pending',
    'appointment', 'unpaid', null, v_items, v_group);
  v_g2 := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '07:00', v_duration, 'queue', null, 'pending',
    'appointment', 'unpaid', null, v_items, v_group);

  select count(*) into v_txn_total_before from public.transactions;
  select * into v_res
  from public.finalize_and_start_appointment_group(
    v_group,
    array[v_g1, v_g2],
    'ZZ 122t Group Customer', '0100000009',
    jsonb_build_object(
      v_g1::text, jsonb_build_object(
        'room_id', v_room::text, 'assignment_source', 'queue',
        'service_items', v_items),
      v_g2::text, jsonb_build_object(
        'room_id', v_room::text, 'assignment_source', 'queue',
        'service_items', v_items)
    ),
    v_pay,
    (v_date + time '07:00') at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 200, 0, 200, 'cash', 'ZZ122T-G1'
  );
  if not coalesce(v_res.success, false) then
    raise exception '122t GROUP failed: % / %',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;
  select * into v_row from public.appointments a where a.id = v_g1;
  select * into v_row2 from public.appointments a where a.id = v_g2;
  if v_row.therapist_id is null or v_row2.therapist_id is null then
    raise exception '122t GROUP failed: a pax has no therapist';
  end if;
  if v_row.therapist_id = v_row2.therapist_id then
    raise exception '122t GROUP failed: both pax share therapist %',
      v_row.therapist_id;
  end if;
  if v_row.actual_started_at is distinct from v_row2.actual_started_at then
    raise exception '122t GROUP failed: pax start timestamps differ (% vs %)',
      v_row.actual_started_at, v_row2.actual_started_at;
  end if;
  if v_row.actual_started_at is distinct from
     ((v_date + time '07:00') at time zone 'Asia/Kuala_Lumpur') then
    raise exception '122t GROUP failed: start timestamp % is not the passed value',
      v_row.actual_started_at;
  end if;
  if v_row.end_at <= v_row.start_at or v_row2.end_at <= v_row2.start_at then
    raise exception '122t GROUP failed: inverted pax window';
  end if;
  if v_row.status::text <> 'in_progress' or v_row2.status::text <> 'in_progress'
     or v_row.payment_status::text <> 'paid'
     or v_row2.payment_status::text <> 'paid' then
    raise exception '122t GROUP failed: pax status/payment not moved once';
  end if;
  select count(*) into v_txn_count
  from public.transactions t where t.appointment_group_id = v_group;
  if v_txn_count <> 1 then
    raise exception '122t GROUP failed: expected 1 group transaction, found %',
      v_txn_count;
  end if;
  if (select count(*) from public.transactions) <> v_txn_total_before + 1 then
    raise exception '122t GROUP failed: more than one transaction was written';
  end if;

  -- Group retry stays idempotent.
  select * into v_res2
  from public.finalize_and_start_appointment_group(
    v_group, array[v_g1, v_g2],
    'ZZ 122t Group Customer', '0100000009',
    jsonb_build_object(
      v_g1::text, jsonb_build_object('room_id', v_room::text,
        'assignment_source', 'queue', 'service_items', v_items),
      v_g2::text, jsonb_build_object('room_id', v_room::text,
        'assignment_source', 'queue', 'service_items', v_items)
    ),
    v_pay,
    (v_date + time '07:00') at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 200, 0, 200, 'cash', 'ZZ122T-G1'
  );
  if not coalesce(v_res2.success, false) then
    raise exception '122t GROUP RETRY failed: % / %',
      coalesce(v_res2.error_code, '<none>'), coalesce(v_res2.error_message, '<none>');
  end if;
  if (select count(*) from public.transactions
      where appointment_group_id = v_group) <> 1 then
    raise exception '122t GROUP RETRY failed: a second transaction was written';
  end if;

  ---------------------------------------------------------------------------
  -- Infeasible combination fails whole: no pax starts, nothing is paid.
  ---------------------------------------------------------------------------
  insert into public.appointment_groups (
    group_name, pax_count, appointment_date, status, outlet_id
  ) values ('ZZ 122t group 2', 2, v_date, 'confirmed', v_outlet)
  returning id into v_group;
  v_g1 := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '05:00', v_duration, 'queue', null, 'pending',
    'appointment', 'unpaid', null, v_items, v_group);
  v_g2 := pg_temp.mk_appt(v_outlet, v_service, v_service_name, v_room,
    v_stale, v_date, time '05:00', v_duration, 'queue', null, 'pending',
    'appointment', 'unpaid', null, v_items, v_group);

  insert into public.therapist_unavailability (
    outlet_id, therapist_id, starts_at, ends_at, internal_reason
  )
  select v_outlet, t.id,
    (v_date + time '04:30') at time zone 'Asia/Kuala_Lumpur',
    (v_date + time '06:30') at time zone 'Asia/Kuala_Lumpur',
    'ZZ 122t leave one'
  from public.therapists t
  where t.outlet_id = v_outlet and t.id <> v_ta;

  select count(*) into v_txn_total_before from public.transactions;
  select * into v_res
  from public.finalize_and_start_appointment_group(
    v_group, array[v_g1, v_g2],
    'ZZ 122t Group Customer', '0100000010',
    jsonb_build_object(
      v_g1::text, jsonb_build_object('room_id', v_room::text,
        'assignment_source', 'queue', 'service_items', v_items),
      v_g2::text, jsonb_build_object('room_id', v_room::text,
        'assignment_source', 'queue', 'service_items', v_items)
    ),
    v_pay,
    (v_date + time '05:00') at time zone 'Asia/Kuala_Lumpur',
    null, 'ZZ 122t Counter', 200, 0, 200, 'cash', 'ZZ122T-G2'
  );
  if coalesce(v_res.success, false) then
    raise exception
      '122t GROUP ATOMICITY failed: started with only one eligible therapist';
  end if;
  if coalesce(v_res.error_code, '') <> 'NO_THERAPIST_COMBINATION' then
    raise exception '122t GROUP ATOMICITY failed: unclear failure (% / %)',
      coalesce(v_res.error_code, '<none>'), coalesce(v_res.error_message, '<none>');
  end if;
  select * into v_row from public.appointments a where a.id = v_g1;
  select * into v_row2 from public.appointments a where a.id = v_g2;
  if v_row.actual_started_at is not null or v_row2.actual_started_at is not null
     or v_row.payment_status::text <> 'unpaid'
     or v_row2.payment_status::text <> 'unpaid' then
    raise exception
      '122t GROUP ATOMICITY failed: partial start or payment on failure';
  end if;
  if (select count(*) from public.transactions) <> v_txn_total_before then
    raise exception
      '122t GROUP ATOMICITY failed: a transaction was written on failure';
  end if;
  select g.status into v_group_status
  from public.appointment_groups g where g.id = v_group;
  if v_group_status = 'in_progress' then
    raise exception
      '122t GROUP ATOMICITY failed: group moved to in_progress on failure';
  end if;

  ---------------------------------------------------------------------------
  -- Global window sanity across every fixture row.
  ---------------------------------------------------------------------------
  if exists (
    select 1 from public.appointments a
    where a.outlet_id = v_outlet and a.appointment_date = v_date
      and (a.end_at <= a.start_at
        or public.csp_appointment_end_at(a) <= public.csp_appointment_start_at(a))
  ) then
    raise exception '122t failed: a fixture row has a non-positive window';
  end if;

  raise notice '122t BEHAVIOURAL VALIDATION PASSED';
end
$behaviour$;

rollback;
