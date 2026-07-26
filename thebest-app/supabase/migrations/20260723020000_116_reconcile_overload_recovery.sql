-- Recovery hardening for the assignment reconciler deployed by migration 112.
--
-- This migration deliberately stands on production migration 112 only. It
-- does not depend on local migrations 113, 114, or 115. The existing allocator
-- is retained as a private core so its CSP, provisional-capacity, assignment
-- locking, and check-in behaviour remain intact.
--
-- Booking/create RPCs are intentionally not replaced here. Their per-pax
-- concrete therapist_id and room_id holds continue to reserve therapist,
-- gender/request, room/zone, duration, and time-range capacity immediately.
-- The independent assignment states keep those concrete IDs silent/pending
-- until the one near-time assignment pass or atomic check-in confirmation.

alter table public.appointments
  add column if not exists assignment_reconcile_attempt_count integer
    not null default 0,
  add column if not exists assignment_next_retry_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'appointments_assignment_attempt_count_check'
      and conrelid = 'public.appointments'::regclass
  ) then
    alter table public.appointments
      add constraint appointments_assignment_attempt_count_check
      check (assignment_reconcile_attempt_count >= 0);
  end if;
end;
$$;

create index if not exists appointments_assignment_recovery_v116_idx
  on public.appointments (
    appointment_date,
    start_time,
    assignment_next_retry_at
  )
  where actual_started_at is null
    and status in ('pending', 'confirmed')
    and type = 'appointment';

-- Resource/settings triggers enqueue one small invalidation row. Cron expands
-- each invalidation into at most 50 appointment markers per run, avoiding the
-- synchronous future-appointment loops that exhausted production connections.
create table if not exists public.appointment_assignment_invalidations (
  id bigint generated always as identity primary key,
  resource_type text not null check (
    resource_type in ('therapist', 'room', 'service', 'business_hours')
  ),
  resource_id uuid,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  day_of_week integer check (day_of_week between 0 and 6),
  include_following_day boolean not null default false,
  created_at timestamptz not null default now()
);

create unique index if not exists assignment_invalidations_pending_v116_uidx
  on public.appointment_assignment_invalidations (
    resource_type,
    coalesce(resource_id, '00000000-0000-0000-0000-000000000000'::uuid),
    outlet_id,
    coalesce(day_of_week, -1),
    include_following_day
  );

alter table public.appointment_assignment_invalidations enable row level security;
revoke all on table public.appointment_assignment_invalidations
  from public, anon, authenticated;
revoke all on sequence public.appointment_assignment_invalidations_id_seq
  from public, anon, authenticated;

create or replace function public.assignment_reconcile_retry_delay(
  p_attempt_count integer
)
returns interval
language sql
immutable
security invoker
set search_path = public
as $$
  select make_interval(
    mins => case
      when coalesce(p_attempt_count, 0) <= 0 then 5
      when p_attempt_count = 1 then 10
      when p_attempt_count = 2 then 20
      when p_attempt_count = 3 then 40
      else 60
    end
  );
$$;

revoke all on function public.assignment_reconcile_retry_delay(integer)
  from public, anon, authenticated;

-- prevent_appointment_resource_overlap is the exact live production definition,
-- with one change: the per-outlet+day serialization key is taken with a BOUNDED
-- wait instead of an unbounded one. Ordinary writes wait at most 2s for the key,
-- so normal sub-second contention is absorbed transparently, while a
-- pathologically slow holder can never build an unbounded waiter pileup that
-- exhausts the connection pool: after 2s PostgreSQL raises 55P03 and the write
-- fails fast (retryable) instead of hanging. The 2s window is scoped to the lock
-- acquire only and lock_timeout is restored immediately, so it never shortens
-- the rest of the appointment transaction. We never proceed without the lock.
-- While reconciliation is active the enclosing wrapper already holds this exact
-- key for the transaction (it set app.assignment_reconcile_active only after
-- acquiring it), so the nested allocator write skips re-acquiring. All CSP
-- capacity checks are unchanged.
create or replace function public.prevent_appointment_resource_overlap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamp;
  v_block_end timestamp;
  v_room_total integer := 1;
  v_room_conflicts integer := 0;
  v_prev_lock_timeout text;
