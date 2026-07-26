-- Independent therapist and room assignment lifecycle for appointments.
-- Concrete resource IDs remain populated so existing CSP constraints continue
-- to protect capacity. These state columns, not is_provisional, control what
-- may be automatically changed and what the counter UI may reveal.

alter table public.appointments
  add column if not exists therapist_assignment_state text,
  add column if not exists room_assignment_state text,
  add column if not exists therapist_auto_assigned_at timestamptz,
  add column if not exists resources_confirmed_at timestamptz,
  add column if not exists resources_confirmed_by uuid references auth.users(id),
  add column if not exists assignment_last_attempted_at timestamptz,
  add column if not exists assignment_error_code text,
  add column if not exists assignment_error_message text;

update public.appointments
set therapist_assignment_state = case
      when actual_started_at is not null
        or status::text in ('in_progress', 'completed')
        or type::text = 'walkin'
        or assignment_source in ('specific_customer_request', 'manual_override')
        then 'confirmed'
      when coalesce(is_provisional, false)
        and public.csp_appointment_start_at(appointments)
              <= (now() at time zone 'Asia/Kuala_Lumpur') + interval '60 minutes'
        then 'auto_assigned'
      when coalesce(is_provisional, false) then 'pending'
      else 'confirmed'
    end,
    room_assignment_state = case
      when actual_started_at is not null
        or status::text in ('in_progress', 'completed')
        or type::text = 'walkin'
        then 'confirmed'
      when coalesce(is_provisional, false) then 'pending'
      else 'confirmed'
    end,
    therapist_auto_assigned_at = case
      when coalesce(is_provisional, false)
        and public.csp_appointment_start_at(appointments)
              <= (now() at time zone 'Asia/Kuala_Lumpur') + interval '60 minutes'
        then coalesce(updated_at, created_at, now())
      else therapist_auto_assigned_at
    end,
    resources_confirmed_at = case
      when actual_started_at is not null
        or status::text in ('in_progress', 'completed')
        or type::text = 'walkin'
        then coalesce(actual_started_at, updated_at, created_at, now())
      else resources_confirmed_at
    end
where therapist_assignment_state is null
   or room_assignment_state is null;

alter table public.appointments
  alter column therapist_assignment_state set default 'pending',
  alter column therapist_assignment_state set not null,
  alter column room_assignment_state set default 'pending',
  alter column room_assignment_state set not null;

alter table public.appointments
  drop constraint if exists appointments_therapist_assignment_state_check,
  add constraint appointments_therapist_assignment_state_check
    check (therapist_assignment_state in ('pending', 'auto_assigned', 'confirmed')),
  drop constraint if exists appointments_room_assignment_state_check,
  add constraint appointments_room_assignment_state_check
    check (room_assignment_state in ('pending', 'auto_assigned', 'confirmed'));

create index if not exists appointments_assignment_reconcile_idx
  on public.appointments (
    outlet_id,
    appointment_date,
    therapist_assignment_state,
    room_assignment_state
  )
  where status in ('pending', 'confirmed')
    and actual_started_at is null;

create or replace function public.normalize_appointment_assignment_states()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.therapist_assignment_state := coalesce(
    nullif(new.therapist_assignment_state, ''),
    'pending'
  );
  new.room_assignment_state := coalesce(
    nullif(new.room_assignment_state, ''),
    'pending'
  );

  if new.actual_started_at is not null
     or new.status::text in ('in_progress', 'completed')
     or new.type::text = 'walkin' then
    new.therapist_assignment_state := 'confirmed';
    new.room_assignment_state := 'confirmed';
    new.resources_confirmed_at := coalesce(
      new.resources_confirmed_at,
      new.actual_started_at,
      now()
    );
    new.resources_confirmed_by := coalesce(new.resources_confirmed_by, auth.uid());
  elsif new.assignment_source in (
    'specific_customer_request',
    'manual_override'
  ) then
    -- An explicit therapist is locked immediately. The room remains a silent
    -- capacity hold until check-in unless staff confirms it separately.
    new.therapist_assignment_state := 'confirmed';
  end if;

  if new.therapist_assignment_state = 'auto_assigned' then
    new.therapist_auto_assigned_at := coalesce(
      new.therapist_auto_assigned_at,
      now()
    );
  end if;

  if new.therapist_assignment_state = 'confirmed'
     and new.room_assignment_state = 'confirmed' then
    new.resources_confirmed_at := coalesce(new.resources_confirmed_at, now());
  end if;

  -- Compatibility only. New code must read the independent state columns.
  new.is_provisional := not (
    new.therapist_assignment_state = 'confirmed'
    and new.room_assignment_state = 'confirmed'
  );
  return new;
