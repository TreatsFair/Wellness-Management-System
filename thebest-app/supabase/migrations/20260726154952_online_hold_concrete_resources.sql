-- Ten-minute public payment holds with concrete resource ownership.
--
-- Existing public booking RPCs already choose assigned_therapist_id and
-- assigned_room_id, the numbered-room trigger assigns assigned_room_unit_id,
-- and migration 070 caps the hold at ten minutes. This follow-up makes those
-- invariants explicit and provides one idempotent transaction boundary for
-- each successful Billplz callback.

begin;

-- Appointment add-ons are a separate pricing context. This intentionally does
-- not alter either outlet's existing counter pricing mode.
alter table public.business_settings
  add column if not exists appointment_addon_sst_pricing_mode text
    not null default 'exclusive';

alter table public.business_settings
  drop constraint if exists
    business_settings_appointment_addon_sst_pricing_mode_check;

alter table public.business_settings
  add constraint business_settings_appointment_addon_sst_pricing_mode_check
    check (appointment_addon_sst_pricing_mode in (
      'disabled', 'inclusive', 'exclusive'
    ));

update public.business_settings
set appointment_addon_sst_pricing_mode = 'disabled',
    billplz_sst_pricing_mode = 'inclusive',
    sst_rate_percent = 6.00
where outlet_id = '00000000-0000-0000-0000-000000000128';

update public.business_settings
set appointment_addon_sst_pricing_mode = 'exclusive',
    billplz_sst_pricing_mode = 'inclusive',
    sst_rate_percent = 6.00,
    sst_rounding_mode = 'nearest_10_sen'
where outlet_id = '00000000-0000-0000-0000-000000000002';

create or replace function public.outlet_payment_breakdown(
  p_outlet_id uuid,
  p_display_price numeric,
  p_payment_origin text
)
returns table (
  service_price numeric,
  sst_amount numeric,
  total_amount numeric
)
language plpgsql
stable
set search_path = public
as $function$
declare
  v_settings public.business_settings%rowtype;
  v_price numeric := round(greatest(coalesce(p_display_price, 0), 0), 2);
  v_rate numeric := 0;
  v_mode text := 'exclusive';
  v_origin text := lower(coalesce(p_payment_origin, 'counter'));
begin
  if v_origin not in ('billplz', 'counter', 'appointment_addon') then
    raise exception 'Unsupported payment origin: %', p_payment_origin;
  end if;

  select *
  into v_settings
  from public.business_settings
  where outlet_id = p_outlet_id
  limit 1;

  if not found then
    service_price := v_price;
    sst_amount := 0;
    total_amount := v_price;
    return next;
    return;
  end if;

  v_rate := greatest(coalesce(v_settings.sst_rate_percent, 0), 0) / 100;
  v_mode := case v_origin
    when 'billplz' then v_settings.billplz_sst_pricing_mode
    when 'appointment_addon' then
      v_settings.appointment_addon_sst_pricing_mode
    else v_settings.counter_sst_pricing_mode
  end;

  if v_mode = 'disabled'
     or not coalesce(v_settings.sst_enabled, false)
     or v_rate = 0 then
    service_price := v_price;
    sst_amount := 0;
    total_amount := v_price;
    return next;
    return;
  end if;

  if v_mode = 'inclusive' then
    total_amount := v_price;
    service_price := round(total_amount / (1 + v_rate), 2);
    sst_amount := round(total_amount - service_price, 2);
    return next;
    return;
  end if;

  service_price := v_price;
  total_amount := round(service_price + round(service_price * v_rate, 2), 2);
  if v_settings.sst_rounding_mode = 'nearest_10_sen' then
    total_amount := round(total_amount * 10) / 10;
  elsif v_settings.sst_rounding_mode = 'nearest_5_sen' then
    total_amount := round(total_amount * 20) / 20;
  elsif v_settings.sst_rounding_mode = 'floor_cent' then
    total_amount := floor(total_amount * 100) / 100;
  elsif v_settings.sst_rounding_mode = 'ceil_cent' then
    total_amount := ceil(total_amount * 100) / 100;
  end if;
  sst_amount := round(total_amount - service_price, 2);
  return next;