begin
  if not public.csp_blocks_schedule(new.status::text) then
    return new;
  end if;

  if current_setting('app.allow_late_extension_overlap', true) = 'on' then
    return new;
  end if;

  if current_setting('app.assignment_reconcile_active', true) <> '1' then
    v_prev_lock_timeout := current_setting('lock_timeout');
    perform set_config('lock_timeout', '2s', true);
    begin
      perform pg_advisory_xact_lock(
        hashtextextended(
          coalesce(new.outlet_id::text, '') || ':' || new.appointment_date::text,
          0
        )
      );
    exception when lock_not_available then
      raise exception using
        errcode = '55P03',
        message = 'Another appointment update is in progress. Please try again.';
    end;
    -- Restore immediately so the 2s bound applies only to the lock acquire, not
    -- to the remainder of the appointment transaction.
    perform set_config('lock_timeout', v_prev_lock_timeout, true);
  end if;

  v_start := public.csp_appointment_start_at(new);
  v_block_end := public.csp_appointment_end_at(new)
    + make_interval(mins => greatest(coalesce(new.buffer_after_minutes, 0), 0));

  if new.therapist_id is not null and exists (
    select 1
    from public.appointments existing
    where existing.therapist_id = new.therapist_id
      and existing.id is distinct from new.id
      and public.csp_blocks_schedule(existing.status::text)
      and public.csp_appointment_start_at(existing) < v_block_end
      and public.csp_appointment_block_end_at(existing) > v_start
  ) then
    raise exception using
      errcode = '23P01',
      message = 'Therapist is already booked during this service or cleanup buffer.';
  end if;

  if new.therapist_id is not null and exists (
    select 1
    from public.booking_holds hold
    where hold.assigned_therapist_id = new.therapist_id
      and hold.status = 'pending_payment'
      and hold.expires_at > now()
      and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_block_end
      and ((hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))) at time zone 'Asia/Kuala_Lumpur') > v_start
  ) then
    raise exception using
      errcode = '23P01',
      message = 'Therapist is temporarily reserved by an online booking hold.';
  end if;

  if new.room_id is not null then
    select greatest(coalesce(total_slots, 1), 1)
    into v_room_total
    from public.rooms
    where id = new.room_id;

    select count(*)
    into v_room_conflicts
    from public.appointments existing
    where existing.room_id = new.room_id
      and existing.id is distinct from new.id
      and public.csp_blocks_schedule(existing.status::text)
      and public.csp_appointment_start_at(existing) < v_block_end
      and public.csp_appointment_block_end_at(existing) > v_start;

    v_room_conflicts := v_room_conflicts + (
      select count(*)
      from public.booking_holds hold
      where hold.assigned_room_id = new.room_id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
        and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_block_end
        and ((hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))) at time zone 'Asia/Kuala_Lumpur') > v_start
    );

    if v_room_conflicts >= coalesce(v_room_total, 1) then
      raise exception using
        errcode = '23P01',
        message = 'Room or bed capacity is already full during this service or cleanup buffer.';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.prevent_appointment_resource_overlap()
  from public, anon, authenticated;

