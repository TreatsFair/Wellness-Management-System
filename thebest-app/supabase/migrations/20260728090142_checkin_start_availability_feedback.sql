-- Revalidate the staff-confirmed exact therapist at the atomic service-start
-- boundary. The existing 122q wrapper still owns payment, appointment updates,
-- transaction creation, queue consumption and rollback as one subtransaction.
-- This guard only enriches the resource failure and prevents the legacy core
-- from choosing a replacement when no therapist was explicitly submitted.

do $preflight$
begin
  if to_regprocedure(
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  ) is null then
    raise exception '124 requires the applied atomic finalisation core';
  end if;
  if to_regprocedure(
    'public.finalize_and_start_appointment_core_124_legacy(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  ) is not null then
    raise exception '124 legacy finalisation core already exists';
  end if;
end;
$preflight$;

alter function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) rename to finalize_and_start_appointment_core_124_legacy;

revoke all on function public.finalize_and_start_appointment_core_124_legacy(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

create function public.finalize_and_start_appointment_core(
  p_appointment_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_guest_name text,
  p_guest_phone text,
  p_service_items jsonb,
  p_therapist_id uuid,
  p_assignment_source text,
  p_requested_gender text,
  p_room_id uuid,
  p_room_unit_id uuid,
  p_started_at timestamptz,
  p_expected_end_at timestamptz default null
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_items jsonb;
  v_source text;
  v_requested_gender text;
  v_duration_minutes integer;
  v_start_local timestamp;
  v_end_local timestamp;
  v_check record;
  v_therapist_name text;
  v_busy_until timestamp;
  v_suggested_therapist_id uuid;
  v_suggested_therapist_name text;
  v_error jsonb;
begin
  select appointment.*
  into v_appointment
  from public.appointments appointment
  where appointment.id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Appointment was not found.';
  end if;

  -- Preserve the original idempotent retry result.
  if v_appointment.actual_started_at is not null then
    return public.finalize_and_start_appointment_core_124_legacy(
      p_appointment_id,
      p_customer_name,
      p_customer_phone,
      p_guest_name,
      p_guest_phone,
      p_service_items,
      p_therapist_id,
      p_assignment_source,
      p_requested_gender,
      p_room_id,
      p_room_unit_id,
      p_started_at,
      p_expected_end_at
    );
  end if;

  v_items := case
    when jsonb_typeof(p_service_items) = 'array'
         and jsonb_array_length(p_service_items) > 0
      then p_service_items
    else coalesce(v_appointment.service_items, '[]'::jsonb)
  end;
  v_source := lower(coalesce(
    nullif(trim(p_assignment_source), ''),
    nullif(trim(v_appointment.assignment_source), ''),
    'queue'
  ));
  if v_source not in (
    'queue',
    'gender_preference',
    'specific_customer_request',
    'manual_override'
  ) then
    raise exception using errcode = '22023',
      message = 'Invalid therapist assignment source.';
  end if;

  v_requested_gender := case
    when v_source = 'gender_preference'
      then coalesce(
        nullif(trim(p_requested_gender), ''),
        nullif(trim(v_appointment.requested_gender), '')
      )
    else null
  end;
  if v_source = 'gender_preference' and v_requested_gender is null then
    raise exception using errcode = '22023',
      message = 'Choose a gender for the therapist preference.';
  end if;

  select coalesce(
    sum(greatest(
      coalesce(
        nullif(item ->> 'duration', '')::integer,
        service.duration,
        0
      ),
      0
    )),
    0
  )::integer
  into v_duration_minutes
  from jsonb_array_elements(v_items) item
  left join public.services service
    on service.id = nullif(
      coalesce(item ->> 'id', item ->> 'serviceId'),
      ''
    )::uuid;

  if v_duration_minutes <= 0 then
    v_duration_minutes := greatest(
      ceil(extract(epoch from (
        coalesce(
          v_appointment.booked_end_at,
          public.csp_end_at(
            coalesce(
              v_appointment.booked_date,
              v_appointment.appointment_date
            ),
            coalesce(
              v_appointment.booked_start_time,
              v_appointment.start_time
            ),
            coalesce(v_appointment.booked_end_time, v_appointment.end_time)
          ) at time zone 'Asia/Kuala_Lumpur'
        ) - coalesce(
          v_appointment.booked_start_at,
          public.csp_start_at(
            coalesce(
              v_appointment.booked_date,
              v_appointment.appointment_date
            ),
            coalesce(
              v_appointment.booked_start_time,
              v_appointment.start_time
            )
          ) at time zone 'Asia/Kuala_Lumpur'
        )
      )) / 60.0)::integer,
      1
    );
  end if;

  v_start_local := p_started_at at time zone 'Asia/Kuala_Lumpur';
  v_end_local := coalesce(
    p_expected_end_at at time zone 'Asia/Kuala_Lumpur',
    v_start_local + make_interval(mins => v_duration_minutes)
  );
  if v_end_local <= v_start_local then
    raise exception using errcode = '22023',
      message = 'Expected end time must be after the actual start time.';
  end if;

  -- A queue or gender rule may recommend, but finalisation never chooses.
  if p_therapist_id is null then
    if v_source in ('queue', 'gender_preference') then
      select queue_row.therapist_id, queue_row.name
      into v_suggested_therapist_id, v_suggested_therapist_name
      from public.get_therapist_queue(
        v_appointment.outlet_id,
        v_start_local::date,
        v_start_local::time,
        v_duration_minutes
      ) queue_row
      join public.therapists therapist
        on therapist.id = queue_row.therapist_id
      cross join lateral public.check_booking_availability(
        v_start_local::date,
        v_start_local::time,
        v_end_local::time,
        queue_row.therapist_id,
        p_room_id,
        p_appointment_id,
        null
      ) availability
      where coalesce(availability.therapist_available, false)
        and (
          v_requested_gender is null
          or lower(coalesce(queue_row.gender, ''))
             = lower(v_requested_gender)
        )
        and not exists (
          select 1
          from jsonb_array_elements(v_items) service_item
          where coalesce(therapist.service_commissions, '{}'::jsonb)
                <> '{}'::jsonb
            and not (
              therapist.service_commissions
              ? coalesce(
                  service_item ->> 'id',
                  service_item ->> 'serviceId'
                )
            )
        )
      order by queue_row.rotation_rank
      limit 1;
    end if;

    v_error := jsonb_build_object(
      'code', 'THERAPIST_CONFIRMATION_REQUIRED',
      'message', 'Staff must confirm the therapist before starting.',
      'appointment_id', p_appointment_id,
      'suggested_therapist_id', v_suggested_therapist_id,
      'suggested_therapist_name', v_suggested_therapist_name
    );
    raise exception using errcode = 'P0001', message = v_error::text;
  end if;

  select therapist.name
  into v_therapist_name
  from public.therapists therapist
  where therapist.id = p_therapist_id
    and therapist.outlet_id = v_appointment.outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and not exists (
      select 1
      from jsonb_array_elements(v_items) service_item
      where coalesce(therapist.service_commissions, '{}'::jsonb)
            <> '{}'::jsonb
        and not (
          therapist.service_commissions
          ? coalesce(
              service_item ->> 'id',
              service_item ->> 'serviceId'
            )
        )
    );
  if not found then
    raise exception using errcode = 'P0001',
      message = 'The selected therapist is not eligible for these services.';
  end if;

  select *
  into v_check
  from public.check_booking_availability(
    v_start_local::date,
    v_start_local::time,
    v_end_local::time,
    p_therapist_id,
    p_room_id,
    p_appointment_id,
    null
  );

  if not coalesce(v_check.therapist_available, false) then
    if v_check.therapist_busy_until is not null then
      v_busy_until :=
        v_start_local::date + v_check.therapist_busy_until;
      if v_busy_until <= v_start_local then
        v_busy_until := v_busy_until + interval '1 day';
      end if;
    end if;

    if v_source in ('queue', 'gender_preference') then
      select queue_row.therapist_id, queue_row.name
      into v_suggested_therapist_id, v_suggested_therapist_name
      from public.get_therapist_queue(
        v_appointment.outlet_id,
        v_start_local::date,
        v_start_local::time,
        v_duration_minutes
      ) queue_row
      join public.therapists therapist
        on therapist.id = queue_row.therapist_id
      cross join lateral public.check_booking_availability(
        v_start_local::date,
        v_start_local::time,
        v_end_local::time,
        queue_row.therapist_id,
        p_room_id,
        p_appointment_id,
        null
      ) availability
      where queue_row.therapist_id <> p_therapist_id
        and coalesce(availability.therapist_available, false)
        and (
          v_requested_gender is null
          or lower(coalesce(queue_row.gender, ''))
             = lower(v_requested_gender)
        )
        and not exists (
          select 1
          from public.appointments sibling
          where sibling.appointment_group_id
                = v_appointment.appointment_group_id
            and sibling.id <> p_appointment_id
            and sibling.therapist_id = queue_row.therapist_id
        )
        and not exists (
          select 1
          from jsonb_array_elements(v_items) service_item
          where coalesce(therapist.service_commissions, '{}'::jsonb)
                <> '{}'::jsonb
            and not (
              therapist.service_commissions
              ? coalesce(
                  service_item ->> 'id',
                  service_item ->> 'serviceId'
                )
            )
        )
      order by queue_row.rotation_rank
      limit 1;
    end if;

    v_error := jsonb_build_object(
      'code', 'THERAPIST_BUSY',
      'message', 'The selected therapist is busy for the actual service window.',
      'appointment_id', p_appointment_id,
      'therapist_id', p_therapist_id,
      'therapist_name', v_therapist_name,
      'busy_until', case
        when v_busy_until is null then null
        else v_busy_until at time zone 'Asia/Kuala_Lumpur'
      end,
      'suggested_therapist_id', v_suggested_therapist_id,
      'suggested_therapist_name', v_suggested_therapist_name
    );
    raise exception using errcode = 'P0001', message = v_error::text;
  end if;

  -- The legacy core repeats the authoritative availability checks before its
  -- writes. Supplying the exact ID prevents its old fallback loop from running.
  return public.finalize_and_start_appointment_core_124_legacy(
    p_appointment_id,
    p_customer_name,
    p_customer_phone,
    p_guest_name,
    p_guest_phone,
    v_items,
    p_therapist_id,
    v_source,
    v_requested_gender,
    p_room_id,
    p_room_unit_id,
    p_started_at,
    p_expected_end_at
  );
end;
$function$;

revoke all on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

comment on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) is
  'Owner-only atomic-start guard: exact therapist confirmation, actual-window revalidation and structured busy feedback.';