end;
$$;

drop trigger if exists appointments_normalize_assignment_states
  on public.appointments;
create trigger appointments_normalize_assignment_states
before insert or update of
  therapist_id,
  room_id,
  assignment_source,
  therapist_assignment_state,
  room_assignment_state,
  actual_started_at,
  status,
  type
on public.appointments
for each row execute function public.normalize_appointment_assignment_states();

revoke all on function public.normalize_appointment_assignment_states()
  from public, anon, authenticated;

-- Reconcile one appointment without consuming the therapist queue. A pending
-- therapist is reconsidered against the live queue only inside the 60-minute
-- horizon, or immediately when its concrete reservation has become invalid.
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
       or p_confirm
       or v_start_local <= (now() at time zone 'Asia/Kuala_Lumpur')
                            + interval '60 minutes'
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

revoke all on function public.reconcile_appointment_resources(uuid, boolean)
  from public, anon;
grant execute on function public.reconcile_appointment_resources(uuid, boolean)
  to authenticated, service_role;

create or replace function public.reconcile_upcoming_appointment_assignments()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_count integer := 0;
begin
  for v_row in
    select appointment.id
    from public.appointments appointment
    where appointment.actual_started_at is null
      and appointment.status::text in ('pending', 'confirmed')
      and appointment.type::text = 'appointment'
      and (
        public.csp_appointment_start_at(appointment)
          between (now() at time zone 'Asia/Kuala_Lumpur')
              and (now() at time zone 'Asia/Kuala_Lumpur') + interval '60 minutes'
        or appointment.assignment_error_code is not null
      )
    order by appointment.appointment_date, appointment.start_time, appointment.id
  loop
    begin
      perform public.reconcile_appointment_resources(v_row.id, false);
      v_count := v_count + 1;
    exception when others then
      update public.appointments
      set assignment_last_attempted_at = now(),
          assignment_error_code = 'RECONCILE_FAILED',
          assignment_error_message = sqlerrm,
          updated_at = now()
      where id = v_row.id;
    end;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.reconcile_upcoming_appointment_assignments()
  from public, anon, authenticated;
grant execute on function public.reconcile_upcoming_appointment_assignments()
  to service_role;

-- Event-driven attempt when an appointment's protected window or concrete
-- resources change. The deferred trigger runs after the row is valid and does
-- not touch queue positions. Cron below is recovery, not the primary path.
create or replace function public.request_appointment_assignment_reconcile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.type::text = 'appointment'
     and new.actual_started_at is null
     and new.status::text in ('pending', 'confirmed')
     and (
       public.csp_appointment_start_at(new)
         <= (now() at time zone 'Asia/Kuala_Lumpur') + interval '60 minutes'
       or new.assignment_error_code is not null
     ) then
    perform public.reconcile_appointment_resources(new.id, false);
  end if;
  return null;
end;
$$;

drop trigger if exists appointments_request_assignment_reconcile
  on public.appointments;
create constraint trigger appointments_request_assignment_reconcile
after insert or update of
  appointment_date,
  start_time,
  end_time,
  therapist_id,
  room_id,
  status
on public.appointments
deferrable initially deferred
for each row execute function public.request_appointment_assignment_reconcile();

revoke all on function public.request_appointment_assignment_reconcile()
  from public, anon, authenticated;

