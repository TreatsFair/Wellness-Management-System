-- Reactivating a no-show is an explicit audited lifecycle transition. A
-- generic appointment update remains unable to change no_show back to active.

do $preflight$
begin
  if to_regprocedure(
    'public.check_booking_availability(date,time without time zone,time without time zone,uuid,uuid,uuid,uuid)'
  ) is null
     or to_regprocedure(
       'public.allocate_specific_room_unit(uuid,timestamp without time zone,timestamp without time zone,uuid,uuid,uuid)'
     ) is null
     or not exists (
       select 1
       from pg_trigger
       where tgrelid = 'public.appointments'::regclass
         and tgname = 'appointments_write_audit_log'
         and not tgisinternal
     ) then
    raise exception
      '127 requires deployed availability, room-unit and appointment-audit contracts';
  end if;
end;
$preflight$;

create or replace function public.reactivate_no_show_appointment(
  p_appointment_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_therapist_id uuid,
  p_room_id uuid,
  p_room_unit_id uuid default null,
  p_updates jsonb default '{}'::jsonb
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_result public.appointments%rowtype;
  v_check record;
  v_start_at timestamp;
  v_end_at timestamp;
  v_block_end_at timestamp;
  v_room_mode text;
  v_room_type text;
  v_room_unit_id uuid;
  v_room_unit_name text := '';
  v_items jsonb;
  v_source text;
  v_requested_gender text;
  v_customer_id uuid;
  v_service_id uuid;
  v_service_name text;
  v_item_count integer;
  v_total_price numeric;
  v_buffer_after_minutes integer;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception using errcode = '42501',
      message = 'Only staff may reschedule and reactivate a no-show.';
  end if;

  if p_appointment_id is null
     or p_date is null
     or p_start_time is null
     or p_end_time is null
     or p_therapist_id is null
     or p_room_id is null then
    raise exception using errcode = '22023',
      message = 'Appointment, date, time, therapist and room are required.';
  end if;

  select appointment.*
  into v_appointment
  from public.appointments appointment
  where appointment.id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Appointment was not found.';
  end if;
  if lower(v_appointment.status::text) <> 'no_show' then
    raise exception using errcode = 'P0001',
      message = 'Only a no-show appointment can be reactivated.';
  end if;
  if p_date = v_appointment.appointment_date
     and p_start_time = v_appointment.start_time
     and p_end_time = v_appointment.end_time then
    raise exception using errcode = '22023',
      message = 'Choose a new date or time before reactivating this no-show.';
  end if;

  v_start_at := public.csp_start_at(p_date, p_start_time);
  v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);
  if v_end_at <= v_start_at then
    raise exception using errcode = '22023',
      message = 'The rescheduled end must be after the start.';
  end if;

  v_items := case
    when jsonb_typeof(p_updates -> 'service_items') = 'array'
         and jsonb_array_length(p_updates -> 'service_items') > 0
      then p_updates -> 'service_items'
    else coalesce(v_appointment.service_items, '[]'::jsonb)
  end;
  v_source := lower(coalesce(
    nullif(trim(p_updates ->> 'assignment_source'), ''),
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
        nullif(trim(p_updates ->> 'requested_gender'), ''),
        nullif(trim(v_appointment.requested_gender), '')
      )
    else null
  end;
  if v_source = 'gender_preference' and v_requested_gender is null then
    raise exception using errcode = '22023',
      message = 'Choose a therapist gender before reactivating.';
  end if;

  v_customer_id := coalesce(
    nullif(p_updates ->> 'customer_id', '')::uuid,
    v_appointment.customer_id
  );
  v_service_id := coalesce(
    nullif(p_updates ->> 'service_id', '')::uuid,
    v_appointment.service_id
  );
  v_service_name := coalesce(
    nullif(trim(p_updates ->> 'service_name'), ''),
    v_appointment.service_name
  );
  v_item_count := greatest(coalesce(
    nullif(p_updates ->> 'item_count', '')::integer,
    v_appointment.item_count,
    jsonb_array_length(v_items),
    1
  ), 1);
  v_total_price := coalesce(
    nullif(p_updates ->> 'total_price', '')::numeric,
    v_appointment.total_price
  );
  select coalesce(max(greatest(coalesce(
    nullif(item ->> 'bufferAfterMinutes', '')::integer,
    nullif(item ->> 'buffer_after_minutes', '')::integer,
    service.buffer_after_minutes,
    0
  ), 0)), coalesce(v_appointment.buffer_after_minutes, 0))::integer
  into v_buffer_after_minutes
  from jsonb_array_elements(v_items) item
  left join public.services service
    on service.id = nullif(
      coalesce(item ->> 'id', item ->> 'serviceId'),
      ''
    )::uuid;
  v_block_end_at := v_end_at
    + make_interval(mins => greatest(v_buffer_after_minutes, 0));

  if not exists (
    select 1
    from public.therapists therapist
    where therapist.id = p_therapist_id
      and therapist.outlet_id = v_appointment.outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and (
        v_requested_gender is null
        or lower(coalesce(therapist.gender, ''))
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
  ) then
    raise exception using errcode = 'P0001',
      message = 'The selected therapist is not eligible for this reschedule.';
  end if;

  select room.allocation_mode, room.room_type::text
  into v_room_mode, v_room_type
  from public.rooms room
  where room.id = p_room_id
    and room.outlet_id = v_appointment.outlet_id
    and coalesce(room.is_active, true);
  if not found then
    raise exception using errcode = 'P0001',
      message = 'The selected room is inactive or belongs to another outlet.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_items) service_item
    join public.services service
      on service.id = nullif(
        coalesce(
          service_item ->> 'id',
          service_item ->> 'serviceId'
        ),
        ''
      )::uuid
    where lower(coalesce(service.room_type::text, ''))
          <> lower(coalesce(v_room_type, ''))
  ) then
    raise exception using errcode = 'P0001',
      message = 'The selected room does not match the rescheduled services.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      v_appointment.outlet_id::text || ':' || p_date::text,
      0
    )
  );

  select *
  into v_check
  from public.check_booking_availability(
    p_date,
    p_start_time,
    v_block_end_at::time,
    p_therapist_id,
    p_room_id,
    p_appointment_id,
    null
  );
  if not coalesce(v_check.therapist_available, false) then
    raise exception using errcode = '23P01',
      message = 'The selected therapist is unavailable for the rescheduled service and cleanup window.';
  end if;
  if coalesce(v_check.room_full, false) then
    raise exception using errcode = '23P01',
      message = 'The selected room is full for the rescheduled service and cleanup window.';
  end if;

  if coalesce(v_room_mode, 'capacity') = 'specific_room' then
    v_room_unit_id := public.allocate_specific_room_unit(
      p_room_id,
      v_start_at,
      v_block_end_at,
      p_room_unit_id,
      p_appointment_id,
      null
    );
    select room_unit.name
    into v_room_unit_name
    from public.room_units room_unit
    where room_unit.id = v_room_unit_id
      and room_unit.zone_id = p_room_id
      and room_unit.outlet_id = v_appointment.outlet_id
      and room_unit.is_active;
    if not found then
      raise exception using errcode = 'P0001',
        message = 'The selected numbered room is invalid for this outlet.';
    end if;
  elsif p_room_unit_id is not null then
    raise exception using errcode = '22023',
      message = 'This shared room zone does not accept a numbered room.';
  end if;

  update public.appointments
  set appointment_date = p_date,
      start_time = p_start_time,
      end_time = p_end_time,
      start_at = v_start_at,
      end_at = v_end_at,
      booked_date = p_date,
      booked_start_time = p_start_time,
      booked_end_time = p_end_time,
      booked_start_at =
        v_start_at at time zone 'Asia/Kuala_Lumpur',
      booked_end_at =
        v_end_at at time zone 'Asia/Kuala_Lumpur',
      therapist_id = p_therapist_id,
      room_id = p_room_id,
      room_unit_id = v_room_unit_id,
      room_unit_name = v_room_unit_name,
      customer_id = v_customer_id,
      service_id = v_service_id,
      service_name = v_service_name,
      service_items = v_items,
      item_count = v_item_count,
      total_price = v_total_price,
      buffer_after_minutes = v_buffer_after_minutes,
      assignment_source = v_source,
      requested_therapist_id = case
        when v_source in (
          'specific_customer_request',
          'manual_override'
        ) then p_therapist_id
        else null
      end,
      requested_gender = v_requested_gender,
      status = 'confirmed'::public.appointment_status,
      checked_in_at = null,
      checked_in_by = null,
      actual_started_at = null,
      actual_completed_at = null,
      therapist_assignment_state = 'confirmed',
      room_assignment_state = 'confirmed',
      resources_confirmed_at = now(),
      resources_confirmed_by = auth.uid(),
      therapist_auto_assigned_at = case
        when v_source in ('queue', 'gender_preference') then now()
        else null
      end,
      assignment_last_attempted_at = now(),
      assignment_error_code = null,
      assignment_error_message = null,
      assignment_reconcile_attempt_count = 0,
      assignment_next_retry_at = null,
      updated_at = now()
  where id = p_appointment_id
    and status = 'no_show'::public.appointment_status
  returning * into v_result;

  if not found then
    raise exception using errcode = '40001',
      message = 'The no-show changed while it was being reactivated. Reload and try again.';
  end if;

  return v_result;
end;
$function$;

revoke all on function public.reactivate_no_show_appointment(
  uuid, date, time, time, uuid, uuid, uuid, jsonb
) from public, anon;
grant execute on function public.reactivate_no_show_appointment(
  uuid, date, time, time, uuid, uuid, uuid, jsonb
) to authenticated;

comment on function public.reactivate_no_show_appointment(
  uuid, date, time, time, uuid, uuid, uuid, jsonb
) is
  'Atomically reschedules and reactivates one no-show while preserving payment, transactions and audited no-show history.';
