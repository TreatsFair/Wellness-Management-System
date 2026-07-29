-- When no eligible therapist can cover a delayed appointment right now,
-- return the earliest complete therapist + room window instead of a generic
-- dead end. This wrapper preserves migration 124's atomic validation/start
-- boundary and never records a future actual_started_at.

do $preflight$
begin
  if to_regprocedure(
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  ) is null
     or to_regprocedure(
       'public.get_available_slots(date,uuid,uuid,integer,uuid,integer)'
     ) is null then
    raise exception
      '126 requires the deployed atomic finalisation and boundary-aware slot functions';
  end if;
end;
$preflight$;

alter function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid,
  timestamptz, timestamptz
) rename to finalize_and_start_appointment_core_126_legacy;

revoke all on function public.finalize_and_start_appointment_core_126_legacy(
  uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid,
  timestamptz, timestamptz
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
  v_room_id uuid;
  v_duration_minutes integer;
  v_buffer_after_minutes integer;
  v_start_local timestamp;
  v_next_start_at timestamptz;
  v_next_end_at timestamptz;
  v_next_therapist_id uuid;
  v_next_therapist_name text;
  v_search_through date;
  v_payload jsonb;
begin
  begin
    return public.finalize_and_start_appointment_core_126_legacy(
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
  exception
    when sqlstate 'P0001' then
      if left(sqlerrm, 1) <> '{' then
        raise;
      end if;
      v_payload := sqlerrm::jsonb;
      if coalesce(v_payload ->> 'code', '') <> 'THERAPIST_BUSY'
         or nullif(v_payload ->> 'suggested_therapist_id', '') is not null
      then
        raise;
      end if;
  end;

  select appointment.*
  into v_appointment
  from public.appointments appointment
  where appointment.id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Appointment was not found.';
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
  v_requested_gender := case
    when v_source = 'gender_preference'
      then coalesce(
        nullif(trim(p_requested_gender), ''),
        nullif(trim(v_appointment.requested_gender), '')
      )
    else null
  end;
  v_room_id := coalesce(p_room_id, v_appointment.room_id);
  v_start_local := p_started_at at time zone 'Asia/Kuala_Lumpur';
  v_search_through := v_start_local::date + 13;

  select
    coalesce(sum(greatest(coalesce(
      nullif(item ->> 'duration', '')::integer,
      service.duration,
      0
    ), 0)), 0)::integer,
    coalesce(max(greatest(coalesce(
      nullif(item ->> 'bufferAfterMinutes', '')::integer,
      nullif(item ->> 'buffer_after_minutes', '')::integer,
      service.buffer_after_minutes,
      0
    ), 0)), 0)::integer
  into v_duration_minutes, v_buffer_after_minutes
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

  with candidate_therapists as (
    select
      therapist.id,
      therapist.name,
      coalesce(queue_row.queue_position, 2147483647) as queue_position
    from public.therapists therapist
    left join public.therapist_queue queue_row
      on queue_row.outlet_id = v_appointment.outlet_id
     and queue_row.queue_date = v_start_local::date
     and queue_row.therapist_id = therapist.id
    where therapist.outlet_id = v_appointment.outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and (
        (
          v_source in ('queue', 'gender_preference')
          and (
            v_requested_gender is null
            or lower(coalesce(therapist.gender, ''))
               = lower(v_requested_gender)
          )
        )
        or (
          v_source in ('specific_customer_request', 'manual_override')
          and therapist.id = p_therapist_id
        )
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
      and not exists (
        select 1
        from public.appointments sibling
        where sibling.appointment_group_id = v_appointment.appointment_group_id
          and sibling.id <> p_appointment_id
          and sibling.therapist_id = therapist.id
      )
  ),
  candidate_dates as (
    select generate_series(
      v_start_local::date,
      v_search_through,
      interval '1 day'
    )::date as candidate_date
  )
  select
    (
      candidate_dates.candidate_date + slot.start_time
    ) at time zone 'Asia/Kuala_Lumpur',
    (
      candidate_dates.candidate_date + slot.end_time
    ) at time zone 'Asia/Kuala_Lumpur',
    candidate.id,
    candidate.name
  into
    v_next_start_at,
    v_next_end_at,
    v_next_therapist_id,
    v_next_therapist_name
  from candidate_therapists candidate
  cross join candidate_dates
  cross join lateral public.get_available_slots(
    candidate_dates.candidate_date,
    candidate.id,
    v_room_id,
    v_duration_minutes,
    p_appointment_id,
    v_buffer_after_minutes
  ) slot
  where slot.classification <> 'unavailable'
    and candidate_dates.candidate_date + slot.start_time > v_start_local
  order by
    candidate_dates.candidate_date + slot.start_time,
    slot.score desc,
    candidate.queue_position,
    candidate.id
  limit 1;

  v_payload := v_payload || jsonb_build_object(
    'message', case
      when v_next_start_at is null then
        'No complete therapist and room window was found in the next 14 days.'
      else
        'The current window is unavailable. The next complete service window is ready for staff confirmation.'
    end,
    'next_available_start_at', v_next_start_at,
    'next_available_end_at', v_next_end_at,
    'next_available_therapist_id', v_next_therapist_id,
    'next_available_therapist_name', v_next_therapist_name,
    'availability_searched_through', v_search_through
  );

  raise exception using errcode = 'P0001', message = v_payload::text;
end;
$function$;

revoke all on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid,
  timestamptz, timestamptz
) from public, anon, authenticated, service_role;

comment on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid,
  timestamptz, timestamptz
) is
  'Atomically validates and starts an appointment, returning the next complete delayed window when no therapist is free now.';
