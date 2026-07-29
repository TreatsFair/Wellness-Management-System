-- Race-safe ten-minute booking holds and retryable Billplz cancellation.
--
-- Resource availability remains governed only by expires_at. The two cleanup
-- jobs below improve row hygiene and invalidate abandoned external bills; they
-- never decide whether a therapist, room, or room unit is available.

begin;

alter table public.booking_holds
  alter column expires_at set default (now() + interval '10 minutes'),
  add column if not exists billplz_cancelled_at timestamptz,
  add column if not exists billplz_cancellation_attempts integer
    not null default 0,
  add column if not exists billplz_cancellation_last_attempt_at timestamptz,
  add column if not exists billplz_cancellation_last_error text,
  add column if not exists billplz_cancellation_claim_token uuid,
  add column if not exists billplz_cancellation_claimed_at timestamptz;

alter table public.booking_holds
  drop constraint if exists booking_holds_billplz_cancellation_attempts_check;
alter table public.booking_holds
  add constraint booking_holds_billplz_cancellation_attempts_check
    check (billplz_cancellation_attempts >= 0);

create index if not exists booking_holds_billplz_cleanup_idx
  on public.booking_holds (
    status,
    expires_at,
    billplz_cancellation_claimed_at
  )
  where billplz_bill_id is not null
    and billplz_cancelled_at is null;

comment on column public.booking_holds.billplz_cancelled_at is
  'When the unpaid external Billplz bill was successfully deleted.';
comment on column public.booking_holds.billplz_cancellation_last_error is
  'Last Billplz deletion failure; retained until a later retry succeeds.';

-- The live create RPC still contains a historical 15-minute literal on some
-- environments. Patch only that literal in its current definition so this
-- migration preserves later availability fixes already present there.
do $migration$
declare
  v_function regprocedure := to_regprocedure(
    'public.create_public_booking_hold_v2('
    'uuid,timestamp with time zone,text,text,text,text,text,text,text)'
  );
  v_definition text;
begin
  if v_function is null then
    raise exception 'create_public_booking_hold_v2 is missing';
  end if;

  select pg_get_functiondef(v_function) into v_definition;
  v_definition := replace(
    v_definition,
    'interval ''15 minutes''',
    'interval ''10 minutes'''
  );
  execute v_definition;

  select pg_get_functiondef(v_function) into v_definition;
  if v_definition not ilike '%interval ''10 minutes''%'
     or v_definition ilike '%interval ''15 minutes''%' then
    raise exception 'Unable to standardise create_public_booking_hold_v2';
  end if;
end
$migration$;

-- Status relabelling is atomic and intentionally independent of bill cleanup.
create or replace function public.expire_stale_booking_holds()
returns integer
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
begin
  update public.booking_holds
  set status = 'expired',
      updated_at = now()
  where status = 'pending_payment'
    and expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