end;
$function$;

create or replace function public.enforce_online_hold_concrete_resources()
returns trigger
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_created_at timestamptz := coalesce(new.created_at, now());
  v_room_mode text;
begin
  if coalesce(new.hold_kind, '') = 'staff_walkin_draft' then
    return new;
  end if;

  if new.status <> 'pending_payment' then
    return new;
  end if;

  new.expires_at := least(
    coalesce(new.expires_at, v_created_at + interval '10 minutes'),
    v_created_at + interval '10 minutes'
  );

  if new.assigned_therapist_id is null then
    raise exception using errcode = '23514',
      message = 'An online payment hold requires an exact therapist.';
  end if;
  if new.assigned_room_id is null then
    raise exception using errcode = '23514',
      message = 'An online payment hold requires an exact room or shared zone.';
  end if;

  select room.allocation_mode
  into v_room_mode
  from public.rooms room
  where room.id = new.assigned_room_id
    and room.outlet_id = new.outlet_id
    and coalesce(room.is_active, true);

  if not found then
    raise exception using errcode = '23514',
      message = 'The held room is inactive or belongs to another outlet.';
  end if;

  if coalesce(v_room_mode, 'capacity') = 'specific_room'
     and new.assigned_room_unit_id is null then
    new.assigned_room_unit_id := public.allocate_specific_room_unit(
      new.assigned_room_id,
      new.start_at at time zone 'Asia/Kuala_Lumpur',
      (
        new.end_at + make_interval(
          mins => greatest(coalesce(new.buffer_after_minutes, 0), 0)
        )
      ) at time zone 'Asia/Kuala_Lumpur',
      null,
      null,
      new.id
    );
  end if;

  if coalesce(v_room_mode, 'capacity') = 'specific_room'
     and new.assigned_room_unit_id is null then
    raise exception using errcode = '23514',
      message = 'An online body-service hold requires an exact numbered room.';
  end if;

  return new;
end;
$function$;

drop trigger if exists booking_holds_require_concrete_resources
  on public.booking_holds;
create trigger booking_holds_require_concrete_resources
before insert or update of
  status,
  expires_at,
  assigned_therapist_id,
  assigned_room_id,
  assigned_room_unit_id,
  start_at,
  end_at,
  buffer_after_minutes
on public.booking_holds
for each row
execute function public.enforce_online_hold_concrete_resources();

-- Stamp the confirmed appointment with the exact resources from its hold.
-- Conversion is creation only: actual service start remains a later explicit
-- Check In & Start update.
create or replace function public.enforce_online_appointment_conversion()
returns trigger
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_hold public.booking_holds%rowtype;
  v_preference text;
begin
  if new.online_booking_service_id is null then
    return new;
  end if;

  if new.actual_started_at is not null
     or lower(coalesce(new.status::text, '')) = 'in_progress' then
    raise exception using errcode = '23514',
      message = 'Online payment conversion must not start the service.';
  end if;
  if new.therapist_id is null or new.room_id is null then
    raise exception using errcode = '23514',
      message = 'Online payment conversion requires locked resources.';
  end if;

  select hold.*
  into v_hold
  from public.booking_holds hold
  where hold.online_booking_service_id = new.online_booking_service_id
    and hold.assigned_therapist_id = new.therapist_id
    and hold.assigned_room_id = new.room_id
    and hold.start_at = coalesce(
      new.booked_start_at,
      new.start_at at time zone 'Asia/Kuala_Lumpur'
    )
    and hold.status in ('paid', 'confirmed')
  order by hold.updated_at desc nulls last, hold.created_at desc
  limit 1;

  if not found then
    raise exception using errcode = '23514',
      message = 'The confirmed online appointment has no matching paid hold.';
  end if;

  v_preference := lower(coalesce(v_hold.therapist_preference, 'none'));
  new.assignment_source := case
    when v_preference in ('female', 'male') then 'gender_preference'
    else 'queue'
  end;
  new.requested_gender := case
    when v_preference = 'female' then 'Female'
    when v_preference = 'male' then 'Male'
    else null
  end;
  new.requested_therapist_id := null;
  new.room_unit_id := coalesce(
    v_hold.assigned_room_unit_id,
    new.room_unit_id
  );
  new.therapist_assignment_state := 'confirmed';
  new.room_assignment_state := 'confirmed';
  new.resources_confirmed_at := coalesce(
    new.resources_confirmed_at,
    v_hold.confirmed_at,
    now()
  );
  new.resources_confirmed_by := null;
  new.actual_started_at := null;
  new.status := 'confirmed';
  return new;
