-- Fix: 097 added queue-rotation logic to start_appointment_service(uuid,
-- timestamptz) -- a 2-arg signature that predates checkin_csp_start.sql
-- (20260717071356), which had already replaced it with a 4-arg version
-- (uuid, timestamptz, timestamptz, boolean) accepting an explicit expected
-- end time and a late-extension-overlap override. The Dart client
-- (AppointmentRepository.startAppointment / PaymentService checkout paths)
-- always calls the 4-arg form, so 097's queue-consume logic never actually
-- ran -- it was attached to a dead overload. This drops the stray 2-arg
-- overload and moves the same queue-rotation logic onto the real 4-arg
-- function that both single and group check-in (via
-- start_appointment_group_service, which loops calling this) go through.

drop function if exists public.start_appointment_service(uuid, timestamptz);

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
  v_this_position integer;
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
  if v_appointment.status not in ('pending', 'confirmed') then
    raise exception 'Only a pending or confirmed service can be started.';
  end if;
  if v_appointment.payment_status <> 'paid' then
    raise exception 'Payment must be confirmed before starting this service.';
  end if;
  if v_appointment.actual_started_at is not null then
    raise exception 'This service has already started.';
  end if;

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
      status = 'in_progress',
      actual_started_at = p_started_at,
      end_at = v_expected_end at time zone 'Asia/Kuala_Lumpur',
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  -- Queue rotation. Only bookable service types participate; therapist_id
  -- is always populated by the time a service can start.
  if v_updated.therapist_id is not null then
    perform public.seed_therapist_queue(v_updated.outlet_id, v_updated.appointment_date);

    select queue_position into v_this_position
    from public.therapist_queue
    where outlet_id = v_updated.outlet_id
      and queue_date = v_updated.appointment_date
      and therapist_id = v_updated.therapist_id;

    if v_this_position is not null then
      -- Anyone still ahead of this therapist (not yet consumed today) who is
      -- currently mid-service on a specific customer request had their
      -- normal turn skipped by this start -- flag it so get_therapist_queue
      -- resurfaces them at the front the moment they free up.
      update public.therapist_queue tq
      set protected_turn_owed = true,
          protected_turn_reason = 'busy_specific_request'
      where tq.outlet_id = v_updated.outlet_id
        and tq.queue_date = v_updated.appointment_date
        and tq.turn_consumed_at is null
        and tq.queue_position < v_this_position
        and exists (
          select 1 from public.appointments busy
          where busy.therapist_id = tq.therapist_id
            and busy.status = 'in_progress'
            and busy.assignment_source = 'specific_customer_request'
            and busy.id <> v_updated.id
        );

      update public.therapist_queue
      set turn_consumed_at = p_started_at,
          protected_turn_owed = false,
          protected_turn_reason = null
      where outlet_id = v_updated.outlet_id
        and queue_date = v_updated.appointment_date
        and therapist_id = v_updated.therapist_id;
    end if;
  end if;

  return v_updated;
end;
$$;

revoke all on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) from public, anon;
grant execute on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) to authenticated;