-- Direct group confirmation keeps its own expiry boundary even though execute
-- remains revoked from anon, authenticated, and service_role. The idempotent
-- already-confirmed return stays before the clock check.
create or replace function public.confirm_public_booking_group_v1(p_token uuid)
returns table (
  appointment_group_id uuid,
  appointment_ids uuid[],
  status text,
  start_at timestamptz,
  end_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_group_id uuid;
  v_hold record;
  v_confirmed record;
  v_ids uuid[] := '{}'::uuid[];
  v_first public.booking_holds%rowtype;
  v_count integer;
begin
  select *
  into v_first
  from public.booking_holds
  where booking_group_token = p_token
  order by guest_index
  limit 1
  for update;

  if not found then
    raise exception 'Booking reference not found';
  end if;

  if v_first.appointment_group_id is not null then
    select
      array_agg(hold.appointment_id order by hold.guest_index),
      min(hold.start_at),
      max(hold.end_at)
    into v_ids, start_at, end_at
    from public.booking_holds hold
    where hold.booking_group_token = p_token;
    appointment_group_id := v_first.appointment_group_id;
    appointment_ids := v_ids;
    status := 'confirmed';
    return next;
    return;
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
    raise exception 'Booking hold expired';
  end if;

  for v_hold in
    select *
    from public.booking_holds
    where booking_group_token = p_token
    order by guest_index
    for update
  loop
    select *
    into v_confirmed
    from public.confirm_public_booking_hold(v_hold.public_token);
    v_ids := array_append(v_ids, v_confirmed.appointment_id);
  end loop;

  select *
  into v_first
  from public.booking_holds
  where booking_group_token = p_token
  order by guest_index
  limit 1;

  v_count := cardinality(v_ids);
  insert into public.appointment_groups (
    outlet_id,
    customer_id,
    group_name,
    pax_count,
    appointment_date,
    status,
    notes
  ) values (
    v_first.outlet_id,
    v_first.customer_id,
    coalesce(nullif(v_first.customer_name, ''), 'Online') || ' group',
    v_count,
    (v_first.start_at at time zone 'Asia/Kuala_Lumpur')::date,
    'confirmed',
    v_first.notes
  )
  returning id into v_group_id;

  update public.appointments
  set appointment_group_id = v_group_id,
      updated_at = now()
  where id = any(v_ids);

  update public.booking_holds
  set appointment_group_id = v_group_id,
      updated_at = now()
  where booking_group_token = p_token;

  appointment_group_id := v_group_id;
  appointment_ids := v_ids;
  status := 'confirmed';
  select min(hold.start_at), max(hold.end_at)
  into start_at, end_at
  from public.booking_holds hold
  where hold.booking_group_token = p_token;
  return next;
end;
$function$;

-- A customer cancellation or deadline expiry is claimed in the database
-- before Billplz is called. Whichever transaction wins the row lock--payment
-- callback or closure--defines the outcome; a stale Edge read cannot overwrite
-- a confirmed booking.
create or replace function public.claim_booking_bill_cancellation(
  p_token uuid,
  p_target_status text
)
returns table (
  hold_id uuid,
  bill_id text,
  cancellation_claim_token uuid,
  claim_acquired boolean,
  already_cancelled boolean,
  resulting_status text
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_target text := lower(coalesce(p_target_status, ''));
  v_is_group boolean;
  v_bill_hold public.booking_holds%rowtype;
  v_status text;
  v_claim uuid;
begin
  if v_target not in ('cancelled', 'expired') then
    raise exception 'Invalid booking-hold closure status';
  end if;

  select exists (
    select 1
    from public.booking_holds
    where booking_group_token = p_token
  ) into v_is_group;

  perform 1
  from public.booking_holds hold
  where (
    v_is_group
    and hold.booking_group_token = p_token
  ) or (
    not v_is_group
    and hold.public_token = p_token
  )
  order by hold.guest_index nulls first, hold.id
  for update;

  if not found then
    raise exception 'Booking reference not found';
  end if;

  if exists (
    select 1
    from public.booking_holds hold
    where (
      (
        v_is_group
        and hold.booking_group_token = p_token
      ) or (
        not v_is_group
        and hold.public_token = p_token
      )
    )
    and (
      hold.status in ('confirmed', 'paid')
      or hold.appointment_id is not null
      or hold.appointment_group_id is not null
    )
  ) then
    raise exception 'A paid booking cannot be cancelled';
  end if;

  if v_target = 'expired' and exists (
    select 1
    from public.booking_holds hold
    where (
      (
        v_is_group
        and hold.booking_group_token = p_token
      ) or (
        not v_is_group
        and hold.public_token = p_token
      )
    )
    and hold.status = 'pending_payment'
    and hold.expires_at > now()
  ) then
    raise exception 'This booking hold has not expired';
  end if;

  update public.booking_holds hold
  set status = v_target,
      expires_at = case
        when v_target = 'cancelled' then least(hold.expires_at, now())
        else hold.expires_at
      end,
      updated_at = now()
  where (
    (
      v_is_group
      and hold.booking_group_token = p_token
    ) or (
      not v_is_group
      and hold.public_token = p_token
    )
  )
  and hold.status = 'pending_payment'
  and (
    v_target = 'cancelled'
    or hold.expires_at <= now()
  );

  select hold.*
  into v_bill_hold
  from public.booking_holds hold
  where (
    (
      v_is_group
      and hold.booking_group_token = p_token
    ) or (
      not v_is_group
      and hold.public_token = p_token
    )
  )
  and hold.billplz_bill_id is not null
  order by hold.guest_index nulls first, hold.id
  limit 1;

  select hold.status
  into v_status
  from public.booking_holds hold
  where (
    v_is_group
    and hold.booking_group_token = p_token
  ) or (
    not v_is_group
    and hold.public_token = p_token
  )
  order by hold.guest_index nulls first, hold.id
  limit 1;

  if v_status not in ('expired', 'cancelled') then
    raise exception 'This booking hold can no longer be cancelled';
  end if;

  if v_bill_hold.billplz_bill_id is null then
    hold_id := null;
    bill_id := null;
    cancellation_claim_token := null;
    claim_acquired := false;
    already_cancelled := false;
    resulting_status := v_status;
    return next;
    return;
  end if;

  if v_bill_hold.billplz_cancelled_at is not null then
    hold_id := v_bill_hold.id;
    bill_id := v_bill_hold.billplz_bill_id;
    cancellation_claim_token := null;
    claim_acquired := false;
    already_cancelled := true;
    resulting_status := v_status;
    return next;
    return;
  end if;

  v_claim := gen_random_uuid();
  update public.booking_holds hold
  set billplz_cancellation_claim_token = v_claim,
      billplz_cancellation_claimed_at = now(),
      billplz_cancellation_attempts =
        hold.billplz_cancellation_attempts + 1,
      billplz_cancellation_last_attempt_at = now(),
      billplz_cancellation_last_error = null,
      updated_at = now()
  where hold.id = v_bill_hold.id
    and hold.billplz_cancelled_at is null
    and (
      hold.billplz_cancellation_claimed_at is null
      or hold.billplz_cancellation_claimed_at
           <= now() - interval '5 minutes'
    );

  hold_id := v_bill_hold.id;
  bill_id := v_bill_hold.billplz_bill_id;
  cancellation_claim_token := v_claim;
  claim_acquired := found;
  already_cancelled := false;
  resulting_status := v_status;
  return next;
end;
$function$;

-- Batch claims are retryable and only process clock-expired holds. A
-- customer-cancelled hold is retried only by a repeated customer cancellation,
-- not by this periodic expiry worker.
create or replace function public.claim_expired_billplz_cancellations(
  p_limit integer default 100
)
returns table (
  hold_id uuid,
  bill_id text,
  cancellation_claim_token uuid
)
language plpgsql
security definer
set search_path = public
as $function$
begin
  perform public.expire_stale_booking_holds();

  return query
  with candidates as (
    select hold.id
    from public.booking_holds hold
    where hold.billplz_bill_id is not null
      and hold.billplz_cancelled_at is null
      and hold.status = 'expired'
      and hold.appointment_id is null
      and hold.appointment_group_id is null
      and (
        hold.billplz_cancellation_claimed_at is null
        or hold.billplz_cancellation_claimed_at
             <= now() - interval '5 minutes'
      )
    order by hold.expires_at, hold.id
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 100), 500))
  )
  update public.booking_holds hold
  set billplz_cancellation_claim_token = gen_random_uuid(),
      billplz_cancellation_claimed_at = now(),
      billplz_cancellation_attempts =
        hold.billplz_cancellation_attempts + 1,
      billplz_cancellation_last_attempt_at = now(),
      billplz_cancellation_last_error = null,
      updated_at = now()
  from candidates
  where hold.id = candidates.id
  returning
    hold.id,
    hold.billplz_bill_id,
    hold.billplz_cancellation_claim_token;
