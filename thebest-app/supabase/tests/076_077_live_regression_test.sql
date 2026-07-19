begin;

select plan(18);

select ok(
  to_regclass('public.notifications') is not null,
  'notifications table exists'
);

select ok(
  to_regprocedure('public.get_available_slots(date,uuid,uuid,integer,uuid)') is not null,
  'smart staff slot RPC exists'
);

select ok(
  to_regprocedure('public.check_booking_availability(date,time without time zone,time without time zone,uuid,uuid,uuid,uuid)') is not null,
  'staff availability validator exists'
);

select ok(
  exists (
    select 1
    from public.therapists therapist
    join public.rooms room on room.outlet_id = therapist.outlet_id
    where coalesce(therapist.is_active, true)
      and coalesce(room.is_active, true)
  ),
  'production has a therapist/room fixture for read-only slot checks'
);

with fixture as (
  select therapist.id as therapist_id, room.id as room_id
  from public.therapists therapist
  join public.rooms room on room.outlet_id = therapist.outlet_id
  where coalesce(therapist.is_active, true)
    and coalesce(room.is_active, true)
  order by therapist.created_at, room.created_at
  limit 1
), slots as (
  select slot.*
  from fixture
  cross join lateral public.get_available_slots(
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1,
    fixture.therapist_id,
    fixture.room_id,
    60,
    null
  ) slot
)
select ok(
  not exists (
    select 1 from slots group by start_time having count(*) > 1
  ),
  'each generated start time is emitted exactly once'
);

with fixture as (
  select therapist.id as therapist_id, room.id as room_id
  from public.therapists therapist
  join public.rooms room on room.outlet_id = therapist.outlet_id
  where coalesce(therapist.is_active, true)
    and coalesce(room.is_active, true)
  order by therapist.created_at, room.created_at
  limit 1
), slots as (
  select slot.*
  from fixture
  cross join lateral public.get_available_slots(
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1,
    fixture.therapist_id,
    fixture.room_id,
    60,
    null
  ) slot
)
select ok(
  not exists (
    select 1
    from slots unavailable
    join slots available using (start_time)
    where unavailable.classification = 'unavailable'
      and available.classification <> 'unavailable'
  ),
  'an unavailable time is never also returned as bookable'
);

with fixture as (
  select therapist.id as therapist_id, room.id as room_id
  from public.therapists therapist
  join public.rooms room on room.outlet_id = therapist.outlet_id
  where coalesce(therapist.is_active, true)
    and coalesce(room.is_active, true)
  order by therapist.created_at, room.created_at
  limit 1
), slots as (
  select slot.*
  from fixture
  cross join lateral public.get_available_slots(
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1,
    fixture.therapist_id,
    fixture.room_id,
    60,
    null
  ) slot
)
select ok(
  not exists (
    select 1 from slots
    where classification not in ('unavailable', 'standard', 'recommended')
  ),
  'slot classifications use the supported contract'
);

with fixture as (
  select therapist.id as therapist_id, room.id as room_id
  from public.therapists therapist
  join public.rooms room on room.outlet_id = therapist.outlet_id
  where coalesce(therapist.is_active, true)
    and coalesce(room.is_active, true)
  order by therapist.created_at, room.created_at
  limit 1
), slots as (
  select slot.*
  from fixture
  cross join lateral public.get_available_slots(
    (now() at time zone 'Asia/Kuala_Lumpur')::date + 1,
    fixture.therapist_id,
    fixture.room_id,
    60,
    null
  ) slot
)
select ok(
  not exists (
    select 1 from slots
    where classification <> 'unavailable' and room_available_slots < 1
  ),
  'every bookable slot reports positive remaining room capacity'
);

select ok(
  lower(pg_get_functiondef(
    'public.get_available_slots(date,uuid,uuid,integer,uuid)'::regprocedure
  )) not like '%or a.room_id = p_room_id%',
  'shared-room bookings do not manufacture therapist gap recommendations'
);

select ok(
  lower(pg_get_functiondef(
    'public.check_booking_availability(date,time without time zone,time without time zone,uuid,uuid,uuid,uuid)'::regprocedure
  )) like '%p_date - 1%',
  'availability validator includes previous-day overnight shifts'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.booking_holds'::regclass
      and tgname = 'booking_holds_notify_event'
      and not tgisinternal
  ),
  'booking-hold notification trigger is installed'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.appointments'::regclass
      and tgname = 'appointments_notify_event'
      and not tgisinternal
  ),
  'appointment notification trigger is installed'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.transactions'::regclass
      and tgname = 'transactions_notify_event'
      and not tgisinternal
  ),
  'transaction notification trigger is installed'
);

select ok(
  has_column_privilege('authenticated', 'public.notifications', 'read_at', 'UPDATE'),
  'authenticated staff may mark notifications read'
);

select ok(
  not has_column_privilege('authenticated', 'public.notifications', 'title', 'UPDATE'),
  'authenticated staff cannot rewrite notification content'
);

select ok(
  exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ),
  'notifications are published to Supabase Realtime'
);

select ok(
  strpos(
    lower(pg_get_functiondef('public.notify_appointment_event()'::regprocedure)),
    'new.payment_status::text = ''voided'''
  ) < strpos(
    lower(pg_get_functiondef('public.notify_appointment_event()'::regprocedure)),
    'new.status::text = ''cancelled'''
  ),
  'void classification is evaluated before cancellation'
);

select ok(
  lower(pg_get_triggerdef(
    (
      select oid from pg_trigger
      where tgrelid = 'public.booking_holds'::regclass
        and tgname = 'booking_holds_notify_event'
        and not tgisinternal
    )
  )) like '%appointment_group_id%',
  'group-link updates can enrich a deduplicated online-booking notification'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'notifications'
      and policyname = 'notifications_staff_admin_select'
  ),
  'notification feed select policy is installed'
);

select * from finish();

rollback;