-- Migration 112's mature allocator, inlined verbatim as a private core with a
-- single behavioural change: the near-time reassignment branch is restricted to
-- a still-pending therapist assignment. A valid auto-assignment is kept and only
-- confirmed at check-in, never reshuffled merely for entering the 60-minute
-- window; an invalidated assignment (not v_therapist_valid) is still repaired.
-- Everything else is the exact verified live definition, so CSP capacity
-- protection and confirmed/manual/requested preservation are unchanged. It never
-- consumes or reorders the therapist queue (queue turns move only on
-- actual_started_at, via a separate trigger this migration does not touch).
create or replace function public.reconcile_appointment_resources_112_core(
  p_appointment_id uuid,
  p_confirm boolean default false
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_start_local timestamp;
  v_end_local timestamp;
  v_duration integer;
  v_candidate uuid;
  v_room uuid;
  v_check record;
  v_queue record;
  v_scheduled boolean := false;
  v_therapist_valid boolean := false;
  v_room_valid boolean := false;
  v_original_therapist_id uuid;
  v_original_service_items jsonb;
  v_original_therapist_state text;
  v_original_auto_assigned_at timestamptz;
begin
  if auth.uid() is not null and not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments appointment
  where appointment.id = p_appointment_id
  for update;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  if v_appointment.actual_started_at is not null
     or v_appointment.status::text not in ('pending', 'confirmed') then
    return v_appointment;
  end if;

  v_original_therapist_id := v_appointment.therapist_id;
  v_original_service_items := v_appointment.service_items;
  v_original_therapist_state := v_appointment.therapist_assignment_state;
  v_original_auto_assigned_at := v_appointment.therapist_auto_assigned_at;

  v_start_local := public.csp_appointment_start_at(v_appointment);
  v_end_local := public.csp_appointment_end_at(v_appointment);
  v_duration := greatest(
    ceil(extract(epoch from (v_end_local - v_start_local)) / 60.0)::integer,
    1
  );

  select exists (
    select 1
    from public.get_therapist_queue(
      v_appointment.outlet_id,
      v_appointment.appointment_date,
      v_appointment.start_time,
      v_duration
    ) queue
    where queue.therapist_id = v_appointment.therapist_id
  ) into v_scheduled;

  select * into v_check
  from public.check_booking_availability(
    v_appointment.appointment_date,
    v_appointment.start_time,
    v_appointment.end_time,
    v_appointment.therapist_id,
    v_appointment.room_id,
    v_appointment.id
  );
  v_therapist_valid := v_scheduled
    and coalesce(v_check.therapist_available, false);

  if v_appointment.therapist_assignment_state = 'confirmed'
     and not v_therapist_valid then
    update public.appointments
    set assignment_last_attempted_at = now(),
        assignment_error_code = 'CONFIRMED_THERAPIST_UNAVAILABLE',
        assignment_error_message = 'The confirmed therapist is no longer available for the protected time window.',
        updated_at = now()
    where id = p_appointment_id
    returning * into v_appointment;
    if p_confirm then
      raise exception 'The confirmed therapist is unavailable. Staff must switch the therapist before check-in.';
    end if;
    return v_appointment;
  end if;

  if v_appointment.therapist_assignment_state <> 'confirmed'
     and (
       not v_therapist_valid
       or (
         v_appointment.therapist_assignment_state = 'pending'
         and (
           p_confirm
           or v_start_local <= (now() at time zone 'Asia/Kuala_Lumpur')
                                + interval '60 minutes'
         )
       )
     ) then
    -- The queue RPC is used for its shift-aware live order only. Its raw
    -- availability includes this appointment's own hold, so each candidate is
    -- revalidated with p_exclude_appointment_id before selection.
    for v_queue in
      select queue.*
      from public.get_therapist_queue(
        v_appointment.outlet_id,
        v_appointment.appointment_date,
        v_appointment.start_time,
        v_duration
      ) queue
      where v_appointment.requested_gender is null
         or lower(queue.gender) = lower(v_appointment.requested_gender)
      order by queue.rotation_rank
    loop
      select * into v_check
      from public.check_booking_availability(
        v_appointment.appointment_date,
        v_appointment.start_time,
        v_appointment.end_time,
        v_queue.therapist_id,
        v_appointment.room_id,
        v_appointment.id
      );
      if coalesce(v_check.therapist_available, false) then
        v_candidate := v_queue.therapist_id;
        exit;
      end if;
    end loop;

    if v_candidate is null then
      update public.appointments
      set assignment_last_attempted_at = now(),
          assignment_error_code = 'NO_THERAPIST_CAPACITY',
          assignment_error_message = 'No scheduled therapist is available for the protected time window.',
          updated_at = now()
      where id = p_appointment_id
      returning * into v_appointment;
      if p_confirm then
        raise exception 'No scheduled therapist is available for this appointment.';
      end if;
      return v_appointment;
    end if;

    if v_candidate is distinct from v_appointment.therapist_id then
      perform set_config('app.therapist_switch_rpc', '1', true);
      update public.appointments appointment
      set therapist_id = v_candidate,
          service_items = coalesce((
            select jsonb_agg(
              item || jsonb_build_object(
                'assignedTherapistId', v_candidate,
                'assignedTherapistName', therapist.name
              )
            )
            from jsonb_array_elements(
              coalesce(appointment.service_items, '[]'::jsonb)
            ) item
            cross join public.therapists therapist
            where therapist.id = v_candidate
          ), appointment.service_items),
          updated_at = now()
      where appointment.id = p_appointment_id;
    end if;

    update public.appointments
    set therapist_assignment_state = case
          when p_confirm then 'confirmed' else 'auto_assigned'
        end,
        therapist_auto_assigned_at = case
          when p_confirm then therapist_auto_assigned_at else now()
        end,
        assignment_last_attempted_at = now(),
        assignment_error_code = null,
        assignment_error_message = null,
        updated_at = now()
    where id = p_appointment_id
    returning * into v_appointment;
  end if;

  select exists (
    select 1
    from public.rooms room
    join public.services service on service.id = v_appointment.service_id
    where room.id = v_appointment.room_id
      and room.outlet_id = v_appointment.outlet_id
      and coalesce(room.is_active, true)
      and lower(coalesce(room.room_type::text, ''))
          = lower(coalesce(service.room_type::text, ''))
      and (
        select count(*)
        from public.appointments conflict
        where conflict.room_id = room.id
          and conflict.id <> v_appointment.id
          and public.csp_blocks_schedule(conflict.status::text)
          and public.csp_appointment_start_at(conflict)
                < v_end_local + make_interval(
                    mins => greatest(coalesce(v_appointment.buffer_after_minutes, 0), 0)
                  )
          and public.csp_appointment_block_end_at(conflict) > v_start_local
      ) + (
        select count(*)
        from public.booking_holds hold
        where hold.assigned_room_id = room.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur')
                < v_end_local + make_interval(
                    mins => greatest(coalesce(v_appointment.buffer_after_minutes, 0), 0)
                  )
          and (
            hold.end_at + make_interval(
              mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
            )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start_local
      ) < greatest(coalesce(room.total_slots, 1), 1)
  ) into v_room_valid;

  if not v_room_valid then
    if v_appointment.room_assignment_state = 'confirmed' then
      perform set_config('app.therapist_switch_rpc', '1', true);
      update public.appointments
      set therapist_id = v_original_therapist_id,
          service_items = v_original_service_items,
          therapist_assignment_state = v_original_therapist_state,
          therapist_auto_assigned_at = v_original_auto_assigned_at,
          assignment_last_attempted_at = now(),
          assignment_error_code = 'CONFIRMED_ROOM_UNAVAILABLE',
          assignment_error_message = 'The confirmed room is no longer available for the protected time window.',
          updated_at = now()
      where id = p_appointment_id
      returning * into v_appointment;
      if p_confirm then
        raise exception 'The confirmed room is unavailable. Staff must switch the room before check-in.';
      end if;
      return v_appointment;
    end if;

    select room.id into v_room
    from public.rooms room
    join public.services service on service.id = v_appointment.service_id
    where room.outlet_id = v_appointment.outlet_id
      and coalesce(room.is_active, true)
      and lower(coalesce(room.room_type::text, ''))
          = lower(coalesce(service.room_type::text, ''))
      and (
        select count(*)
        from public.appointments conflict
        where conflict.room_id = room.id
          and conflict.id <> v_appointment.id
          and public.csp_blocks_schedule(conflict.status::text)
          and public.csp_appointment_start_at(conflict)
                < v_end_local + make_interval(
                    mins => greatest(coalesce(v_appointment.buffer_after_minutes, 0), 0)
                  )
          and public.csp_appointment_block_end_at(conflict) > v_start_local
      ) + (
        select count(*)
        from public.booking_holds hold
        where hold.assigned_room_id = room.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur')
                < v_end_local + make_interval(
                    mins => greatest(coalesce(v_appointment.buffer_after_minutes, 0), 0)
                  )
          and (
            hold.end_at + make_interval(
              mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
            )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start_local
      ) < greatest(coalesce(room.total_slots, 1), 1)
    order by room.name, room.id
    limit 1;

    if v_room is null then
      perform set_config('app.therapist_switch_rpc', '1', true);
      update public.appointments
      set therapist_id = v_original_therapist_id,
          service_items = v_original_service_items,
          therapist_assignment_state = v_original_therapist_state,
          therapist_auto_assigned_at = v_original_auto_assigned_at,
          assignment_last_attempted_at = now(),
          assignment_error_code = 'NO_ROOM_CAPACITY',
          assignment_error_message = 'No matching room capacity is available for the protected time window.',
          updated_at = now()
      where id = p_appointment_id
      returning * into v_appointment;
      if p_confirm then
        raise exception 'No matching room is available for this appointment.';
      end if;
      return v_appointment;
    end if;

    update public.appointments
    set room_id = v_room,
        room_unit_id = null,
        room_assignment_state = 'auto_assigned',
        assignment_last_attempted_at = now(),
        assignment_error_code = null,
        assignment_error_message = null,
        updated_at = now()
    where id = p_appointment_id
    returning * into v_appointment;
  end if;

  if p_confirm then
    update public.appointments
    set therapist_assignment_state = 'confirmed',
        room_assignment_state = 'confirmed',
        resources_confirmed_at = now(),
        resources_confirmed_by = auth.uid(),
        assignment_last_attempted_at = now(),
        assignment_error_code = null,
        assignment_error_message = null,
        updated_at = now()
    where id = p_appointment_id
    returning * into v_appointment;
  elsif v_appointment.room_assignment_state = 'pending' then
    update public.appointments
    set room_assignment_state = 'auto_assigned',
        assignment_last_attempted_at = now(),
        updated_at = now()
    where id = p_appointment_id
    returning * into v_appointment;
  end if;

  return v_appointment;
end;
$$;

revoke all on function public.reconcile_appointment_resources_112_core(uuid, boolean)
  from public, anon, authenticated, service_role;

-- Guarded public wrapper. A group is one assignment unit: all rows that need
-- work are reconciled inside one exception subtransaction, so a failure rolls
-- every changed pax back before shared retry metadata is recorded.
create or replace function public.reconcile_appointment_resources(
  p_appointment_id uuid,
  p_confirm boolean default false
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.appointments%rowtype;
  v_result public.appointments%rowtype;
  v_member record;
  v_group_id uuid;
  v_unit_key bigint;
  v_day_key bigint;
  v_unit_locked boolean := false;
  v_day_locked boolean := false;
  v_previous_guard text := current_setting(
    'app.assignment_reconcile_active',
    true
  );
  v_previous_lock_timeout text := current_setting('lock_timeout');
  v_previous_statement_timeout text := current_setting('statement_timeout');
  v_failure_code text;
  v_failure_message text;
  v_error_detail text;
  v_failure_sqlstate text;
begin
  if auth.uid() is not null and not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select *
  into v_target
  from public.appointments appointment
  where appointment.id = p_appointment_id;

  if not found then
    raise exception 'Appointment was not found.';
  end if;

  if current_setting('app.assignment_reconcile_active', true) = '1' then
    return v_target;
  end if;

  if v_target.actual_started_at is not null
     or v_target.status::text not in ('pending', 'confirmed') then
    return v_target;
  end if;

  v_group_id := v_target.appointment_group_id;
  v_unit_key := hashtextextended(
    'assignment-unit:' || coalesce(v_group_id, v_target.id)::text,
    0
  );
  v_day_key := hashtextextended(
    coalesce(v_target.outlet_id::text, '')
      || ':' || v_target.appointment_date::text,
    0
  );

  -- Transaction-scoped and non-blocking: both keys auto-release at commit or
  -- rollback, so a pooled backend can never leak an advisory lock. If a key is
  -- held by a competing writer we defer instead of waiting.
  v_unit_locked := pg_try_advisory_xact_lock(v_unit_key);
  if v_unit_locked then
    v_day_locked := pg_try_advisory_xact_lock(v_day_key);
  end if;

  if not v_unit_locked or not v_day_locked then
    -- A partially acquired xact lock needs no manual release; it is bounded to
    -- this transaction and auto-releases at commit/rollback.
    if p_confirm then
      raise exception using
        errcode = '55P03',
        message = 'Appointment resources are being updated. Please retry check-in.';
    end if;

    begin
      update public.appointments appointment
      set assignment_last_attempted_at = now(),
          assignment_error_code = 'RECONCILE_LOCK_BUSY',
          assignment_error_message =
            'Resource assignment is busy and will retry automatically.',
          assignment_reconcile_attempt_count =
            appointment.assignment_reconcile_attempt_count + 1,
          assignment_next_retry_at = now()
            + public.assignment_reconcile_retry_delay(
                appointment.assignment_reconcile_attempt_count
              ),
          updated_at = now()
      where appointment.id = p_appointment_id
      returning * into v_target;
    exception when others then
      null;
    end;
    return v_target;
  end if;

  perform set_config('lock_timeout', '750ms', true);
  perform set_config(
    'statement_timeout',
    case when p_confirm then '12s' else '8s' end,
    true
  );
  perform set_config('app.assignment_reconcile_active', '1', true);

  begin
    for v_member in
      select appointment.id,
             appointment.therapist_assignment_state,
             appointment.room_assignment_state,
             appointment.assignment_error_code
      from public.appointments appointment
      where appointment.actual_started_at is null
        and appointment.status::text in ('pending', 'confirmed')
        and (
          (v_group_id is null and appointment.id = p_appointment_id)
          or appointment.appointment_group_id = v_group_id
        )
      order by appointment.id
      for update
    loop
      if not p_confirm
         and v_member.therapist_assignment_state <> 'pending'
         and v_member.room_assignment_state <> 'pending'
         and v_member.assignment_error_code is null then
        continue;
      end if;

      v_result := public.reconcile_appointment_resources_112_core(
        v_member.id,
        p_confirm
      );

      -- Migration 112 can leave an invalidation marker behind when a locked
      -- therapist is valid and only its pending room needed confirmation.
      if v_result.assignment_error_code in (
           'RESOURCE_CHANGED',
           'BUSINESS_HOURS_CHANGED',
           'RECONCILE_DEFERRED',
           'RECONCILE_LOCK_BUSY',
           'RECONCILE_FAILED'
         )
         and v_result.therapist_assignment_state <> 'pending'
         and v_result.room_assignment_state <> 'pending' then
        update public.appointments appointment
        set assignment_error_code = null,
            assignment_error_message = null,
            updated_at = now()
        where appointment.id = v_member.id
        returning * into v_result;
      end if;

      if v_result.assignment_error_code is not null then
        v_failure_code := v_result.assignment_error_code;
        v_failure_message := v_result.assignment_error_message;
        raise exception using
          errcode = 'P0001',
          message = coalesce(
            v_failure_message,
            'Resource assignment could not be completed.'
          );
      end if;
    end loop;

    update public.appointments appointment
    set assignment_reconcile_attempt_count = 0,
        assignment_next_retry_at = null,
        assignment_error_code = null,
        assignment_error_message = null,
        updated_at = now()
    where appointment.actual_started_at is null
      and appointment.status::text in ('pending', 'confirmed')
      and (
        (v_group_id is null and appointment.id = p_appointment_id)
        or appointment.appointment_group_id = v_group_id
      )
      and appointment.therapist_assignment_state <> 'pending'
      and appointment.room_assignment_state <> 'pending';
  exception when others then
    get stacked diagnostics
      v_error_detail = message_text,
      v_failure_sqlstate = returned_sqlstate;
    perform set_config(
      'app.assignment_reconcile_active',
      coalesce(nullif(v_previous_guard, ''), '0'),
      true
    );
    perform set_config('lock_timeout', v_previous_lock_timeout, true);
    perform set_config(
      'statement_timeout',
      v_previous_statement_timeout,
      true
    );
    -- Advisory locks are transaction scoped; they release automatically.

    if p_confirm then
      raise;
    end if;

    begin
      update public.appointments appointment
      set assignment_last_attempted_at = now(),
          assignment_error_code = coalesce(
            v_failure_code,
            case
              when v_failure_sqlstate = '55P03' then 'RECONCILE_LOCK_BUSY'
              when v_failure_sqlstate = '57014' then 'RECONCILE_TIMEOUT'
              else 'RECONCILE_FAILED'
            end
          ),
          assignment_error_message = left(
            coalesce(v_failure_message, v_error_detail),
            1000
          ),
          assignment_reconcile_attempt_count =
            appointment.assignment_reconcile_attempt_count + 1,
          assignment_next_retry_at = now()
            + public.assignment_reconcile_retry_delay(
                appointment.assignment_reconcile_attempt_count
              ),
          updated_at = now()
      where appointment.actual_started_at is null
        and appointment.status::text in ('pending', 'confirmed')
        and (
          (v_group_id is null and appointment.id = p_appointment_id)
          or appointment.appointment_group_id = v_group_id
        )
        and (
          appointment.therapist_assignment_state = 'pending'
          or appointment.room_assignment_state = 'pending'
          or appointment.assignment_error_code is not null
        );
    exception when others then
      null;
    end;

    select * into v_target
    from public.appointments appointment
    where appointment.id = p_appointment_id;
    return v_target;
  end;

  perform set_config(
    'app.assignment_reconcile_active',
    coalesce(nullif(v_previous_guard, ''), '0'),
    true
  );
  perform set_config('lock_timeout', v_previous_lock_timeout, true);
  perform set_config(
    'statement_timeout',
    v_previous_statement_timeout,
    true
  );
  -- Advisory locks are transaction scoped; they release automatically.

  select * into v_target
  from public.appointments appointment
  where appointment.id = p_appointment_id;
  return v_target;
end;
$$;

revoke all on function public.reconcile_appointment_resources(uuid, boolean)
  from public, anon;
grant execute on function public.reconcile_appointment_resources(uuid, boolean)
  to authenticated, service_role;

-- Immediate, guarded, non-fatal event trigger. It replaces migration 112's
-- deferred constraint trigger so the transaction guard is still active when
-- allocator-owned therapist/room updates fire their nested trigger event.
create or replace function public.request_appointment_assignment_reconcile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if current_setting('app.assignment_reconcile_active', true) = '1' then
    return null;
  end if;

  if tg_op = 'UPDATE'
     and old.appointment_date is not distinct from new.appointment_date
     and old.start_time is not distinct from new.start_time
     and old.end_time is not distinct from new.end_time
     and old.therapist_id is not distinct from new.therapist_id
     and old.room_id is not distinct from new.room_id
     and old.status is not distinct from new.status then
    return null;
  end if;

  if new.type::text = 'appointment'
     and new.actual_started_at is null
     and new.status::text in ('pending', 'confirmed')
     and (
       public.csp_appointment_start_at(new)
         <= (now() at time zone 'Asia/Kuala_Lumpur') + interval '60 minutes'
       or new.assignment_error_code is not null
     ) then
    begin
      perform public.reconcile_appointment_resources(new.id, false);
    exception when others then
      -- An ordinary staff write is already valid at this boundary. Assignment
      -- recovery is best-effort and must not roll that write back.
      null;
    end;
  end if;
  return null;
end;
$$;

drop trigger if exists appointments_request_assignment_reconcile
  on public.appointments;
create trigger appointments_request_assignment_reconcile
after insert or update of
  appointment_date,
  start_time,
  end_time,
  therapist_id,
  room_id,
  status
on public.appointments
for each row execute function public.request_appointment_assignment_reconcile();

revoke all on function public.request_appointment_assignment_reconcile()
  from public, anon, authenticated;

-- Resource changes only enqueue invalidation metadata. No appointment scan or
-- allocator call occurs in the staff/settings transaction.
create or replace function public.enqueue_appointment_assignment_invalidation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_new jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_resource_type text;
  v_resource_id uuid;
  v_outlet_id uuid;
  v_day_of_week integer;
begin
  if tg_op = 'UPDATE' and v_old is not distinct from v_new then
    return new;
  end if;

  if tg_table_name = 'therapist_working_hours'
     and current_setting('app.business_hours_sync', true) = '1' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_table_name = 'therapists' then
    v_resource_type := 'therapist';
    v_resource_id := nullif(v_row ->> 'id', '')::uuid;
    v_outlet_id := nullif(v_row ->> 'outlet_id', '')::uuid;
  elsif tg_table_name in (
    'therapist_working_hours',
    'therapist_unavailability'
  ) then
    v_resource_type := 'therapist';
    v_resource_id := nullif(v_row ->> 'therapist_id', '')::uuid;
    v_outlet_id := nullif(v_row ->> 'outlet_id', '')::uuid;
    v_day_of_week := nullif(v_row ->> 'day_of_week', '')::integer;
  elsif tg_table_name = 'rooms' then
    v_resource_type := 'room';
    v_resource_id := nullif(v_row ->> 'id', '')::uuid;
    v_outlet_id := nullif(v_row ->> 'outlet_id', '')::uuid;
  elsif tg_table_name = 'services' then
    v_resource_type := 'service';
    v_resource_id := nullif(v_row ->> 'id', '')::uuid;
    v_outlet_id := nullif(v_row ->> 'outlet_id', '')::uuid;
  end if;

  if v_outlet_id is null and v_resource_type = 'therapist' then
    select therapist.outlet_id
    into v_outlet_id
    from public.therapists therapist
    where therapist.id = v_resource_id;
  end if;

  if v_resource_type is not null
     and v_resource_id is not null
     and v_outlet_id is not null then
    insert into public.appointment_assignment_invalidations (
      resource_type,
      resource_id,
      outlet_id,
      day_of_week
    ) values (
      v_resource_type,
      v_resource_id,
      v_outlet_id,
      v_day_of_week
    ) on conflict do nothing;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.enqueue_appointment_assignment_invalidation()
  from public, anon, authenticated;

drop trigger if exists therapists_reconcile_appointment_holds
  on public.therapists;
create trigger therapists_reconcile_appointment_holds
after update of availability_status, outlet_id, role
on public.therapists
for each row
when (
  old.availability_status is distinct from new.availability_status
  or old.outlet_id is distinct from new.outlet_id
  or old.role is distinct from new.role
)
execute function public.enqueue_appointment_assignment_invalidation();

drop trigger if exists therapist_hours_reconcile_appointment_holds
  on public.therapist_working_hours;
create trigger therapist_hours_reconcile_appointment_holds
after insert or update or delete
on public.therapist_working_hours
for each row execute function public.enqueue_appointment_assignment_invalidation();

drop trigger if exists therapist_unavailability_reconcile_appointment_holds
  on public.therapist_unavailability;
create trigger therapist_unavailability_reconcile_appointment_holds
after insert or update or delete
on public.therapist_unavailability
for each row execute function public.enqueue_appointment_assignment_invalidation();

drop trigger if exists rooms_reconcile_appointment_holds
  on public.rooms;
create trigger rooms_reconcile_appointment_holds
after update of is_active, room_type, total_slots, outlet_id
on public.rooms
for each row
when (
  old.is_active is distinct from new.is_active
  or old.room_type is distinct from new.room_type
  or old.total_slots is distinct from new.total_slots
  or old.outlet_id is distinct from new.outlet_id
)
execute function public.enqueue_appointment_assignment_invalidation();

drop trigger if exists services_reconcile_appointment_holds
  on public.services;
create trigger services_reconcile_appointment_holds
after update of room_type, duration, buffer_after_minutes
on public.services
for each row
when (
  old.room_type is distinct from new.room_type
  or old.duration is distinct from new.duration
  or old.buffer_after_minutes is distinct from new.buffer_after_minutes
)
execute function public.enqueue_appointment_assignment_invalidation();

drop function if exists public.reconcile_appointments_for_resource_change();

-- Suppress per-therapist invalidations during inherited business-hours
-- propagation, then enqueue one outlet/day invalidation after the batch.
create or replace function public.begin_business_hours_staff_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.business_hours_sync', '1', true);
  return new;
end;
$$;

create or replace function public.queue_business_hours_assignment_reconcile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_include_following_day boolean := new.close_time <= new.open_time;
begin
  if tg_op = 'UPDATE' then
    v_include_following_day := v_include_following_day
      or old.close_time <= old.open_time;
  end if;

  insert into public.appointment_assignment_invalidations (
    resource_type,
    outlet_id,
    day_of_week,
    include_following_day
  ) values (
    'business_hours',
    new.outlet_id,
    new.day_of_week,
    v_include_following_day
  ) on conflict do nothing;
  return new;
end;
$$;

revoke all on function public.begin_business_hours_staff_sync()
  from public, anon, authenticated;
revoke all on function public.queue_business_hours_assignment_reconcile()
  from public, anon, authenticated;

drop trigger if exists business_hours_sync_staff on public.business_hours;
drop trigger if exists business_hours_sync_staff_insert on public.business_hours;
drop trigger if exists business_hours_sync_staff_update on public.business_hours;
drop trigger if exists business_hours_begin_staff_sync_insert on public.business_hours;
drop trigger if exists business_hours_begin_staff_sync_update on public.business_hours;
drop trigger if exists business_hours_queue_reconcile_insert on public.business_hours;
drop trigger if exists business_hours_queue_reconcile_update on public.business_hours;

create trigger business_hours_begin_staff_sync_insert
before insert on public.business_hours
for each row execute function public.begin_business_hours_staff_sync();

create trigger business_hours_begin_staff_sync_update
before update of open_time, close_time, is_closed on public.business_hours
for each row
when (
  old.open_time is distinct from new.open_time
  or old.close_time is distinct from new.close_time
  or old.is_closed is distinct from new.is_closed
)
execute function public.begin_business_hours_staff_sync();

create trigger business_hours_sync_staff_insert
after insert on public.business_hours
for each row execute function public.sync_staff_hours_from_business_hours();

create trigger business_hours_sync_staff_update
after update of open_time, close_time, is_closed on public.business_hours
for each row
when (
  old.open_time is distinct from new.open_time
  or old.close_time is distinct from new.close_time
  or old.is_closed is distinct from new.is_closed
)
execute function public.sync_staff_hours_from_business_hours();

create trigger business_hours_queue_reconcile_insert
after insert on public.business_hours
for each row execute function public.queue_business_hours_assignment_reconcile();

create trigger business_hours_queue_reconcile_update
after update of open_time, close_time, is_closed on public.business_hours
for each row
when (
  old.open_time is distinct from new.open_time
  or old.close_time is distinct from new.close_time
  or old.is_closed is distinct from new.is_closed
)
execute function public.queue_business_hours_assignment_reconcile();

-- Safe recovery worker. The global try-lock prevents overlap. Invalidation and
-- assignment work are capped; row claims use SKIP LOCKED; error retries honor
-- exponential backoff and never select appointments outside the 60-minute
-- horizon.
create or replace function public.reconcile_upcoming_appointment_assignments()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invalidation record;
  v_work record;
  v_marked integer;
  v_count integer := 0;
begin
  if not pg_try_advisory_xact_lock(
    hashtextextended('assignment-reconcile-cron-v116', 0)
  ) then
    return 0;
  end if;

  perform set_config('lock_timeout', '750ms', true);
  perform set_config('statement_timeout', '25s', true);

  for v_invalidation in
    select invalidation.*
    from public.appointment_assignment_invalidations invalidation
    order by invalidation.created_at, invalidation.id
    for update skip locked
    limit 4
  loop
    with affected as (
      select appointment.id
      from public.appointments appointment
      where appointment.outlet_id = v_invalidation.outlet_id
        and appointment.actual_started_at is null
        and appointment.status::text in ('pending', 'confirmed')
        and appointment.type::text = 'appointment'
        and public.csp_appointment_start_at(appointment)
              >= (now() at time zone 'Asia/Kuala_Lumpur')
        and case v_invalidation.resource_type
          when 'therapist' then
            appointment.therapist_id = v_invalidation.resource_id
            and (
              v_invalidation.day_of_week is null
              or extract(dow from appointment.appointment_date)::integer
                    = v_invalidation.day_of_week
            )
          when 'room' then appointment.room_id = v_invalidation.resource_id
          when 'service' then appointment.service_id = v_invalidation.resource_id
          when 'business_hours' then
            extract(dow from appointment.appointment_date)::integer
              = v_invalidation.day_of_week
            or (
              v_invalidation.include_following_day
              and extract(dow from appointment.appointment_date)::integer
                    = ((v_invalidation.day_of_week + 1) % 7)
            )
          else false
        end
      order by appointment.appointment_date, appointment.start_time, appointment.id
      for update skip locked
      limit 50
    )
    update public.appointments appointment
    set assignment_error_code = case
          when v_invalidation.resource_type = 'business_hours'
            then 'BUSINESS_HOURS_CHANGED'
          else 'RESOURCE_CHANGED'
        end,
        assignment_error_message = case
          when v_invalidation.resource_type = 'business_hours'
            then 'Outlet hours changed; protected resources will be revalidated.'
          else 'Resource configuration changed; protected resources will be revalidated.'
        end,
        assignment_reconcile_attempt_count = 0,
        assignment_next_retry_at = null,
        assignment_last_attempted_at = null,
        updated_at = now()
    from affected
    where appointment.id = affected.id;

    get diagnostics v_marked = row_count;
    if v_marked < 50 then
      delete from public.appointment_assignment_invalidations
      where id = v_invalidation.id;
    end if;
  end loop;

  for v_work in
    with eligible as (
      select
        appointment.id,
        row_number() over (
          partition by coalesce(
            appointment.appointment_group_id::text,
            appointment.id::text
          )
          order by appointment.id
        ) as unit_row
      from public.appointments appointment
      where appointment.actual_started_at is null
        and appointment.status::text in ('pending', 'confirmed')
        and appointment.type::text = 'appointment'
        and public.csp_appointment_start_at(appointment)
              between (now() at time zone 'Asia/Kuala_Lumpur')
                  and (now() at time zone 'Asia/Kuala_Lumpur')
                      + interval '60 minutes'
        and (
          appointment.therapist_assignment_state = 'pending'
          or appointment.room_assignment_state = 'pending'
          or appointment.assignment_error_code is not null
        )
        and not (
          appointment.therapist_assignment_state = 'confirmed'
          and appointment.room_assignment_state = 'confirmed'
        )
        and (
          appointment.assignment_next_retry_at is null
          or appointment.assignment_next_retry_at <= now()
        )
    )
    select appointment.id
    from eligible
    join public.appointments appointment on appointment.id = eligible.id
    where eligible.unit_row = 1
    order by appointment.appointment_date, appointment.start_time, appointment.id
    for update of appointment skip locked
    limit 6
  loop
    perform public.reconcile_appointment_resources(v_work.id, false);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.reconcile_upcoming_appointment_assignments()
  from public, anon, authenticated;
grant execute on function public.reconcile_upcoming_appointment_assignments()
  to service_role;

-- Configure the safer cadence but intentionally leave the job disabled. It is
-- enabled only after post-deployment single/group and lock verification.
create extension if not exists pg_cron with schema pg_catalog;

do $$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname = 'reconcile-upcoming-appointment-assignments'
  limit 1;

  if v_job_id is null then
    v_job_id := cron.schedule(
      'reconcile-upcoming-appointment-assignments',
      '*/5 * * * *',
      'select public.reconcile_upcoming_appointment_assignments();'
    );
  end if;

  perform cron.alter_job(
    v_job_id,
    schedule := '*/5 * * * *',
    command := 'select public.reconcile_upcoming_appointment_assignments();',
    active := false
  );
end;
$$;

comment on function public.reconcile_appointment_resources(uuid, boolean) is
  'Guarded assignment-unit wrapper around the migration-112 allocator; never consumes queue turns.';
comment on function public.reconcile_upcoming_appointment_assignments() is
  'Non-overlapping capped 60-minute recovery worker with invalidation batching and retry backoff.';
comment on table public.appointment_assignment_invalidations is
  'Small asynchronous invalidation queue populated by resource and business-hours triggers.';