-- Resource configuration changes invalidate holds immediately instead of
-- waiting for a screen load or the recovery job. This is intentionally scoped
-- to future, not-yet-started appointments that reference the changed resource.
create or replace function public.reconcile_appointments_for_resource_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb := coalesce(to_jsonb(new), to_jsonb(old));
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_appointment record;
begin
  if tg_table_name = 'therapists' then
    v_therapist_id := nullif(v_row ->> 'id', '')::uuid;
  elsif tg_table_name in ('therapist_working_hours', 'therapist_unavailability') then
    v_therapist_id := nullif(v_row ->> 'therapist_id', '')::uuid;
  elsif tg_table_name = 'rooms' then
    v_room_id := nullif(v_row ->> 'id', '')::uuid;
  elsif tg_table_name = 'services' then
    v_service_id := nullif(v_row ->> 'id', '')::uuid;
  end if;

  for v_appointment in
    select appointment.id
    from public.appointments appointment
    where appointment.actual_started_at is null
      and appointment.status::text in ('pending', 'confirmed')
      and public.csp_appointment_start_at(appointment)
            >= (now() at time zone 'Asia/Kuala_Lumpur')
      and (
        (v_therapist_id is not null
          and appointment.therapist_id = v_therapist_id)
        or (v_room_id is not null and appointment.room_id = v_room_id)
        or (v_service_id is not null and appointment.service_id = v_service_id)
      )
    order by appointment.appointment_date, appointment.start_time, appointment.id
  loop
    perform public.reconcile_appointment_resources(v_appointment.id, false);
  end loop;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists therapists_reconcile_appointment_holds
  on public.therapists;
create trigger therapists_reconcile_appointment_holds
after update of availability_status, outlet_id, role
on public.therapists
for each row execute function public.reconcile_appointments_for_resource_change();

drop trigger if exists therapist_hours_reconcile_appointment_holds
  on public.therapist_working_hours;
create trigger therapist_hours_reconcile_appointment_holds
after insert or update or delete
on public.therapist_working_hours
for each row execute function public.reconcile_appointments_for_resource_change();

drop trigger if exists therapist_unavailability_reconcile_appointment_holds
  on public.therapist_unavailability;
create trigger therapist_unavailability_reconcile_appointment_holds
after insert or update or delete
on public.therapist_unavailability
for each row execute function public.reconcile_appointments_for_resource_change();

drop trigger if exists rooms_reconcile_appointment_holds
  on public.rooms;
create trigger rooms_reconcile_appointment_holds
after update of is_active, room_type, total_slots, outlet_id
on public.rooms
for each row execute function public.reconcile_appointments_for_resource_change();

drop trigger if exists services_reconcile_appointment_holds
  on public.services;
create trigger services_reconcile_appointment_holds
after update of room_type, duration, buffer_after_minutes
on public.services
for each row execute function public.reconcile_appointments_for_resource_change();

revoke all on function public.reconcile_appointments_for_resource_change()
  from public, anon, authenticated;

-- Recovery job. pg_cron executes the database function directly; no browser or
-- screen loader writes are involved.
create extension if not exists pg_cron with schema pg_catalog;

do $$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname = 'reconcile-upcoming-appointment-assignments'
  limit 1;
  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;
  perform cron.schedule(
    'reconcile-upcoming-appointment-assignments',
    '*/2 * * * *',
    'select public.reconcile_upcoming_appointment_assignments();'
  );
end;
$$;