end;
$function$;

create or replace function public.complete_billplz_cancellation(
  p_hold_id uuid,
  p_claim_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_updated integer;
begin
  update public.booking_holds
  set billplz_cancelled_at = now(),
      billplz_cancellation_claim_token = null,
      billplz_cancellation_claimed_at = null,
      billplz_cancellation_last_error = null,
      updated_at = now()
  where id = p_hold_id
    and billplz_cancellation_claim_token = p_claim_token
    and billplz_cancelled_at is null
    and status in ('expired', 'cancelled');
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$function$;

create or replace function public.fail_billplz_cancellation(
  p_hold_id uuid,
  p_claim_token uuid,
  p_error text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_updated integer;
begin
  update public.booking_holds
  set billplz_cancellation_claim_token = null,
      billplz_cancellation_claimed_at = null,
      billplz_cancellation_last_error =
        left(coalesce(nullif(trim(p_error), ''), 'Unknown Billplz error'), 2000),
      updated_at = now()
  where id = p_hold_id
    and billplz_cancellation_claim_token = p_claim_token
    and billplz_cancelled_at is null
    and status in ('expired', 'cancelled');
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$function$;

revoke all on function public.expire_stale_booking_holds()
  from public, anon, authenticated;
revoke all on function public.confirm_public_booking_group_v1(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.claim_booking_bill_cancellation(uuid, text)
  from public, anon, authenticated;
revoke all on function public.claim_expired_billplz_cancellations(integer)
  from public, anon, authenticated;
revoke all on function public.complete_billplz_cancellation(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.fail_billplz_cancellation(uuid, uuid, text)
  from public, anon, authenticated;

grant execute on function public.expire_stale_booking_holds()
  to service_role;
grant execute on function public.claim_booking_bill_cancellation(uuid, text)
  to service_role;
grant execute on function public.claim_expired_billplz_cancellations(integer)
  to service_role;
grant execute on function public.complete_billplz_cancellation(uuid, uuid)
  to service_role;
grant execute on function public.fail_billplz_cancellation(uuid, uuid, text)
  to service_role;

-- Database bookkeeping every ten minutes. This exact job name is the only job
-- replaced; the appointment-reconciliation Cron is deliberately untouched.
create extension if not exists pg_cron with schema pg_catalog;

do $cron$
declare
  v_job_id bigint;
begin
  select jobid
  into v_job_id
  from cron.job
  where jobname = 'expire-stale-booking-holds'
  limit 1;

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  perform cron.schedule(
    'expire-stale-booking-holds',
    '*/10 * * * *',
    'select public.expire_stale_booking_holds();'
  );
end
$cron$;

commit;