end;
$function$;

drop trigger if exists online_appointment_conversion_requires_locked_resources
  on public.appointments;
create trigger online_appointment_conversion_requires_locked_resources
before insert on public.appointments
for each row
when (new.online_booking_service_id is not null)
execute function public.enforce_online_appointment_conversion();

-- Billplz callbacks call one RPC. Both underlying functions are already
-- idempotent (confirmed holds return their existing appointment; transaction
-- inserts upsert on appointment/group), and this wrapper makes conversion plus
-- payment recording atomic.
create or replace function public.process_paid_public_booking_hold(
  p_token uuid,
  p_bill_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_hold public.booking_holds%rowtype;
  v_transaction_id uuid;
begin
  select *
  into v_hold
  from public.booking_holds
  where public_token = p_token
  for update;

  if not found then
    raise exception 'Booking reference not found';
  end if;
  if nullif(trim(p_bill_id), '') is null
     or v_hold.billplz_bill_id is distinct from p_bill_id then
    raise exception 'Billplz bill does not match this booking hold';
  end if;
  if v_hold.status = 'confirmed' and v_hold.appointment_id is not null then
    return public.record_online_booking_payment(p_token);
  end if;
  if v_hold.status <> 'pending_payment' or v_hold.expires_at <= now() then
    raise exception 'Paid callback arrived after booking hold expired';
  end if;

  perform public.confirm_public_booking_hold(p_token);
  v_transaction_id := public.record_online_booking_payment(p_token);
  return v_transaction_id;
end;
$function$;

create or replace function public.process_paid_public_booking_group(
  p_token uuid,
  p_bill_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_first public.booking_holds%rowtype;
  v_hold_count integer;
  v_transaction_id uuid;
begin
  perform 1
  from public.booking_holds
  where booking_group_token = p_token
  order by guest_index, id
  for update;

  select count(*)
  into v_hold_count
  from public.booking_holds
  where booking_group_token = p_token;

  if v_hold_count = 0 then
    raise exception 'Booking reference not found';
  end if;
  select *
  into v_first
  from public.booking_holds
  where booking_group_token = p_token
  order by guest_index, id
  limit 1;
  if nullif(trim(p_bill_id), '') is null
     or v_first.billplz_bill_id is distinct from p_bill_id then
    raise exception 'Billplz bill does not match this booking group';
  end if;
  if v_first.appointment_group_id is not null then
    return public.record_online_booking_group_payment(p_token);
  end if;
  if exists (
    select 1
    from public.booking_holds hold
    where hold.booking_group_token = p_token
      and (
        hold.status <> 'pending_payment'
        or hold.expires_at <= now()
      )
  ) then
    raise exception 'Paid callback arrived after booking hold expired';
  end if;

  perform public.confirm_public_booking_group_v1(p_token);
  v_transaction_id := public.record_online_booking_group_payment(p_token);
  return v_transaction_id;
end;
$function$;

revoke all on function public.enforce_online_hold_concrete_resources()
  from public, anon, authenticated;
revoke all on function public.enforce_online_appointment_conversion()
  from public, anon, authenticated;
revoke all on function public.confirm_public_booking_hold(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.confirm_public_booking_group_v1(uuid)
  from public, anon, authenticated, service_role;
drop function if exists public.process_paid_public_booking_hold(uuid);
drop function if exists public.process_paid_public_booking_group(uuid);
revoke all on function public.process_paid_public_booking_hold(uuid, text)
  from public, anon, authenticated;
revoke all on function public.process_paid_public_booking_group(uuid, text)
  from public, anon, authenticated;
grant execute on function public.process_paid_public_booking_hold(uuid, text)
  to service_role;
grant execute on function public.process_paid_public_booking_group(uuid, text)
  to service_role;

commit;