-- Check-in/service start is the confirmation boundary. Reconciliation and
-- confirmation happen in the same transaction before actual_started_at is set.
create or replace function public.start_appointment_service(
  p_appointment_id uuid,
  p_started_at timestamptz default now(),
  p_expected_end_at timestamptz default null,
  p_allow_late_extension_overlap boolean default false
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_duration interval;
  v_expected_end timestamptz;
  v_updated public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;
  if not found then raise exception 'Appointment was not found.'; end if;
  if v_appointment.appointment_date <>
      (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service can only be started on its appointment date.';
  end if;
  if v_appointment.status::text not in ('pending', 'confirmed') then
    raise exception 'Only a pending or confirmed service can be started.';
  end if;
  if v_appointment.payment_status::text <> 'paid' then
    raise exception 'Payment must be confirmed before starting this service.';
  end if;
  if v_appointment.actual_started_at is not null then
    raise exception 'This service has already started.';
  end if;

  v_appointment := public.reconcile_appointment_resources(
    p_appointment_id,
    true
  );

  v_duration := coalesce(
    v_appointment.booked_end_at - v_appointment.booked_start_at,
    public.csp_end_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time),
      coalesce(v_appointment.booked_end_time, v_appointment.end_time)
    ) - public.csp_start_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time)
    ),
    v_appointment.end_at - v_appointment.start_at
  );
  if v_duration is null or v_duration <= interval '0 seconds' then
    raise exception 'Service duration must be greater than zero.';
  end if;

  v_expected_end := coalesce(p_expected_end_at, p_started_at + v_duration);
  if v_expected_end <= p_started_at then
    raise exception 'Expected end time must be after the actual start time.';
  end if;
  perform set_config(
    'app.allow_late_extension_overlap',
    case when p_allow_late_extension_overlap then 'on' else 'off' end,
    true
  );

  update public.appointments
  set booked_date = coalesce(booked_date, appointment_date),
      booked_start_time = coalesce(booked_start_time, start_time),
      booked_end_time = coalesce(booked_end_time, end_time),
      booked_start_at = coalesce(
        booked_start_at,
        public.csp_start_at(appointment_date, start_time)
          at time zone 'Asia/Kuala_Lumpur'
      ),
      booked_end_at = coalesce(
        booked_end_at,
        public.csp_end_at(appointment_date, start_time, end_time)
          at time zone 'Asia/Kuala_Lumpur'
      ),
      therapist_assignment_state = 'confirmed',
      room_assignment_state = 'confirmed',
      resources_confirmed_at = now(),
      resources_confirmed_by = auth.uid(),
      status = 'in_progress',
      actual_started_at = p_started_at,
      end_at = v_expected_end at time zone 'Asia/Kuala_Lumpur',
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;
  return v_updated;
end;
$$;

revoke all on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) from public, anon;
grant execute on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) to authenticated;

-- Paid check-in RPCs with add-ons historically wrote actual_started_at
-- directly. Inject the same reconciliation/confirmation boundary before those
-- writes so every check-in path is atomic. The surrounding receipt, add-on,
-- and commission logic stays byte-for-byte unchanged.
do $$
declare
  v_signature text;
  v_definition text;
  v_patched text;
begin
  v_signature :=
    'public.check_in_paid_appointment_with_addon(uuid,jsonb,time without time zone,timestamp with time zone,boolean,uuid,text,numeric,numeric,numeric,text,text)';
  select pg_get_functiondef(v_signature::regprocedure) into v_definition;
  v_patched := regexp_replace(
    v_definition,
    '(if\s+p_allow_late_extension_overlap\s+then\s+perform\s+set_config\(''app\.allow_late_extension_overlap'',\s*''on'',\s*true\);\s+end\s+if;)(\s+update\s+public\.appointments)',
    E'\\1\n\n  v_appointment := public.reconcile_appointment_resources(\n    p_appointment_id,\n    true\n  );\\2',
    'i'
  );
  if v_patched = v_definition then
    raise exception 'Check-in reconciliation patch did not match %', v_signature;
  end if;
  execute v_patched;

  v_signature :=
    'public.check_in_paid_appointment_group_with_addon(uuid,uuid[],jsonb,jsonb,uuid,text,numeric,numeric,numeric,text,text)';
  select pg_get_functiondef(v_signature::regprocedure) into v_definition;
  v_patched := regexp_replace(
    v_definition,
    '(if\s+v_appointment\.status\s+not\s+in\s*\(''pending'',\s*''confirmed''\)\s+or\s+v_appointment\.actual_started_at\s+is\s+not\s+null\s+then\s+raise\s+exception\s+''A group service has already started: %'',\s*v_id;\s+end\s+if;)(\s+if\s+v_first\.id\s+is\s+null)',
    E'\\1\n\n    v_appointment := public.reconcile_appointment_resources(\n      v_id,\n      true\n    );\\2',
    'i'
  );
  if v_patched = v_definition then
    raise exception 'Group check-in reconciliation patch did not match %', v_signature;
  end if;
  execute v_patched;
