-- Migration 123 lifecycle and pricing behavior. All fixture writes roll back.
-- Run only after applying migration 123 to a disposable/local test database.

begin;

do $test$
declare
  v_catalogue uuid;
  v_single_start timestamptz;
  v_expiry_start timestamptz;
  v_group_start timestamptz;
  v_group_allocations jsonb;
  v_single record;
  v_replacement record;
  v_group record;
  v_hold public.booking_holds%rowtype;
  v_expired public.booking_holds%rowtype;
  v_appointment public.appointments%rowtype;
  v_original_therapist uuid;
  v_original_room uuid;
  v_original_room_unit uuid;
  v_transaction uuid;
  v_duplicate_transaction uuid;
  v_queue_before jsonb;
  v_queue_after jsonb;
  v_breakdown record;
  v_cancel_claim record;
  v_retry_claim record;
  v_rejected boolean := false;
begin
  -- Find one public treatment with three currently available future slots.
  select candidate.catalogue_id,
         candidate.starts[1],
         candidate.starts[2],
         candidate.starts[3]
  into v_catalogue, v_single_start, v_expiry_start, v_group_start
  from (
    select catalogue.id as catalogue_id,
           array_agg(slot.start_at order by slot.start_at) as starts
    from public.online_booking_services catalogue
    cross join lateral generate_series(
      current_date + 1,
      current_date + 30,
      interval '1 day'
    ) day
    cross join lateral public.get_public_booking_slots_v2(
      catalogue.id,
      day::date,
      'none'
    ) slot
    where catalogue.enabled
    group by catalogue.id
    having count(*) >= 3
    order by catalogue.id
    limit 1
  ) candidate;

  if v_catalogue is null then
    raise exception 'Migration 123 test fixture needs one catalogue with three future slots';
  end if;

  -- Single hold creation: exact resources and a maximum ten-minute lifetime.
  select *
  into v_single
  from public.create_public_booking_hold_v2(
    v_catalogue,
    v_single_start,
    'none',
    'M123 Single',
    '0123456789',
    'm123-single@example.test',
    '',
    'migration 123 rollback test',
    'm123-single-' || gen_random_uuid()::text
  );

  select *
  into v_hold
  from public.booking_holds
  where id = v_single.hold_id;

  if v_hold.assigned_therapist_id is null
     or v_hold.assigned_room_id is null
     or v_hold.expires_at - v_hold.created_at
          <> interval '10 minutes' then
    raise exception 'Single hold did not reserve exact resources for ten minutes';
  end if;

  v_original_therapist := v_hold.assigned_therapist_id;
  v_original_room := v_hold.assigned_room_id;
  v_original_room_unit := v_hold.assigned_room_unit_id;

  -- An unpaid hold cannot enter the paid conversion boundary.
  begin
    perform public.process_paid_public_booking_hold(
      v_single.hold_token,
      'M123-UNRECORDED-BILL'
    );
  exception
    when others then
      v_rejected := sqlerrm ilike '%billplz bill does not match%';
  end;
  if not v_rejected then
    raise exception 'Unpaid conversion was not rejected';
  end if;
  if exists (
    select 1
    from public.booking_holds
    where id = v_single.hold_id
      and (status <> 'pending_payment' or appointment_id is not null)
  ) then
    raise exception 'Rejected unpaid conversion changed the hold';
  end if;

  -- A verified-callback-equivalent call converts the same resources, remains
  -- confirmed, and does not consume the therapist queue.
  perform public.record_billplz_bill(
    v_single.hold_token,
    'M123-SINGLE-PAID'
  );
  select to_jsonb(queue_row)
  into v_queue_before
  from public.therapist_queue queue_row
  where queue_row.outlet_id = v_hold.outlet_id
    and queue_row.queue_date =
      (v_hold.start_at at time zone 'Asia/Kuala_Lumpur')::date
    and queue_row.therapist_id = v_hold.assigned_therapist_id;

  v_transaction := public.process_paid_public_booking_hold(
    v_single.hold_token,
    'M123-SINGLE-PAID'
  );
  v_duplicate_transaction := public.process_paid_public_booking_hold(
    v_single.hold_token,
    'M123-SINGLE-PAID'
  );

  if v_transaction is null
     or v_duplicate_transaction is distinct from v_transaction then
    raise exception 'Duplicate paid callback was not idempotent';
  end if;

  select appointment.*
  into v_appointment
  from public.appointments appointment
  join public.booking_holds hold on hold.appointment_id = appointment.id
  where hold.id = v_single.hold_id;

  if v_appointment.status::text <> 'confirmed'
     or v_appointment.actual_started_at is not null
     or v_appointment.therapist_id is distinct from v_original_therapist
     or v_appointment.room_id is distinct from v_original_room
     or v_appointment.room_unit_id is distinct from v_original_room_unit then
    raise exception 'Paid conversion changed resources or started the service';
  end if;

  select to_jsonb(queue_row)
  into v_queue_after
  from public.therapist_queue queue_row
  where queue_row.outlet_id = v_hold.outlet_id
    and queue_row.queue_date =
      (v_hold.start_at at time zone 'Asia/Kuala_Lumpur')::date
    and queue_row.therapist_id = v_hold.assigned_therapist_id;
  if v_queue_after is distinct from v_queue_before then
    raise exception 'Paid conversion consumed or changed the therapist queue';
  end if;

  -- Expiry releases the same slot. A late paid callback is acknowledged by
  -- the Edge layer but the database conversion boundary must reject it.
  select *
  into v_single
  from public.create_public_booking_hold_v2(
    v_catalogue,
    v_expiry_start,
    'none',
    'M123 Expiry',
    '0123456790',
    'm123-expiry@example.test',
    '',
    'migration 123 rollback test',
    'm123-expiry-' || gen_random_uuid()::text
  );
  perform public.record_billplz_bill(v_single.hold_token, 'M123-LATE-BILL');
  update public.booking_holds
  set expires_at = now() - interval '1 second'
  where id = v_single.hold_id;
  perform public.expire_stale_booking_holds();
  select * into v_expired
  from public.booking_holds
  where id = v_single.hold_id;
  if v_expired.status <> 'expired' then
    raise exception 'Ten-minute expiry did not release the hold';
  end if;

  select *
  into v_replacement
  from public.create_public_booking_hold_v2(
    v_catalogue,
    v_expiry_start,
    'none',
    'M123 Replacement',
    '0123456791',
    'm123-replacement@example.test',
    '',
    'migration 123 rollback test',
    'm123-replacement-' || gen_random_uuid()::text
  );
  if v_replacement.hold_id is null then
    raise exception 'Expired resources could not be reserved again';
  end if;

  v_rejected := false;
  begin
    perform public.process_paid_public_booking_hold(
      v_single.hold_token,
      'M123-LATE-BILL'
    );
  exception
    when others then
      v_rejected := sqlerrm ilike '%after booking hold expired%';
  end;
  if not v_rejected or v_expired.appointment_id is not null then
    raise exception 'Late callback converted an expired hold';
  end if;

  -- External cancellation is claimed once, retains failures for retry, and
  -- records a successful retry without removing the Billplz reference.
  select *
  into v_cancel_claim
  from public.claim_booking_bill_cancellation(
    v_single.hold_token,
    'expired'
  );
  if not coalesce(v_cancel_claim.claim_acquired, false)
     or v_cancel_claim.bill_id <> 'M123-LATE-BILL'
     or v_cancel_claim.cancellation_claim_token is null then
    raise exception 'Expired Billplz cancellation was not claimed';
  end if;

  if not public.fail_billplz_cancellation(
    v_cancel_claim.hold_id,
    v_cancel_claim.cancellation_claim_token,
    'sandbox cancellation failure'
  ) then
    raise exception 'Billplz cancellation failure was not retained';
  end if;

  select *
  into v_retry_claim
  from public.claim_booking_bill_cancellation(
    v_single.hold_token,
    'expired'
  );
  if not coalesce(v_retry_claim.claim_acquired, false)
     or v_retry_claim.cancellation_claim_token is null
     or v_retry_claim.cancellation_claim_token
          = v_cancel_claim.cancellation_claim_token then
    raise exception 'Failed Billplz cancellation was not retryable';
  end if;

  if not public.complete_billplz_cancellation(
    v_retry_claim.hold_id,
    v_retry_claim.cancellation_claim_token
  ) then
    raise exception 'Billplz cancellation retry was not completed';
  end if;

  select *
  into v_expired
  from public.booking_holds
  where id = v_single.hold_id;
  if v_expired.billplz_cancelled_at is null
     or v_expired.billplz_cancellation_attempts <> 2
     or v_expired.billplz_cancellation_last_error is not null
     or v_expired.billplz_bill_id <> 'M123-LATE-BILL' then
    raise exception 'Billplz cancellation audit state is incorrect';
  end if;

  -- Group hold creation reserves one exact therapist and room for every pax.
  v_group_allocations := jsonb_build_array(
    jsonb_build_object(
      'catalogue_id', v_catalogue,
      'therapist_preference', 'none',
      'guest_name', 'Guest 1'
    ),
    jsonb_build_object(
      'catalogue_id', v_catalogue,
      'therapist_preference', 'none',
      'guest_name', 'Guest 2'
    )
  );
  select slot.start_at
  into v_group_start
  from generate_series(
    current_date + 1,
    current_date + 30,
    interval '1 day'
  ) day
  cross join lateral public.get_public_booking_group_slots_v1(
    v_group_allocations,
    day::date
  ) slot
  order by slot.start_at
  limit 1;
  if v_group_start is null then
    raise exception 'Migration 123 test fixture needs one available two-pax group slot';
  end if;

  select *
  into v_group
  from public.create_public_booking_group_hold_v1(
    v_group_allocations,
    v_group_start,
    'M123 Group',
    '0123456792',
    'm123-group@example.test',
    'migration 123 rollback test',
    'm123-group-' || gen_random_uuid()::text
  );
  if v_group.guest_count <> 2
     or (
       select count(*)
       from public.booking_holds hold
       where hold.booking_group_token = v_group.group_token
         and hold.assigned_therapist_id is not null
         and hold.assigned_room_id is not null
         and hold.expires_at <= hold.created_at + interval '10 minutes'
     ) <> 2 then
    raise exception 'Group hold did not reserve exact resources for both guests';
  end if;

  -- Direct group confirmation has its own all-pax expiry guard even though
  -- service_role cannot call it outside this rollback-only database test.
  update public.booking_holds
  set expires_at = now() - interval '1 second'
  where booking_group_token = v_group.group_token
    and guest_index = 2;
  v_rejected := false;
  begin
    perform public.confirm_public_booking_group_v1(v_group.group_token);
  exception
    when others then
      v_rejected := sqlerrm ilike '%expired%';
  end;
  if not v_rejected then
    raise exception 'Direct group confirmation accepted an expired pax hold';
  end if;

  -- Explicit pricing contexts.
  select * into v_breakdown
  from public.outlet_payment_breakdown(
    '00000000-0000-0000-0000-000000000128',
    39,
    'appointment_addon'
  );
  if v_breakdown.service_price <> 39
     or v_breakdown.sst_amount <> 0
     or v_breakdown.total_amount <> 39 then
    raise exception 'PV128 appointment add-on pricing is incorrect';
  end if;

  select * into v_breakdown
  from public.outlet_payment_breakdown(
    '00000000-0000-0000-0000-000000000002',
    39,
    'appointment_addon'
  );
  if v_breakdown.service_price <> 39
     or v_breakdown.sst_amount <> 2.30
     or v_breakdown.total_amount <> 41.30 then
    raise exception 'Taman Wahyu appointment add-on pricing is incorrect';
  end if;

  select * into v_breakdown
  from public.outlet_payment_breakdown(
    '00000000-0000-0000-0000-000000000128',
    39,
    'billplz'
  );
  if v_breakdown.sst_amount <= 0 or v_breakdown.total_amount <> 39 then
    raise exception 'PV128 Billplz is not inclusive/nett';
  end if;
  select * into v_breakdown
  from public.outlet_payment_breakdown(
    '00000000-0000-0000-0000-000000000002',
    39,
    'billplz'
  );
  if v_breakdown.sst_amount <= 0 or v_breakdown.total_amount <> 39 then
    raise exception 'Taman Wahyu Billplz is not inclusive/nett';
  end if;

  select * into v_breakdown
  from public.outlet_payment_breakdown(
    '00000000-0000-0000-0000-000000000128',
    39,
    'counter'
  );
  if v_breakdown.total_amount <> 39 then
    raise exception 'Migration 123 changed PV128 counter pricing';
  end if;
  select * into v_breakdown
  from public.outlet_payment_breakdown(
    '00000000-0000-0000-0000-000000000002',
    39,
    'counter'
  );
  if v_breakdown.sst_amount <> 2.30
     or v_breakdown.total_amount <> 41.30 then
    raise exception 'Migration 123 changed Taman Wahyu counter pricing';
  end if;
end
$test$;

rollback;