end;
$$;

-- Preserve the queue contract while making blocked-window wording explicit.
-- A future commitment is not the same thing as a therapist who is busy now.
create or replace function public.get_therapist_queue(
  p_outlet_id uuid,
  p_date date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid,
  name text,
  gender text,
  queue_position integer,
  status text,
  free_at time,
  free_in_minutes integer,
  protected_turn_owed boolean,
  is_recommended boolean,
  rotation_rank bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  return query
  with raw_availability as (
    select availability.therapist_id,
           availability.status,
           availability.free_at,
           availability.free_in_minutes
    from public.get_walkin_therapist_availability(
      p_date,
      p_now_time,
      p_duration
    ) availability
  ),
  availability as (
    select
      raw.therapist_id,
      case
        when raw.status = 'free_now' then 'free_now'
        when exists (
          select 1
          from public.appointments appointment
          where appointment.therapist_id = raw.therapist_id
            and appointment.actual_started_at is not null
            and appointment.actual_completed_at is null
            and public.csp_blocks_schedule(appointment.status::text)
            and appointment.actual_started_at
                  <= ((p_date + p_now_time) at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'busy_now'
        when exists (
          select 1
          from public.appointments appointment
          where appointment.therapist_id = raw.therapist_id
            and appointment.therapist_assignment_state = 'confirmed'
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment)
                  < p_date + p_now_time
                      + make_interval(mins => greatest(p_duration, 1))
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'reserved'
        else 'tentative_hold'
      end as status,
      raw.free_at,
      raw.free_in_minutes
    from raw_availability raw
  ),
  ordered as (
    select
      queue.therapist_id,
      therapist.name,
      therapist.gender,
      queue.queue_position,
      availability.status,
      availability.free_at,
      availability.free_in_minutes,
      queue.protected_turn_owed,
      row_number() over (
        order by
          queue.protected_turn_owed desc,
          queue.turn_consumed_at nulls first,
          queue.queue_position
      ) as rotation_rank
    from public.therapist_queue queue
    join public.therapists therapist on therapist.id = queue.therapist_id
    join availability on availability.therapist_id = queue.therapist_id
    where queue.outlet_id = p_outlet_id
      and queue.queue_date = p_date
  )
  select
    ordered.therapist_id,
    ordered.name,
    ordered.gender,
    ordered.queue_position,
    ordered.status,
    ordered.free_at,
    ordered.free_in_minutes,
    ordered.protected_turn_owed,
    ordered.rotation_rank = (
      select min(candidate.rotation_rank)
      from ordered candidate
      where candidate.status = 'free_now'
    ) as is_recommended,
    ordered.rotation_rank
  from ordered
  order by ordered.rotation_rank;
end;
$$;

revoke all on function public.get_therapist_queue(uuid, date, time, integer)
  from public, anon;
grant execute on function public.get_therapist_queue(uuid, date, time, integer)
  to authenticated;

-- Screen-load refreshes are deliberately retired. Reconciliation is now
-- event-driven with the pg_cron recovery job above.
drop function if exists public.refresh_provisional_therapist_assignments(
  uuid,
  date
);

-- Remove the final legacy column dependency without replacing the mature CSP,
-- group-payment, commission-split, or walk-in logic around it. These are the
-- exact seven live function bodies found by the preflight catalog audit. Their
-- deprecated optional parameters remain accepted for rolling-client safety,
-- but are ignored; only the independent state columns drive behavior.
do $$
declare
  v_signature text;
  v_definition text;
  v_patched text;
begin
  foreach v_signature in array array[
    'public.create_appointment_with_csp(uuid,uuid,uuid,uuid,date,time without time zone,time without time zone,numeric,text,uuid,text,jsonb,integer,text,uuid,text,uuid,text,boolean)',
    'public.update_appointment_with_csp(uuid,uuid,uuid,date,time without time zone,time without time zone,text,uuid,text,boolean)',
    'public.create_appointment_group_with_csp(uuid,text,integer,date,jsonb,text,text,text,uuid)',
    'public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)',
    'public.create_staff_walkin_with_payment(uuid,uuid,uuid,uuid,date,time without time zone,time without time zone,numeric,text,jsonb,integer,text,text,text,uuid,text,numeric,numeric,text,text,text,boolean,text,uuid,text,uuid,text)',
    'public.set_appointment_assignment_metadata(uuid,text,uuid,text,boolean)',
    'public.switch_appointment_therapist(uuid,uuid,text,text,text,text,boolean)'
  ] loop
    select pg_get_functiondef(v_signature::regprocedure)
    into v_definition;
    v_patched := v_definition;

    -- INSERT target lists and their matching legacy values.
    v_patched := regexp_replace(
      v_patched,
      'requested_gender\s*,\s*is_provisional\s*\)',
      'requested_gender)',
      'gi'
    );
    v_patched := regexp_replace(
      v_patched,
      ',\s*coalesce\(p_is_provisional,\s*false\)\s*\)',
      ')',
      'gi'
    );
    v_patched := regexp_replace(
      v_patched,
      ',\s*coalesce\(\(v_allocation\s*->>\s*''is_provisional''\)::boolean,\s*false\)\s*\)',
      ')',
      'gi'
    );

    -- UPDATE assignments in the single/group CSP and metadata RPCs.
    v_patched := regexp_replace(
      v_patched,
      '\s*is_provisional\s*=\s*coalesce\(p_is_provisional,\s*is_provisional\),\s*',
      E'\n      ',
      'gi'
    );
    v_patched := regexp_replace(
      v_patched,
      '\s*is_provisional\s*=\s*coalesce\(\s*\(v_allocation\s*->>\s*''is_provisional''\)::boolean,\s*a\.is_provisional\s*\),\s*',
      E'\n          ',
      'gi'
    );
    v_patched := regexp_replace(
      v_patched,
      '\s*is_provisional\s*=\s*case\s+when\s+p_keep_provisional\s+then\s+is_provisional\s+else\s+false\s+end,\s*',
      E'\n      ',
      'gi'
    );

    -- The walk-in wrapper used the old optional create parameter by name.
    v_patched := regexp_replace(
      v_patched,
      ',\s*p_is_provisional\s*=>\s*false',
      '',
      'gi'
    );

    if v_patched = v_definition then
      raise exception 'Legacy assignment-state patch did not match %', v_signature;
    end if;
    execute v_patched;
  end loop;
end;
$$;

-- State normalization after the legacy column is gone.
create or replace function public.normalize_appointment_assignment_states()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.therapist_assignment_state := coalesce(
    nullif(new.therapist_assignment_state, ''),
    'pending'
  );
  new.room_assignment_state := coalesce(
    nullif(new.room_assignment_state, ''),
    'pending'
  );

  if new.actual_started_at is not null
     or new.status::text in ('in_progress', 'completed')
     or new.type::text = 'walkin' then
    new.therapist_assignment_state := 'confirmed';
    new.room_assignment_state := 'confirmed';
    new.resources_confirmed_at := coalesce(
      new.resources_confirmed_at,
      new.actual_started_at,
      now()
    );
    new.resources_confirmed_by := coalesce(new.resources_confirmed_by, auth.uid());
  elsif new.assignment_source in (
    'specific_customer_request',
    'manual_override'
  ) then
    new.therapist_assignment_state := 'confirmed';
  end if;

  if new.therapist_assignment_state = 'auto_assigned' then
    new.therapist_auto_assigned_at := coalesce(
      new.therapist_auto_assigned_at,
      now()
    );
  end if;
  if new.therapist_assignment_state = 'confirmed'
     and new.room_assignment_state = 'confirmed' then
    new.resources_confirmed_at := coalesce(new.resources_confirmed_at, now());
  end if;
  return new;
end;
$$;

drop index if exists public.appointments_provisional_idx;
alter table public.appointments drop column if exists is_provisional;

notify pgrst, 'reload schema';
