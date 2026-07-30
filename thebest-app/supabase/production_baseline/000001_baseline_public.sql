--
-- PostgreSQL database dump
--

\restrict WCUTRHEX31ybwXyaFzdPzypcMqZDUe8gjt6EO0ziJzZLzwk3twuthChppv77VyU

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.10 (Debian 17.10-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: appointment_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.appointment_status AS ENUM (
    'pending',
    'confirmed',
    'in_progress',
    'completed',
    'cancelled',
    'no_show'
);


--
-- Name: appointment_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.appointment_type AS ENUM (
    'appointment',
    'walkin'
);


--
-- Name: payment_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_method AS ENUM (
    'cash',
    'qr_code',
    'credit_card',
    'debit_card',
    'billplz',
    'others'
);


--
-- Name: payment_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_status AS ENUM (
    'unpaid',
    'paid',
    'refunded',
    'voided'
);


--
-- Name: room_floor; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.room_floor AS ENUM (
    'Ground',
    'Upper'
);


--
-- Name: TYPE room_floor; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.room_floor IS 'Physical floor grouping for rooms: Ground or Upper.';


--
-- Name: room_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.room_type AS ENUM (
    'body_room',
    'foot_chair'
);


--
-- Name: user_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.user_role AS ENUM (
    'admin',
    'staff'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid,
    therapist_id uuid,
    room_id uuid,
    service_id uuid NOT NULL,
    appointment_date date NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    status public.appointment_status DEFAULT 'confirmed'::public.appointment_status NOT NULL,
    total_price numeric(10,2) DEFAULT 0 NOT NULL,
    type public.appointment_type DEFAULT 'appointment'::public.appointment_type NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    notes text DEFAULT ''::text NOT NULL,
    service_items jsonb DEFAULT '[]'::jsonb NOT NULL,
    item_count integer DEFAULT 1 NOT NULL,
    service_name text DEFAULT ''::text NOT NULL,
    appointment_group_id uuid,
    start_at timestamp without time zone,
    end_at timestamp without time zone,
    outlet_id uuid NOT NULL,
    online_booking_service_id uuid,
    booked_date date,
    booked_start_time time without time zone,
    booked_end_time time without time zone,
    booked_start_at timestamp with time zone,
    booked_end_at timestamp with time zone,
    actual_started_at timestamp with time zone,
    actual_completed_at timestamp with time zone,
    buffer_after_minutes integer DEFAULT 0 NOT NULL,
    payment_status public.payment_status DEFAULT 'unpaid'::public.payment_status NOT NULL,
    room_unit_id uuid,
    room_unit_name text DEFAULT ''::text NOT NULL,
    assignment_source text DEFAULT 'queue'::text NOT NULL,
    requested_therapist_id uuid,
    requested_gender text,
    therapist_assignment_state text DEFAULT 'pending'::text NOT NULL,
    room_assignment_state text DEFAULT 'pending'::text NOT NULL,
    therapist_auto_assigned_at timestamp with time zone,
    resources_confirmed_at timestamp with time zone,
    resources_confirmed_by uuid,
    assignment_last_attempted_at timestamp with time zone,
    assignment_error_code text,
    assignment_error_message text,
    assignment_reconcile_attempt_count integer DEFAULT 0 NOT NULL,
    assignment_next_retry_at timestamp with time zone,
    checked_in_at timestamp with time zone,
    checked_in_by uuid,
    cancelled_at timestamp with time zone,
    cancelled_by uuid,
    cancellation_reason text,
    guest_name text DEFAULT ''::text NOT NULL,
    guest_phone text DEFAULT ''::text NOT NULL,
    CONSTRAINT appointments_assignment_attempt_count_check CHECK ((assignment_reconcile_attempt_count >= 0)),
    CONSTRAINT appointments_assignment_source_check CHECK ((assignment_source = ANY (ARRAY['queue'::text, 'gender_preference'::text, 'specific_customer_request'::text, 'manual_override'::text]))),
    CONSTRAINT appointments_buffer_after_minutes_check CHECK (((buffer_after_minutes >= 0) AND (buffer_after_minutes <= 240))),
    CONSTRAINT appointments_confirmed_room_concrete CHECK (((room_assignment_state <> 'confirmed'::text) OR (room_id IS NOT NULL))),
    CONSTRAINT appointments_confirmed_therapist_concrete CHECK (((therapist_assignment_state <> 'confirmed'::text) OR (therapist_id IS NOT NULL))),
    CONSTRAINT appointments_requested_gender_check CHECK (((requested_gender IS NULL) OR (requested_gender = ANY (ARRAY['Male'::text, 'Female'::text])))),
    CONSTRAINT appointments_room_assignment_state_check CHECK ((room_assignment_state = ANY (ARRAY['pending'::text, 'auto_assigned'::text, 'confirmed'::text]))),
    CONSTRAINT appointments_started_requires_concrete CHECK ((NOT (((resources_confirmed_at IS NOT NULL) OR (actual_started_at IS NOT NULL) OR (status = ANY (ARRAY['in_progress'::public.appointment_status, 'completed'::public.appointment_status]))) AND ((therapist_id IS NULL) OR (room_id IS NULL))))),
    CONSTRAINT appointments_therapist_assignment_state_check CHECK ((therapist_assignment_state = ANY (ARRAY['pending'::text, 'auto_assigned'::text, 'confirmed'::text])))
);


--
-- Name: COLUMN appointments.start_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.start_at IS 'ACTIVE OPERATIONAL resource-blocking window start. Equals the scheduled start until the service starts, then the actual start. This is NOT the scheduled time -- do not display it as such.';


--
-- Name: COLUMN appointments.booked_start_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.booked_start_at IS 'Original SCHEDULED start. Frozen at creation and never rewritten by check-in or service start. Display "Scheduled" from coalesce(booked_start_at, start_at).';


--
-- Name: COLUMN appointments.booked_end_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.booked_end_at IS 'Original SCHEDULED end. Frozen at creation and never rewritten by check-in or service start.';


--
-- Name: COLUMN appointments.actual_started_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.actual_started_at IS 'When the therapist actually began the service. Setting it moves the operational start_at/end_at window (see project_appointment_end_on_actual_start) but never booked_*.';


--
-- Name: COLUMN appointments.checked_in_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.checked_in_at IS 'When the customer physically checked in. Independent of actual_started_at: an appointment may be checked in (status still confirmed) long before the therapist starts the service. Never overwrites booked_* and never moves the operational start_at/end_at window.';


--
-- Name: COLUMN appointments.checked_in_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.checked_in_by IS 'Staff profile that recorded the check-in. NULL for rows created before check-in tracking existed.';


--
-- Name: COLUMN appointments.cancelled_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.cancelled_at IS 'When the appointment was cancelled through cancel_appointment(). NULL for rows cancelled before the dedicated RPC existed.';


--
-- Name: COLUMN appointments.guest_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.guest_name IS 'Per-pax display name used when the appointment is not represented by its own customer row.';


--
-- Name: COLUMN appointments.guest_phone; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.appointments.guest_phone IS 'Per-pax contact number used when the appointment is not represented by its own customer row.';


--
-- Name: CONSTRAINT appointments_confirmed_room_concrete ON appointments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON CONSTRAINT appointments_confirmed_room_concrete ON public.appointments IS 'Project B: a confirmed ROOM assignment must carry a concrete room_id. status=confirmed (booking) does NOT imply this.';


--
-- Name: CONSTRAINT appointments_confirmed_therapist_concrete ON appointments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON CONSTRAINT appointments_confirmed_therapist_concrete ON public.appointments IS 'Project B: a confirmed THERAPIST assignment must carry a concrete therapist_id. status=confirmed (booking) does NOT imply this.';


--
-- Name: CONSTRAINT appointments_started_requires_concrete ON appointments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON CONSTRAINT appointments_started_requires_concrete ON public.appointments IS 'Project B: once resources_confirmed_at/actual_started_at is set or status is in_progress/completed, both therapist_id and room_id must be concrete. A future confirmed (booking) appointment may remain fully anonymous.';


--
-- Name: adjust_appointment_service_end(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.adjust_appointment_service_end(p_appointment_id uuid, p_expected_end_at timestamp with time zone) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_appointment public.appointments%rowtype;
  v_updated public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  if v_appointment.status <> 'in_progress' or v_appointment.actual_started_at is null then
    raise exception 'Only an in-progress service can change its expected end time.';
  end if;
  if v_appointment.appointment_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service time can only be adjusted on its appointment date.';
  end if;
  if p_expected_end_at <= v_appointment.actual_started_at then
    raise exception 'Expected end time must be after the actual start time.';
  end if;

  perform set_config('app.allow_late_extension_overlap', 'on', true);
  update public.appointments
  set end_at = p_expected_end_at at time zone 'Asia/Kuala_Lumpur',
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  return v_updated;
end;
$$;


--
-- Name: allocate_preference_provisional_slots(uuid, date, time without time zone, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.allocate_preference_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(pax_index integer, therapist_id uuid, room_id uuid, end_time time without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.validate_one_based_capacity_requirements_122s(p_requirements);

  return query
  select *
  from public.allocate_preference_provisional_slots_122r_impl(
    p_outlet_id,
    p_date,
    p_start_time,
    p_requirements,
    p_exclude_appointment_group_id
  );
end;
$$;


--
-- Name: allocate_preference_provisional_slots_122r_impl(uuid, date, time without time zone, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.allocate_preference_provisional_slots_122r_impl(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(pax_index integer, therapist_id uuid, room_id uuid, end_time time without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_base jsonb := '{}'::jsonb;
  v_row record;
  v_requirement jsonb;
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_reserved_end timestamp;
  v_used uuid[] := array[]::uuid[];
  v_selected uuid;
begin
  -- Reuse the established allocator for typed room capacity. Its complete
  -- result also proves that a distinct-room allocation exists.
  for v_row in
    select * from public.allocate_provisional_slots(
      p_outlet_id, p_date, p_start_time, p_requirements,
      p_exclude_appointment_group_id
    )
  loop
    v_base := v_base || jsonb_build_object(
      v_row.pax_index::text,
      jsonb_build_object(
        'room_id', v_row.room_id,
        'end_time', v_row.end_time
      )
    );
  end loop;
  if (select count(*) from jsonb_object_keys(v_base))
       <> jsonb_array_length(p_requirements) then
    return;
  end if;

  for v_requirement in
    select r from jsonb_array_elements(p_requirements) r
    order by
      case r ->> 'assignment_source'
        when 'specific_customer_request' then 0
        when 'gender_preference' then 1
        else 2
      end,
      (r ->> 'duration_minutes')::integer
        + greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0)
        desc,
      (r ->> 'pax_index')::integer
  loop
    pax_index := (v_requirement ->> 'pax_index')::integer;
    v_reserved_end := v_start + make_interval(
      mins => (v_requirement ->> 'duration_minutes')::integer
        + greatest(
          coalesce((v_requirement ->> 'buffer_after_minutes')::integer,
          0), 0
        )
    );
    select t.id
    into v_selected
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
      and not (t.id = any(v_used))
      and (
        coalesce(v_requirement ->> 'assignment_source', 'queue')
          <> 'specific_customer_request'
        or t.id = (v_requirement ->> 'requested_therapist_id')::uuid
      )
      and (
        coalesce(v_requirement ->> 'assignment_source', 'queue')
          <> 'gender_preference'
        or lower(t.gender) = lower(v_requirement ->> 'requested_gender')
      )
      and not exists (
        select 1
        from jsonb_array_elements_text(
          coalesce(v_requirement -> 'service_ids', '[]'::jsonb)
        ) service_id(value)
        where coalesce(t.service_commissions, '{}'::jsonb) <> '{}'::jsonb
          and not (t.service_commissions ? service_id.value)
      )
      and exists (
        select 1 from public.therapist_working_hours h
        where h.therapist_id = t.id
          and (
            (
              h.day_of_week = extract(dow from p_date)::integer
              and p_date + h.start_time <= v_start
              and p_date + h.end_time
                + case when h.end_time <= h.start_time
                    then interval '1 day' else interval '0' end
                >= v_reserved_end
            )
            or (
              h.end_time <= h.start_time
              and h.day_of_week =
                extract(dow from p_date - 1)::integer
              and (p_date - 1) + h.start_time <= v_start
              and (p_date - 1) + h.end_time + interval '1 day'
                >= v_reserved_end
            )
          )
      )
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = t.id
          and u.starts_at at time zone 'Asia/Kuala_Lumpur' < v_reserved_end
          and u.ends_at at time zone 'Asia/Kuala_Lumpur' > v_start
      )
      and not exists (
        select 1 from public.appointments a
        where a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_reserved_end
          and public.csp_appointment_block_end_at(a) > v_start
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from
              p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1 from public.booking_holds h
        where h.assigned_therapist_id = t.id
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
          and h.start_at at time zone 'Asia/Kuala_Lumpur' < v_reserved_end
          and (
            h.end_at + make_interval(
              mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
            )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start
      )
    order by t.display_order nulls last, t.name, t.id
    limit 1;
    if v_selected is null then return; end if;
    v_used := array_append(v_used, v_selected);
    therapist_id := v_selected;
    room_id := nullif(v_base -> pax_index::text ->> 'room_id', '')::uuid;
    end_time := nullif(v_base -> pax_index::text ->> 'end_time', '')::time;
    return next;
  end loop;
end;
$$;


--
-- Name: allocate_provisional_slots(uuid, date, time without time zone, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(pax_index integer, therapist_id uuid, room_id uuid, end_time time without time zone)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_requirement jsonb;
  v_requirement_count integer;
  v_pax_index integer;
  v_duration integer;
  v_buffer integer;
  v_room_type text;
  v_source text;
  v_gender text;
  v_fixed_therapist uuid;
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_treatment_end timestamp;
  v_reserved_end timestamp;
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_dow integer := extract(dow from p_date - 1)::integer;
  v_therapist_id uuid;
  v_room_id uuid;
  v_used_therapists uuid[] := array[]::uuid[];
  v_results jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception using errcode = '22023',
      message = 'p_requirements must be a non-empty JSON array.';
  end if;

  v_requirement_count := jsonb_array_length(p_requirements);
  if exists (
    select 1
    from jsonb_array_elements(p_requirements) requirement
    where jsonb_typeof(requirement) is distinct from 'object'
      or coalesce((requirement ->> 'pax_index')::integer, 0) < 1
      or coalesce((requirement ->> 'duration_minutes')::integer, 0) < 1
      or coalesce(nullif(trim(requirement ->> 'room_type'), ''), '') = ''
      or lower(coalesce(
           nullif(requirement ->> 'assignment_source', ''),
           'queue'
         )) not in (
           'queue',
           'gender_preference',
           'specific_customer_request',
           'manual_override'
         )
  ) then
    raise exception using errcode = '22023',
      message = 'Every pax requirement needs a valid index, duration, room type, and assignment source.';
  end if;

  if (
    select count(distinct (requirement ->> 'pax_index')::integer)
    from jsonb_array_elements(p_requirements) requirement
  ) <> v_requirement_count then
    raise exception using errcode = '22023',
      message = 'Every pax requirement must have a unique pax_index.';
  end if;

  -- Longest windows first prevents a short pax from taking the only therapist
  -- who can cover a later end. Within each requirement candidates follow the
  -- live queue, without protected-turn weighting.
  for v_requirement in
    select requirement
    from jsonb_array_elements(p_requirements) requirement
    order by
      coalesce((requirement ->> 'duration_minutes')::integer, 0)
        + greatest(
            coalesce(
              (requirement ->> 'buffer_after_minutes')::integer,
              0
            ),
            0
          ) desc,
      (requirement ->> 'pax_index')::integer
  loop
    v_pax_index := (v_requirement ->> 'pax_index')::integer;
    v_duration := (v_requirement ->> 'duration_minutes')::integer;
    v_buffer := greatest(
      coalesce((v_requirement ->> 'buffer_after_minutes')::integer, 0),
      0
    );
    v_room_type := lower(trim(v_requirement ->> 'room_type'));
    v_source := lower(coalesce(
      nullif(v_requirement ->> 'assignment_source', ''),
      'queue'
    ));
    v_gender := case
      when v_source = 'gender_preference'
        then nullif(trim(v_requirement ->> 'requested_gender'), '')
      else null
    end;
    v_fixed_therapist := case
      when v_source in (
        'specific_customer_request',
        'manual_override'
      ) then nullif(
        coalesce(
          v_requirement ->> 'requested_therapist_id',
          v_requirement ->> 'manual_lock_id'
        ),
        ''
      )::uuid
      else null
    end;

    if v_source = 'gender_preference' and v_gender is null then
      raise exception using errcode = '22023',
        message = 'A gender preference requires requested_gender.';
    end if;
    if v_source in ('specific_customer_request', 'manual_override')
       and v_fixed_therapist is null then
      raise exception using errcode = '22023',
        message = 'A specific or manual assignment requires a therapist.';
    end if;

    v_treatment_end := v_start + make_interval(mins => v_duration);
    v_reserved_end := v_treatment_end + make_interval(mins => v_buffer);

    select therapist.id
    into v_therapist_id
    from public.therapists therapist
    left join public.therapist_queue queue_row
      on queue_row.outlet_id = p_outlet_id
     and queue_row.queue_date = p_date
     and queue_row.therapist_id = therapist.id
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and not (therapist.id = any(v_used_therapists))
      and (v_fixed_therapist is null or therapist.id = v_fixed_therapist)
      and (
        v_gender is null
        or lower(coalesce(therapist.gender, '')) = lower(v_gender)
      )
      and not exists (
        select 1
        from jsonb_array_elements_text(
          coalesce(v_requirement -> 'service_ids', '[]'::jsonb)
        ) requested_service(service_id)
        where coalesce(therapist.service_commissions, '{}'::jsonb)
              <> '{}'::jsonb
          and not (
            therapist.service_commissions
            ? requested_service.service_id
          )
      )
      and exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = therapist.id
          and (
            (
              hours.day_of_week = v_dow
              and p_date + hours.start_time <= v_start
              and p_date + hours.end_time
                + case
                    when hours.end_time <= hours.start_time
                      then interval '1 day'
                    else interval '0'
                  end >= v_reserved_end
            )
            or (
              hours.end_time <= hours.start_time
              and hours.day_of_week = v_prev_dow
              and (p_date - 1) + hours.start_time <= v_start
              and (p_date - 1) + hours.end_time + interval '1 day'
                    >= v_reserved_end
            )
          )
      )
      and not exists (
        select 1
        from public.therapist_unavailability unavailable
        where unavailable.therapist_id = therapist.id
          and unavailable.starts_at at time zone 'Asia/Kuala_Lumpur'
                < v_reserved_end
          and unavailable.ends_at at time zone 'Asia/Kuala_Lumpur'
                > v_start
      )
      and not exists (
        select 1
        from public.appointments appointment
        where appointment.therapist_id = therapist.id
          and appointment.appointment_date between p_date - 1 and p_date + 1
          and public.csp_blocks_schedule(appointment.status::text)
          and public.csp_appointment_start_at(appointment) < v_reserved_end
          and public.csp_appointment_block_end_at(appointment) > v_start
          and (
            p_exclude_appointment_group_id is null
            or appointment.appointment_group_id is distinct from
                 p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1
        from public.booking_holds hold
        where hold.assigned_therapist_id = therapist.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and coalesce(hold.hold_kind, '') <> 'staff_walkin_draft'
          and hold.start_at at time zone 'Asia/Kuala_Lumpur'
                < v_reserved_end
          and (
            hold.end_at + make_interval(
              mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
            )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start
      )
    order by
      case when v_fixed_therapist is not null then 0 else 1 end,
      queue_row.turn_consumed_at nulls first,
      queue_row.queue_position nulls last,
      therapist.display_order nulls last,
      therapist.name,
      therapist.id
    limit 1;

    if v_therapist_id is null then
      return;
    end if;

    select room.id
    into v_room_id
    from public.rooms room
    where room.outlet_id = p_outlet_id
      and coalesce(room.is_active, true)
      and lower(coalesce(room.room_type::text, '')) = v_room_type
      and (
        (
          select count(*)
          from public.appointments appointment
          where appointment.room_id = room.id
            and appointment.appointment_date between p_date - 1 and p_date + 1
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment) < v_reserved_end
            and public.csp_appointment_block_end_at(appointment) > v_start
            and (
              p_exclude_appointment_group_id is null
              or appointment.appointment_group_id is distinct from
                   p_exclude_appointment_group_id
            )
        )
        + (
          select count(*)
          from public.booking_holds hold
          where hold.assigned_room_id = room.id
            and hold.status = 'pending_payment'
            and hold.expires_at > now()
            and coalesce(hold.hold_kind, '') <> 'staff_walkin_draft'
            and hold.start_at at time zone 'Asia/Kuala_Lumpur'
                  < v_reserved_end
            and (
              hold.end_at + make_interval(
                mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
              )
            ) at time zone 'Asia/Kuala_Lumpur' > v_start
        )
        + (
          select count(*)
          from jsonb_array_elements(v_results) assigned
          where assigned ->> 'room_id' = room.id::text
        )
      ) < greatest(coalesce(room.total_slots, 1), 1)
    order by room.name, room.id
    limit 1;

    if v_room_id is null then
      return;
    end if;

    v_used_therapists := array_append(v_used_therapists, v_therapist_id);
    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'pax_index', v_pax_index,
        'therapist_id', v_therapist_id,
        'room_id', v_room_id,
        'end_time', v_treatment_end::time
      )
    );
  end loop;

  return query
  select
    (assigned ->> 'pax_index')::integer,
    (assigned ->> 'therapist_id')::uuid,
    (assigned ->> 'room_id')::uuid,
    (assigned ->> 'end_time')::time
  from jsonb_array_elements(v_results) assigned
  order by (assigned ->> 'pax_index')::integer;
end;
$$;


--
-- Name: allocate_provisional_slots(uuid, date, time without time zone, time without time zone, integer, text, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_pax integer, p_room_type text DEFAULT NULL::text, p_buffer_after_minutes integer DEFAULT 0, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(pax_index integer, therapist_id uuid, room_id uuid)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_buffer integer := greatest(coalesce(p_buffer_after_minutes, 0), 0);
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_e timestamp := public.csp_end_at(p_date, p_start_time, p_end_time)
    + make_interval(mins => v_buffer);
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_dow integer := extract(dow from p_date - 1)::integer;
begin
  if p_pax is null or p_pax < 1 then return; end if;

  return query
  with free_therapists as (
    select
      t.id,
      row_number() over (order by t.display_order, t.name, t.id) as rn
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true) = true
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
      and exists (
        select 1 from public.therapist_working_hours wh
        where wh.therapist_id = t.id
          and (
            (
              wh.day_of_week = v_dow
              and p_date + wh.start_time <= v_start
              and p_date + wh.end_time
                + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
                >= v_e
            )
            or (
              wh.end_time <= wh.start_time
              and wh.day_of_week = v_prev_dow
              and (p_date - 1) + wh.start_time <= v_start
              and (p_date - 1) + wh.end_time + interval '1 day' >= v_e
            )
          )
      )
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = t.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_e
          and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start
      )
      and not exists (
        select 1 from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_e
          and public.csp_appointment_block_end_at(a) > v_start
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1 from public.booking_holds hold
        where hold.assigned_therapist_id = t.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_e
          and ((
            hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
          ) at time zone 'Asia/Kuala_Lumpur') > v_start
      )
  ),
  room_capacity as (
    select
      r.id as room_id,
      r.room_type,
      greatest(coalesce(r.total_slots, 1), 1) - (
        (
          select count(*)
          from public.appointments a
          where a.appointment_date::date between p_date - 1 and p_date + 1
            and a.room_id = r.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_e
            and public.csp_appointment_block_end_at(a) > v_start
            and (
              p_exclude_appointment_group_id is null
              or a.appointment_group_id is distinct from p_exclude_appointment_group_id
            )
        )
        + (
          select count(*)
          from public.booking_holds hold
          where hold.assigned_room_id = r.id
            and hold.status = 'pending_payment'
            and hold.expires_at > now()
            and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_e
            and ((
              hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
            ) at time zone 'Asia/Kuala_Lumpur') > v_start
        )
      ) as free_slots
    from public.rooms r
    where r.outlet_id = p_outlet_id
      and (
        p_room_type is null
        or p_room_type = ''
        or lower(coalesce(r.room_type, '')) = lower(p_room_type)
      )
  ),
  room_slots as (
    select
      rc.room_id,
      row_number() over (order by rc.room_type, rc.room_id, gs.n) as rn
    from room_capacity rc
    cross join lateral generate_series(1, greatest(rc.free_slots, 0)) gs(n)
  )
  select ft.rn::integer, ft.id, rs.room_id
  from free_therapists ft
  join room_slots rs on rs.rn = ft.rn
  where ft.rn <= p_pax
  order by ft.rn;
end;
$$;


--
-- Name: allocate_provisional_slots_unfiltered_rooms_legacy(uuid, date, time without time zone, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.allocate_provisional_slots_unfiltered_rooms_legacy(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(pax_index integer, therapist_id uuid, room_id uuid, end_time time without time zone)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_requirement jsonb;
  v_requirement_count integer;
  v_pax_index integer;
  v_duration integer;
  v_buffer integer;
  v_room_type text;
  v_start timestamp := public.csp_start_at(p_date, p_start_time);
  v_treatment_end timestamp;
  v_reserved_end timestamp;
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_dow integer := extract(dow from p_date - 1)::integer;
  v_therapist_id uuid;
  v_room_id uuid;
  v_used_therapists uuid[] := array[]::uuid[];
  v_results jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception using
      errcode = '22023',
      message = 'p_requirements must be a non-empty JSON array.';
  end if;

  v_requirement_count := jsonb_array_length(p_requirements);

  if exists (
    select 1
    from jsonb_array_elements(p_requirements) requirement
    where jsonb_typeof(requirement) is distinct from 'object'
      or coalesce((requirement ->> 'pax_index')::integer, 0) < 1
      or coalesce((requirement ->> 'duration_minutes')::integer, 0) < 1
      or coalesce(nullif(trim(requirement ->> 'room_type'), ''), '') = ''
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every pax requirement needs a positive pax_index, duration_minutes, and room_type.';
  end if;

  if (
    select count(distinct (requirement ->> 'pax_index')::integer)
    from jsonb_array_elements(p_requirements) requirement
  ) <> v_requirement_count then
    raise exception using
      errcode = '22023',
      message = 'Every pax requirement must have a unique pax_index.';
  end if;

  -- Longest reserved windows are allocated first. For a shared start time the
  -- eligible-therapist sets are nested by end time, so this greedy order does
  -- not let a short treatment consume the only therapist who can cover a long
  -- one. Rooms use the same ordering within their independent room types.
  for v_requirement in
    select requirement
    from jsonb_array_elements(p_requirements) requirement
    order by
      coalesce((requirement ->> 'duration_minutes')::integer, 0)
        + greatest(coalesce((requirement ->> 'buffer_after_minutes')::integer, 0), 0) desc,
      (requirement ->> 'pax_index')::integer
  loop
    v_pax_index := (v_requirement ->> 'pax_index')::integer;
    v_duration := (v_requirement ->> 'duration_minutes')::integer;
    v_buffer := greatest(
      coalesce((v_requirement ->> 'buffer_after_minutes')::integer, 0),
      0
    );
    v_room_type := lower(trim(v_requirement ->> 'room_type'));
    v_treatment_end := v_start + make_interval(mins => v_duration);
    v_reserved_end := v_treatment_end + make_interval(mins => v_buffer);

    v_therapist_id := null;
    select therapist.id
    into v_therapist_id
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true) = true
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and not (therapist.id = any(v_used_therapists))
      and exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = therapist.id
          and (
            (
              hours.day_of_week = v_dow
              and p_date + hours.start_time <= v_start
              and p_date + hours.end_time
                + case
                    when hours.end_time <= hours.start_time then interval '1 day'
                    else interval '0'
                  end >= v_reserved_end
            )
            or (
              hours.end_time <= hours.start_time
              and hours.day_of_week = v_prev_dow
              and (p_date - 1) + hours.start_time <= v_start
              and (p_date - 1) + hours.end_time + interval '1 day' >= v_reserved_end
            )
          )
      )
      and not exists (
        select 1
        from public.therapist_unavailability unavailable
        where unavailable.therapist_id = therapist.id
          and (unavailable.starts_at at time zone 'Asia/Kuala_Lumpur') < v_reserved_end
          and (unavailable.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start
      )
      and not exists (
        select 1
        from public.appointments appointment
        where appointment.appointment_date::date between p_date - 1 and p_date + 1
          and appointment.therapist_id = therapist.id
          and public.csp_blocks_schedule(appointment.status::text)
          and public.csp_appointment_start_at(appointment) < v_reserved_end
          and public.csp_appointment_block_end_at(appointment) > v_start
          and (
            p_exclude_appointment_group_id is null
            or appointment.appointment_group_id is distinct from p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1
        from public.booking_holds hold
        where hold.assigned_therapist_id = therapist.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_reserved_end
          and (
            hold.end_at
              + make_interval(
                  mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start
      )
    order by therapist.display_order nulls last, therapist.name, therapist.id
    limit 1;

    if v_therapist_id is null then
      return;
    end if;

    v_room_id := null;
    select room.id
    into v_room_id
    from public.rooms room
    where room.outlet_id = p_outlet_id
      and lower(coalesce(room.room_type::text, '')) = v_room_type
      and (
        (
          select count(*)
          from public.appointments appointment
          where appointment.appointment_date::date between p_date - 1 and p_date + 1
            and appointment.room_id = room.id
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment) < v_reserved_end
            and public.csp_appointment_block_end_at(appointment) > v_start
            and (
              p_exclude_appointment_group_id is null
              or appointment.appointment_group_id is distinct from p_exclude_appointment_group_id
            )
        )
        + (
          select count(*)
          from public.booking_holds hold
          where hold.assigned_room_id = room.id
            and hold.status = 'pending_payment'
            and hold.expires_at > now()
            and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_reserved_end
            and (
              hold.end_at
                + make_interval(
                    mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                  )
            ) at time zone 'Asia/Kuala_Lumpur' > v_start
        )
        + (
          select count(*)
          from jsonb_array_elements(v_results) assigned
          where (assigned ->> 'room_id')::uuid = room.id
        )
      ) < greatest(coalesce(room.total_slots, 1), 1)
    order by room.name, room.id
    limit 1;

    if v_room_id is null then
      return;
    end if;

    v_used_therapists := array_append(v_used_therapists, v_therapist_id);
    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'pax_index', v_pax_index,
        'therapist_id', v_therapist_id,
        'room_id', v_room_id,
        'end_time', v_treatment_end::time
      )
    );
  end loop;

  return query
  select
    (assigned ->> 'pax_index')::integer,
    (assigned ->> 'therapist_id')::uuid,
    (assigned ->> 'room_id')::uuid,
    (assigned ->> 'end_time')::time
  from jsonb_array_elements(v_results) assigned
  order by (assigned ->> 'pax_index')::integer;
end;
$$;


--
-- Name: allocate_specific_room_unit(uuid, timestamp without time zone, timestamp without time zone, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.allocate_specific_room_unit(p_zone_id uuid, p_start_at timestamp without time zone, p_block_end_at timestamp without time zone, p_requested_unit_id uuid DEFAULT NULL::uuid, p_exclude_appointment_id uuid DEFAULT NULL::uuid, p_exclude_hold_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_mode text;
  v_unit_id uuid;
begin
  select allocation_mode into v_mode from public.rooms where id = p_zone_id;
  if coalesce(v_mode, 'capacity') <> 'specific_room' then
    return null;
  end if;
  if p_block_end_at <= p_start_at then
    raise exception using errcode = '22023', message = 'Invalid room reservation window.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('specific-room-zone:' || p_zone_id::text, 0));

  select u.id into v_unit_id
  from public.room_units u
  where u.zone_id = p_zone_id
    and u.is_active
    and (p_requested_unit_id is null or u.id = p_requested_unit_id)
    and not exists (
      select 1 from public.appointments a
      where a.room_unit_id = u.id
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < p_block_end_at
        and public.csp_appointment_block_end_at(a) > p_start_at
        and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    )
    and not exists (
      select 1 from public.booking_holds h
      where h.assigned_room_unit_id = u.id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < p_block_end_at
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
          at time zone 'Asia/Kuala_Lumpur') > p_start_at
        and (p_exclude_hold_id is null or h.id <> p_exclude_hold_id)
    )
  order by case when p_requested_unit_id is not null then 0 else random() end,
           u.unit_number
  for update of u skip locked
  limit 1;

  if v_unit_id is null then
    if p_requested_unit_id is null then
      raise exception using errcode = 'P0001', message = 'No massage room is available for that service and cleanup window.';
    end if;
    raise exception using errcode = 'P0001', message = 'The selected massage room is occupied or cleaning during that time.';
  end if;
  return v_unit_id;
end;
$$;


--
-- Name: apply_appointment_service_buffer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_appointment_service_buffer() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  select coalesce(buffer_after_minutes, 0)
  into new.buffer_after_minutes
  from public.services
  where id = new.service_id;

  new.buffer_after_minutes := coalesce(new.buffer_after_minutes, 0);
  return new;
end;
$$;


--
-- Name: appointment_addon_minutes(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.appointment_addon_minutes(p_appointment_id uuid) RETURNS integer
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce(sum(greatest(coalesce(s.duration, 0), 0)), 0)::integer
  from public.transactions t
  cross join lateral jsonb_array_elements(coalesce(t.service_items, '[]'::jsonb)) it
  join public.services s
    on s.id = nullif(coalesce(it.value ->> 'id', it.value ->> 'serviceId'), '')::uuid
  where t.appointment_id = p_appointment_id
    and t.source = 'appointment_addon'
    and t.payment_status = 'paid';
$$;


--
-- Name: assign_appointment_room_unit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_appointment_room_unit() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_start timestamp;
  v_block_end timestamp;
  v_hold_id uuid;
begin
  if new.room_id is null then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;

  if (select allocation_mode from public.rooms where id = new.room_id)
       <> 'specific_room' then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;

  if new.actual_started_at is not null
     and lower(coalesce(new.status::text, '')) = 'in_progress' then
    v_start := new.actual_started_at at time zone 'Asia/Kuala_Lumpur';
    v_block_end := greatest(
      new.end_at,
      v_start + make_interval(mins => 1)
    ) + make_interval(
      mins => greatest(
        coalesce(new.buffer_after_minutes, 0),
        0
      )
    );
  else
    v_start := public.csp_start_at(new.appointment_date, new.start_time);
    v_block_end := public.csp_end_at(
      new.appointment_date,
      new.start_time,
      new.end_time
    ) + make_interval(
      mins => greatest(coalesce(new.buffer_after_minutes, 0), 0)
    );
  end if;

  if new.room_unit_id is null then
    select h.id, h.assigned_room_unit_id
    into v_hold_id, new.room_unit_id
    from public.booking_holds h
    where h.assigned_room_id = new.room_id
      and h.assigned_therapist_id = new.therapist_id
      and h.assigned_room_unit_id is not null
      and h.status not in ('expired', 'cancelled', 'failed')
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') = v_start
    order by h.updated_at desc nulls last, h.created_at desc
    limit 1;
  end if;

  new.room_unit_id := public.allocate_specific_room_unit(
    new.room_id,
    v_start,
    v_block_end,
    new.room_unit_id,
    new.id,
    v_hold_id
  );
  select u.name
  into new.room_unit_name
  from public.room_units u
  where u.id = new.room_unit_id;
  return new;
end;
$$;


--
-- Name: assign_booking_hold_room_unit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_booking_hold_room_unit() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.assigned_room_id is null or new.status <> 'pending_payment' then
    return new;
  end if;
  if (select allocation_mode from public.rooms where id = new.assigned_room_id) <> 'specific_room' then
    new.assigned_room_unit_id := null;
    return new;
  end if;
  new.assigned_room_unit_id := public.allocate_specific_room_unit(
    new.assigned_room_id,
    new.start_at at time zone 'Asia/Kuala_Lumpur',
    (new.end_at + make_interval(mins => greatest(coalesce(new.buffer_after_minutes, 0), 0)))
      at time zone 'Asia/Kuala_Lumpur',
    new.assigned_room_unit_id,
    null,
    new.id
  );
  return new;
end;
$$;


--
-- Name: assignment_reconcile_retry_delay(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assignment_reconcile_retry_delay(p_attempt_count integer) RETURNS interval
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
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


--
-- Name: automatic_therapist_queue_starter(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.automatic_therapist_queue_starter(p_outlet_id uuid, p_date date) RETURNS uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_day_of_week integer := extract(dow from p_date)::integer;
  v_previous_order integer := -1;
  v_starter_id uuid;
begin
  select coalesce(therapist.display_order, -1)
  into v_previous_order
  from public.therapist_queue_day previous_day
  left join public.therapists therapist
    on therapist.id = previous_day.starter_therapist_id
  where previous_day.outlet_id = p_outlet_id
    and previous_day.queue_date < p_date
  order by previous_day.queue_date desc
  limit 1;

  if not found then v_previous_order := -1; end if;

  select therapist.id
  into v_starter_id
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and therapist.display_order > v_previous_order
    and exists (
      select 1
      from public.therapist_working_hours working_hours
      join public.business_hours outlet_hours
        on outlet_hours.outlet_id = therapist.outlet_id
       and outlet_hours.day_of_week = working_hours.day_of_week
       and not coalesce(outlet_hours.is_closed, false)
      where working_hours.therapist_id = therapist.id
        and working_hours.day_of_week = v_day_of_week
    )
  order by therapist.display_order, therapist.name
  limit 1;

  if v_starter_id is null then
    select therapist.id
    into v_starter_id
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and exists (
        select 1
        from public.therapist_working_hours working_hours
        join public.business_hours outlet_hours
          on outlet_hours.outlet_id = therapist.outlet_id
         and outlet_hours.day_of_week = working_hours.day_of_week
         and not coalesce(outlet_hours.is_closed, false)
        where working_hours.therapist_id = therapist.id
          and working_hours.day_of_week = v_day_of_week
      )
    order by therapist.display_order, therapist.name
    limit 1;
  end if;

  return v_starter_id;
end;
$$;


--
-- Name: begin_business_hours_staff_sync(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.begin_business_hours_staff_sync() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform set_config('app.business_hours_sync', '1', true);
  return new;
end;
$$;


--
-- Name: can_manage_app_images(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_manage_app_images() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and lower(p.role::text) in ('admin', 'staff')
  )
$$;


--
-- Name: cancel_appointment(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancel_appointment(p_appointment_id uuid, p_reason text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_a public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, 'NOT_FOUND','Appointment was not found.'; return;
  end if;
  if v_a.status::text = 'completed' then
    return query select false, p_appointment_id, 'ALREADY_COMPLETED',
      'A completed service cannot be cancelled.'; return;
  end if;
  -- Idempotent.
  if v_a.status::text in ('cancelled','canceled') then
    return query select true, p_appointment_id, null::text, null::text; return;
  end if;
  if v_a.actual_started_at is not null or v_a.status::text = 'in_progress' then
    return query select false, p_appointment_id, 'ALREADY_STARTED',
      'A started service cannot be cancelled; complete it or mark it no-show.'; return;
  end if;

  -- Capacity is released by the status change alone: csp_blocks_schedule
  -- ('cancelled') is false, so every availability query, the overlap trigger and
  -- capacity_feasible stop counting this row (verified: therapist flipped
  -- busy -> free_now). therapist_id / room_id / room_unit_id are deliberately
  -- RETAINED as the record of what was held; clearing them would destroy audit
  -- history and, because normalize_appointment_assignment_states forces both
  -- states to 'confirmed' for terminal rows, would trip CHECK
  -- appointments_confirmed_room_concrete.
  --
  -- Payment history is untouched. The therapist queue is untouched: consumption
  -- is bound to the actual_started_at transition, which cancellation never makes.
  update public.appointments a
  set status = 'cancelled',
      cancelled_at = now(), cancelled_by = auth.uid(),
      cancellation_reason = nullif(p_reason,''),
      updated_at = now()
  where a.id = p_appointment_id;

  return query select true, p_appointment_id, null::text, null::text;
end;
$$;


--
-- Name: cancel_appointment_group(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancel_appointment_group(p_group_id uuid, p_reason text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, cancelled_count integer, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_g public.appointment_groups%rowtype; v_a public.appointments%rowtype;
  v_id uuid; v_n int := 0; v_ids uuid[] := array[]::uuid[];
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_g from public.appointment_groups where id = p_group_id for update;
  if not found then
    return query select false, p_group_id, 0, 'NOT_FOUND','Group was not found.'; return;
  end if;

  -- Validate every pax before cancelling any, so the group never ends up half
  -- cancelled.
  for v_id in select a.id from public.appointments a
              where a.appointment_group_id = p_group_id order by a.id
  loop
    select * into v_a from public.appointments where id = v_id for update;
    v_ids := array_append(v_ids, v_id);
    if v_a.status::text in ('cancelled','canceled') then continue; end if;
    if v_a.status::text = 'completed' then
      return query select false, p_group_id, 0, 'ALREADY_COMPLETED',
        format('Pax %s is completed.', v_id); return;
    end if;
    if v_a.actual_started_at is not null or v_a.status::text = 'in_progress' then
      return query select false, p_group_id, 0, 'ALREADY_STARTED',
        format('Pax %s has already started.', v_id); return;
    end if;
  end loop;

  if array_length(v_ids,1) is null then
    return query select false, p_group_id, 0, 'EMPTY_GROUP','The group has no pax.'; return;
  end if;

  foreach v_id in array v_ids loop
    select * into v_a from public.appointments where id = v_id;
    if v_a.status::text not in ('cancelled','canceled') then
      update public.appointments
      set status='cancelled', cancelled_at=now(), cancelled_by=auth.uid(),
          cancellation_reason=nullif(p_reason,''), updated_at=now()
      where id = v_id;
      v_n := v_n + 1;
    end if;
  end loop;

  update public.appointment_groups set status='cancelled'
  where id = p_group_id and coalesce(status,'') is distinct from 'cancelled';

  return query select true, p_group_id, v_n, null::text, null::text;
end;
$$;


--
-- Name: capacity_bipartite_saturates(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capacity_bipartite_saturates(p_adjacency jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
declare v_d text; v_m jsonb := '{}'::jsonb; v_res jsonb;
begin
  if p_adjacency is null then return true; end if;
  for v_d in select jsonb_object_keys(p_adjacency) loop
    v_res := public.capacity_kuhn_augment(v_d, p_adjacency, v_m, '{}'::jsonb);
    if not (v_res ->> 'ok')::boolean then return false; end if;
    v_m := v_res -> 'match';
  end loop;
  return true;
end;
$$;


--
-- Name: capacity_feasible(uuid, jsonb, text, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capacity_feasible(p_outlet_id uuid, p_demands jsonb, p_mode text DEFAULT 'hard'::text, p_exclude_appointment_id uuid DEFAULT NULL::uuid, p_exclude_group_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
declare
  v_base jsonb;
  v_min timestamp;
  v_max timestamp;
  v_now timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_points timestamp[];
  v_point timestamp;
  v_room_type text;
  v_slots integer;
  v_proposed integer;
  v_concrete_appointments integer;
  v_anonymous_appointments integer;
  v_concrete_holds integer;
  v_anonymous_holds integer;
  v_total_demand integer;
begin
  v_base := public.capacity_feasible_119b_legacy(
    p_outlet_id, p_demands, p_mode, p_exclude_appointment_id, p_exclude_group_id
  );

  if not coalesce((v_base ->> 'feasible')::boolean, false) then
    return v_base;
  end if;

  if p_demands is null
     or jsonb_typeof(p_demands) is distinct from 'array'
     or jsonb_array_length(p_demands) = 0 then
    return v_base;
  end if;

  select
    min((d ->> 'start')::timestamp),
    max(
      (d ->> 'start')::timestamp
      + make_interval(
          mins => (d ->> 'duration_minutes')::integer
                  + greatest(coalesce((d ->> 'buffer_after_minutes')::integer, 0), 0)
        )
    )
  into v_min, v_max
  from jsonb_array_elements(p_demands) d;

  if v_min is null or v_max is null or v_max <= v_min then
    return v_base;
  end if;

  select array_agg(distinct point order by point)
  into v_points
  from (
    select (d ->> 'start')::timestamp as point
    from jsonb_array_elements(p_demands) d

    union
    select (d ->> 'start')::timestamp
           + make_interval(mins => (d ->> 'duration_minutes')::integer)
    from jsonb_array_elements(p_demands) d

    union
    select (d ->> 'start')::timestamp
           + make_interval(
               mins => (d ->> 'duration_minutes')::integer
                       + greatest(coalesce((d ->> 'buffer_after_minutes')::integer, 0), 0)
             )
    from jsonb_array_elements(p_demands) d

    union
    select public.csp_appointment_start_at(a)
    from public.appointments a
    where a.outlet_id = p_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.id is distinct from p_exclude_appointment_id
      and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
      and public.csp_appointment_start_at(a) < v_max
      and public.csp_appointment_block_end_at(a) > v_min

    union
    select public.csp_appointment_block_end_at(a)
    from public.appointments a
    where a.outlet_id = p_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.id is distinct from p_exclude_appointment_id
      and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
      and public.csp_appointment_start_at(a) < v_max
      and public.csp_appointment_block_end_at(a) > v_min

    union
    select h.start_at at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    where h.outlet_id = p_outlet_id
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_max
      and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
            at time zone 'Asia/Kuala_Lumpur') > v_min

    union
    select (h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
             at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    where h.outlet_id = p_outlet_id
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_max
      and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
            at time zone 'Asia/Kuala_Lumpur') > v_min
  ) boundaries
  where point >= greatest(v_min, v_now)
    and point < v_max;

  if v_points is null then
    v_points := array[greatest(v_min, v_now)];
  end if;

  foreach v_point in array v_points loop
    for v_room_type in
      select distinct lower(trim(d ->> 'room_type'))
      from jsonb_array_elements(p_demands) d
      where nullif(lower(trim(d ->> 'room_type')), '') is not null
        and (d ->> 'start')::timestamp <= v_point
        and ((d ->> 'start')::timestamp
             + make_interval(
                 mins => (d ->> 'duration_minutes')::integer
                         + greatest(coalesce((d ->> 'buffer_after_minutes')::integer, 0), 0)
               )) > v_point
    loop
      select coalesce(sum(greatest(coalesce(r.total_slots, 1), 1)), 0)
      into v_slots
      from public.rooms r
      where r.outlet_id = p_outlet_id
        and coalesce(r.is_active, true)
        and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type;

      select count(*)
      into v_proposed
      from jsonb_array_elements(p_demands) d
      where lower(trim(d ->> 'room_type')) = v_room_type
        and (d ->> 'start')::timestamp <= v_point
        and ((d ->> 'start')::timestamp
             + make_interval(
                 mins => (d ->> 'duration_minutes')::integer
                         + greatest(coalesce((d ->> 'buffer_after_minutes')::integer, 0), 0)
               )) > v_point;

      select count(*)
      into v_concrete_appointments
      from public.appointments a
      join public.rooms r on r.id = a.room_id
      where a.outlet_id = p_outlet_id
        and a.room_id is not null
        and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) <= v_point
        and public.csp_appointment_block_end_at(a) > v_point
        and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type;

      select count(*)
      into v_anonymous_appointments
      from public.appointments a
      join public.services s on s.id = a.service_id
      where a.outlet_id = p_outlet_id
        and a.room_id is null
        and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) <= v_point
        and public.csp_appointment_block_end_at(a) > v_point
        and lower(trim(s.room_type::text)) = v_room_type;

      select count(*)
      into v_concrete_holds
      from public.booking_holds h
      join public.rooms r on r.id = h.assigned_room_id
      where h.outlet_id = p_outlet_id
        and h.assigned_room_id is not null
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= v_point
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_point
        and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type;

      select count(*)
      into v_anonymous_holds
      from public.booking_holds h
      join public.online_booking_services obs on obs.id = h.online_booking_service_id
      join public.services s on s.id = obs.service_id
      where h.outlet_id = p_outlet_id
        and h.assigned_room_id is null
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= v_point
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_point
        and lower(trim(s.room_type::text)) = v_room_type;

      v_total_demand :=
        coalesce(v_proposed, 0)
        + coalesce(v_concrete_appointments, 0)
        + coalesce(v_anonymous_appointments, 0)
        + coalesce(v_concrete_holds, 0)
        + coalesce(v_anonymous_holds, 0);

      if v_total_demand > coalesce(v_slots, 0) then
        return jsonb_build_object(
          'feasible', false,
          'mode', p_mode,
          'dimension', 'room',
          'at', v_point,
          'room_type', v_room_type,
          'required_slots', v_total_demand,
          'available_slots', coalesce(v_slots, 0)
        );
      end if;
    end loop;
  end loop;

  return v_base;
end;
$$;


--
-- Name: capacity_feasible_119b_legacy(uuid, jsonb, text, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capacity_feasible_119b_legacy(p_outlet_id uuid, p_demands jsonb, p_mode text DEFAULT 'hard'::text, p_exclude_appointment_id uuid DEFAULT NULL::uuid, p_exclude_group_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_min timestamp; v_max timestamp; v_now timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_points timestamp[]; c timestamp; v_supply text[]; v_adjacency jsonb; v_demand jsonb;
  v_key text; v_eligible text[]; v_rt text; v_needed integer; v_slots integer; v_used integer;
begin
  if p_demands is null or jsonb_array_length(p_demands) = 0 then
    return jsonb_build_object('feasible', true, 'mode', p_mode); end if;

  select min((d ->> 'start')::timestamp),
    max((d ->> 'start')::timestamp + make_interval(mins => (d ->> 'duration_minutes')::int
            + greatest(coalesce((d ->> 'buffer_after_minutes')::int, 0), 0)))
  into v_min, v_max from jsonb_array_elements(p_demands) d;

  select array_agg(distinct pt order by pt) into v_points from (
    select (d ->> 'start')::timestamp as pt from jsonb_array_elements(p_demands) d
    union select (d ->> 'start')::timestamp + make_interval(mins => (d ->> 'duration_minutes')::int) from jsonb_array_elements(p_demands) d
    union select (d ->> 'start')::timestamp + make_interval(mins => (d ->> 'duration_minutes')::int
             + greatest(coalesce((d ->> 'buffer_after_minutes')::int, 0), 0)) from jsonb_array_elements(p_demands) d
    union select public.csp_appointment_start_at(a) from public.appointments a
      where a.outlet_id = p_outlet_id and public.csp_blocks_schedule(a.status::text)
        and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_appointment_start_at(a) < v_max and public.csp_appointment_block_end_at(a) > v_min
    union select public.csp_appointment_block_end_at(a) from public.appointments a
      where a.outlet_id = p_outlet_id and public.csp_blocks_schedule(a.status::text)
        and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_appointment_start_at(a) < v_max and public.csp_appointment_block_end_at(a) > v_min
    union select (h.start_at at time zone 'Asia/Kuala_Lumpur') from public.booking_holds h
      where h.outlet_id = p_outlet_id and h.status = 'pending_payment' and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_max
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes,0),0))) at time zone 'Asia/Kuala_Lumpur') > v_min
    union select ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes,0),0))) at time zone 'Asia/Kuala_Lumpur')
      from public.booking_holds h where h.outlet_id = p_outlet_id and h.status = 'pending_payment' and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_max
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes,0),0))) at time zone 'Asia/Kuala_Lumpur') > v_min
    union select gs.d + wh.start_time from generate_series(v_min::date - 1, v_max::date, interval '1 day') gs(d)
      join public.therapists th on th.outlet_id = p_outlet_id and coalesce(th.availability_status,true) and lower(coalesce(th.role,'therapist'))='therapist'
      join public.therapist_working_hours wh on wh.therapist_id = th.id and wh.day_of_week = extract(dow from gs.d)::int
    union select gs.d + wh.end_time + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
      from generate_series(v_min::date - 1, v_max::date, interval '1 day') gs(d)
      join public.therapists th on th.outlet_id = p_outlet_id and coalesce(th.availability_status,true) and lower(coalesce(th.role,'therapist'))='therapist'
      join public.therapist_working_hours wh on wh.therapist_id = th.id and wh.day_of_week = extract(dow from gs.d)::int
    union select (u.starts_at at time zone 'Asia/Kuala_Lumpur') from public.therapist_unavailability u
      join public.therapists th on th.id = u.therapist_id and th.outlet_id = p_outlet_id
      where (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_max and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_min
    union select (u.ends_at at time zone 'Asia/Kuala_Lumpur') from public.therapist_unavailability u
      join public.therapists th on th.id = u.therapist_id and th.outlet_id = p_outlet_id
      where (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_max and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_min
  ) pts where pt >= greatest(v_min, v_now) and pt < v_max;

  if v_points is null then v_points := array[greatest(v_min, v_now)]; end if;

  foreach c in array v_points loop
    select array_agg(th.id::text) into v_supply from public.therapists th
    where th.outlet_id = p_outlet_id and coalesce(th.availability_status,true) and lower(coalesce(th.role,'therapist'))='therapist'
      and exists (select 1 from public.therapist_working_hours wh where wh.therapist_id = th.id and (
          (wh.day_of_week = extract(dow from c::date)::int and c::date + wh.start_time <= c
           and c::date + wh.end_time + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end > c)
          or (wh.end_time <= wh.start_time and wh.day_of_week = extract(dow from c::date - 1)::int
              and (c::date - 1) + wh.start_time <= c and (c::date - 1) + wh.end_time + interval '1 day' > c)))
      and not exists (select 1 from public.therapist_unavailability u where u.therapist_id = th.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') <= c and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > c)
      and not exists (select 1 from public.appointments a where a.therapist_id = th.id
          and a.id is distinct from p_exclude_appointment_id
          and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) <= c and public.csp_appointment_block_end_at(a) > c)
      and not exists (select 1 from public.booking_holds h where h.assigned_therapist_id = th.id
          and h.status = 'pending_payment' and h.expires_at > now() and coalesce(h.hold_kind,'') <> 'staff_walkin_draft'
          and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= c
          and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes,0),0))) at time zone 'Asia/Kuala_Lumpur') > c);
    v_supply := coalesce(v_supply, array[]::text[]);
    v_adjacency := '{}'::jsonb;

    for v_demand in select * from jsonb_array_elements(p_demands) loop
      if (v_demand ->> 'start')::timestamp <= c
         and (v_demand ->> 'start')::timestamp + make_interval(mins => (v_demand ->> 'duration_minutes')::int
             + greatest(coalesce((v_demand ->> 'buffer_after_minutes')::int,0),0)) > c then
        v_key := 'p' || (v_demand ->> 'pax_index');
        select array_agg(t) into v_eligible from unnest(v_supply) t join public.therapists th on th.id = t::uuid
        where (v_demand ->> 'requested_gender' is null or lower(th.gender) = lower(v_demand ->> 'requested_gender'))
          and (th.service_commissions = '{}'::jsonb or th.service_commissions ? (v_demand ->> 'service_id'))
          and (v_demand ->> 'requested_therapist_id' is null or th.id = (v_demand ->> 'requested_therapist_id')::uuid)
          and (v_demand ->> 'manual_lock_id' is null or th.id = (v_demand ->> 'manual_lock_id')::uuid);
        v_adjacency := v_adjacency || jsonb_build_object(v_key, to_jsonb(coalesce(v_eligible, array[]::text[])));
      end if;
    end loop;

    -- anonymous existing appointments (FIX: build jsonb explicitly)
    for v_demand in
      select jsonb_build_object('id', a.id::text, 'service_id', a.service_id::text,
               'requested_gender', a.requested_gender, 'requested_therapist_id', a.requested_therapist_id::text) as j
      from public.appointments a
      where a.outlet_id = p_outlet_id and a.therapist_id is null and a.actual_started_at is null
        and public.csp_blocks_schedule(a.status::text) and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_appointment_start_at(a) <= c and public.csp_appointment_block_end_at(a) > c
    loop
      v_key := 'a' || (v_demand ->> 'id');
      select array_agg(t) into v_eligible from unnest(v_supply) t join public.therapists th on th.id = t::uuid
      where (v_demand ->> 'requested_gender' is null or lower(th.gender) = lower(v_demand ->> 'requested_gender'))
        and (th.service_commissions = '{}'::jsonb or th.service_commissions ? (v_demand ->> 'service_id'))
        and (v_demand ->> 'requested_therapist_id' is null or th.id = (v_demand ->> 'requested_therapist_id')::uuid);
      v_adjacency := v_adjacency || jsonb_build_object(v_key, to_jsonb(coalesce(v_eligible, array[]::text[])));
    end loop;

    -- anonymous holds (FIX: build jsonb explicitly)
    for v_demand in
      select jsonb_build_object('id', h.id::text, 'therapist_preference', h.therapist_preference) as j
      from public.booking_holds h
      where h.outlet_id = p_outlet_id and h.assigned_therapist_id is null
        and h.status = 'pending_payment' and h.expires_at > now() and coalesce(h.hold_kind,'') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= c
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes,0),0))) at time zone 'Asia/Kuala_Lumpur') > c
    loop
      v_key := 'h' || (v_demand ->> 'id');
      select array_agg(t) into v_eligible from unnest(v_supply) t join public.therapists th on th.id = t::uuid
      where (v_demand ->> 'therapist_preference' is null or v_demand ->> 'therapist_preference' in ('none','specific')
             or lower(th.gender) = lower(v_demand ->> 'therapist_preference'));
      v_adjacency := v_adjacency || jsonb_build_object(v_key, to_jsonb(coalesce(v_eligible, array[]::text[])));
    end loop;

    if jsonb_typeof(v_adjacency) = 'object' and (select count(*) from jsonb_object_keys(v_adjacency)) > 0
       and not public.capacity_bipartite_saturates(v_adjacency) then
      return jsonb_build_object('feasible', false, 'mode', p_mode, 'dimension', 'therapist', 'at', c, 'room_type', null);
    end if;

    for v_rt in select distinct lower(trim(d ->> 'room_type')) from jsonb_array_elements(p_demands) d
      where (d ->> 'start')::timestamp <= c
        and (d ->> 'start')::timestamp + make_interval(mins => (d ->> 'duration_minutes')::int
            + greatest(coalesce((d ->> 'buffer_after_minutes')::int,0),0)) > c
    loop
      select count(*) into v_needed from jsonb_array_elements(p_demands) d
      where lower(trim(d ->> 'room_type')) = v_rt and (d ->> 'start')::timestamp <= c
        and (d ->> 'start')::timestamp + make_interval(mins => (d ->> 'duration_minutes')::int
            + greatest(coalesce((d ->> 'buffer_after_minutes')::int,0),0)) > c;
      select coalesce(sum(greatest(coalesce(r.total_slots,1),1)),0) into v_slots from public.rooms r
        where r.outlet_id = p_outlet_id and coalesce(r.is_active,true) and lower(coalesce(r.room_type::text,'')) = v_rt;
      v_used := (select count(*) from public.appointments a join public.rooms r on r.id = a.room_id
        where a.room_id is not null and r.outlet_id = p_outlet_id and lower(coalesce(r.room_type::text,'')) = v_rt
          and a.id is distinct from p_exclude_appointment_id
          and (p_exclude_group_id is null or a.appointment_group_id is distinct from p_exclude_group_id)
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) <= c and public.csp_appointment_block_end_at(a) > c
      ) + (select count(*) from public.booking_holds h join public.rooms r on r.id = h.assigned_room_id
        where h.assigned_room_id is not null and r.outlet_id = p_outlet_id and lower(coalesce(r.room_type::text,'')) = v_rt
          and h.status = 'pending_payment' and h.expires_at > now() and coalesce(h.hold_kind,'') <> 'staff_walkin_draft'
          and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= c
          and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes,0),0))) at time zone 'Asia/Kuala_Lumpur') > c);
      if v_used + v_needed > v_slots then
        return jsonb_build_object('feasible', false, 'mode', p_mode, 'dimension', 'room', 'at', c, 'room_type', v_rt);
      end if;
    end loop;
  end loop;
  return jsonb_build_object('feasible', true, 'mode', p_mode, 'dimension', null, 'at', null, 'room_type', null);
end;
$$;


--
-- Name: FUNCTION capacity_feasible_119b_legacy(p_outlet_id uuid, p_demands jsonb, p_mode text, p_exclude_appointment_id uuid, p_exclude_group_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.capacity_feasible_119b_legacy(p_outlet_id uuid, p_demands jsonb, p_mode text, p_exclude_appointment_id uuid, p_exclude_group_id uuid) IS 'Project B SHADOW engine (migration 119): interval-exact, read-only capacity feasibility with exact bipartite therapist matching + per-room_type slot capacity. Wired to nothing; validate before use.';


--
-- Name: capacity_first_enabled(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capacity_first_enabled(p_outlet_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((select bs.capacity_first_enabled from public.business_settings bs
      where bs.outlet_id = p_outlet_id limit 1), false);
$$;


--
-- Name: capacity_kuhn_augment(text, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capacity_kuhn_augment(p_demand text, p_adjacency jsonb, p_match jsonb, p_visited jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $$
declare
  v_t text; v_m jsonb := p_match; v_vis jsonb := p_visited; v_res jsonb;
begin
  for v_t in select jsonb_array_elements_text(coalesce(p_adjacency -> p_demand, '[]'::jsonb)) loop
    if v_vis ? v_t then continue; end if;
    v_vis := v_vis || jsonb_build_object(v_t, true);
    if not (v_m ? v_t) then
      v_m := v_m || jsonb_build_object(v_t, p_demand);
      return jsonb_build_object('ok', true, 'match', v_m, 'visited', v_vis);
    else
      v_res := public.capacity_kuhn_augment(v_m ->> v_t, p_adjacency, v_m, v_vis);
      v_vis := v_res -> 'visited';
      if (v_res ->> 'ok')::boolean then
        v_m := v_res -> 'match';
        v_m := v_m || jsonb_build_object(v_t, p_demand);
        return jsonb_build_object('ok', true, 'match', v_m, 'visited', v_vis);
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', false, 'match', v_m, 'visited', v_vis);
end;
$$;


--
-- Name: change_today_queue_starter(uuid, date, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.change_today_queue_starter(p_outlet_id uuid, p_date date, p_starter_therapist_id uuid, p_reason text DEFAULT NULL::text, p_confirm_reset boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_first_turn timestamptz;
  v_now_time time := (now() at time zone 'Asia/Kuala_Lumpur')::time;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = '22023',
      message = 'Only today''s live queue can be changed.';
  end if;
  if char_length(coalesce(p_reason, '')) > 500 then
    raise exception using errcode = '22023',
      message = 'Reason must be 500 characters or fewer.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  if not exists (
    select 1
    from public.get_therapist_queue(
      p_outlet_id, p_date, v_now_time, 1
    ) live_queue
    where live_queue.therapist_id = p_starter_therapist_id
  ) then
    raise exception using errcode = '22023',
      message = 'Choose an active therapist who is currently scheduled and on shift.';
  end if;

  v_first_turn := public.today_queue_has_started(p_outlet_id, p_date);
  if v_first_turn is not null and not p_confirm_reset then
    raise exception using errcode = 'P0001',
      message = 'RESET_CONFIRMATION_REQUIRED';
  end if;

  update public.therapist_queue_day
  set starter_therapist_id = p_starter_therapist_id,
      is_manual_override = true,
      changed_by = auth.uid(),
      changed_at = now(),
      override_reason = nullif(btrim(p_reason), '')
  where outlet_id = p_outlet_id and queue_date = p_date;

  perform public.rebuild_therapist_queue_from_starter(
    p_outlet_id, p_date, p_starter_therapist_id
  );
end;
$$;


--
-- Name: check_booking_availability(date, time without time zone, time without time zone, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_booking_availability(p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_exclude_appointment_id uuid DEFAULT NULL::uuid, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(therapist_available boolean, therapist_busy_until time without time zone, room_total_slots integer, room_booked_slots integer, room_available_slots integer, room_full boolean, room_full_until time without time zone)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_start_at timestamp := public.csp_start_at(p_date, p_start_time);
  v_end_at timestamp := public.csp_end_at(p_date, p_start_time, p_end_time);
  v_therapist_conflicts integer := 0;
  v_room_conflicts integer := 0;
  v_therapist_hold_conflicts integer := 0;
  v_room_hold_conflicts integer := 0;
  v_room_total integer := 1;
  v_therapist_busy_until time;
  v_room_busy_until time;
  v_within_hours boolean := true;
  v_leave_conflicts integer := 0;
  v_leave_until time;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  -- Working hours: schedules are seeded for every therapist/day (026), so a
  -- missing day means the therapist is off; split shifts mean the whole
  -- requested window must fit inside one shift (the gap between shifts is a
  -- break). A close at/before the open time means the shift runs past
  -- midnight (074 semantics).
  select exists (
    select 1
    from public.therapist_working_hours wh
    where wh.therapist_id = p_therapist_id
      and (
        (
          wh.day_of_week = extract(dow from p_date)::integer
          and p_date + wh.start_time <= v_start_at
          and p_date + wh.end_time
            + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
            >= v_end_at
        )
        or (
          -- An early-morning calendar slot can belong to the previous day's
          -- overnight shift (for example Sunday 21:00 through Monday 02:00).
          wh.end_time <= wh.start_time
          and wh.day_of_week = extract(dow from p_date - 1)::integer
          and (p_date - 1) + wh.start_time <= v_start_at
          and (p_date - 1) + wh.end_time + interval '1 day' >= v_end_at
        )
      )
  ) into v_within_hours;

  -- Leave / blocked time (stored as timestamptz; appointments use naive
  -- Asia/Kuala_Lumpur wall time, so compare on the same clock).
  select count(*), max((u.ends_at at time zone 'Asia/Kuala_Lumpur')::time)
  into v_leave_conflicts, v_leave_until
  from public.therapist_unavailability u
  where u.therapist_id = p_therapist_id
    and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  -- Existing appointments (blocked through their own cleanup buffer).
  select count(*), max(public.csp_appointment_block_end_at(a)::time)
  into v_therapist_conflicts, v_therapist_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_block_end_at(a) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (
      p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id
    );

  select count(*), max(public.csp_appointment_block_end_at(a)::time)
  into v_room_conflicts, v_room_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_block_end_at(a) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (
      p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id
    );

  -- Pending online booking holds (mirror of the enforcement trigger).
  select count(*)
  into v_therapist_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_therapist_id = p_therapist_id
    and hold.status = 'pending_payment'
    and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
    ) at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  select count(*)
  into v_room_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_room_id = p_room_id
    and hold.status = 'pending_payment'
    and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
    ) at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  v_therapist_conflicts := v_therapist_conflicts + coalesce(v_therapist_hold_conflicts, 0);
  v_room_conflicts := v_room_conflicts + coalesce(v_room_hold_conflicts, 0);

  therapist_available := v_therapist_conflicts = 0
    and v_leave_conflicts = 0
    and v_within_hours;
  therapist_busy_until := coalesce(v_therapist_busy_until, v_leave_until);
  room_total_slots := v_room_total;
  room_booked_slots := v_room_conflicts;
  room_available_slots := greatest(v_room_total - v_room_conflicts, 0);
  room_full := v_room_conflicts >= v_room_total;
  room_full_until := case when room_full then v_room_busy_until else null end;
  return next;
end;
$$;


--
-- Name: check_in_appointment(uuid, jsonb, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_in_appointment(p_appointment_id uuid, p_addon_service_items jsonb DEFAULT '[]'::jsonb, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, checked_in_at timestamp with time zone, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_a public.appointments%rowtype; v_c public.customers%rowtype;
  v_first jsonb; v_sid uuid; v_snm text; v_tnm text := ''; v_rnm text := '';
  v_txn uuid; v_pay boolean;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, null::uuid, null::timestamptz,
      'NOT_FOUND','Appointment was not found.'; return;
  end if;
  if v_a.actual_started_at is not null then
    return query select false, p_appointment_id, null::uuid, v_a.checked_in_at,
      'ALREADY_STARTED','The service has already started.'; return;
  end if;
  if v_a.status::text not in ('pending','confirmed') then
    return query select false, p_appointment_id, null::uuid, v_a.checked_in_at,
      'NOT_CHECKABLE','Only a pending or confirmed appointment can be checked in.'; return;
  end if;
  if v_a.appointment_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    return query select false, p_appointment_id, null::uuid, v_a.checked_in_at,
      'WRONG_DATE','Check-in is only allowed on the appointment date.'; return;
  end if;

  v_pay := jsonb_array_length(coalesce(p_addon_service_items,'[]'::jsonb)) > 0
           and coalesce(p_total_amount,0) > 0;

  -- Idempotent: a repeated check-in never re-stamps and never re-charges.
  if v_a.checked_in_at is not null then
    select t.id into v_txn from public.transactions t
    where t.appointment_id = p_appointment_id and t.source = 'appointment_addon'
    order by t.created_at desc limit 1;
    return query select true, p_appointment_id, v_txn, v_a.checked_in_at,
      null::text, null::text; return;
  end if;

  -- The SET list deliberately excludes actual_started_at, status, start_at,
  -- end_at, start_time and end_time, so no schedule trigger fires and the
  -- operational window cannot move.
  update public.appointments a
  set checked_in_at = now(), checked_in_by = auth.uid(), updated_at = now()
  where a.id = p_appointment_id returning * into v_a;

  if v_pay then
    select * into v_c from public.customers where id = v_a.customer_id;
    select coalesce(name,'') into v_tnm from public.therapists where id = v_a.therapist_id;
    select coalesce(name,'') into v_rnm from public.rooms where id = v_a.room_id;
    v_first := p_addon_service_items -> 0;
    v_sid := nullif(coalesce(v_first->>'id', v_first->>'serviceId'),'')::uuid;
    v_snm := coalesce(v_first->>'name','Service add-on');
    insert into public.transactions (
      outlet_id, appointment_id, customer_id, customer_name, customer_phone,
      service_id, service_name, service_items, item_count,
      therapist_id, therapist_name, counter_staff_id, counter_staff_name,
      room_id, room_name, service_price, sst_amount, total_amount,
      therapist_commission_amount, counter_commission_amount,
      source, payment_method, payment_status, receipt_number, notes)
    values (
      v_a.outlet_id, p_appointment_id, v_a.customer_id,
      coalesce(v_c.name,''), coalesce(v_c.phone,''),
      v_sid, v_snm, p_addon_service_items, jsonb_array_length(p_addon_service_items),
      v_a.therapist_id, v_tnm, p_counter_staff_id, p_counter_staff_name,
      v_a.room_id, v_rnm, p_service_price, p_sst_amount, p_total_amount,
      public.csp_commission_for_items(p_addon_service_items, v_a.therapist_id,'Therapist'),
      case when p_counter_staff_id is null then 0
        else public.csp_commission_for_items(p_addon_service_items, p_counter_staff_id,'Counter') end,
      'appointment_addon',
      coalesce(nullif(p_payment_method,''),'cash')::public.payment_method,
      'paid'::public.payment_status, p_receipt_number,
      'Services added during appointment check-in')
    returning id into v_txn;

    -- Freeze the original online receipt's commission from its own snapshot so
    -- newly appended items cannot be counted twice at completion.
    update public.transactions original
    set therapist_commission_amount = public.csp_commission_for_items(
          original.service_items, v_a.therapist_id, 'Therapist'),
        updated_at = now()
    where original.appointment_id = p_appointment_id
      and original.source = 'online_booking'
      and original.payment_status = 'paid'
      and coalesce(original.therapist_commission_amount, 0) = 0;
  end if;

  return query select true, p_appointment_id, v_txn, v_a.checked_in_at, null::text, null::text;
end;
$$;


--
-- Name: check_in_appointment_group(uuid, uuid[], jsonb, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_in_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb DEFAULT '{}'::jsonb, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, transaction_id uuid, checked_in_at timestamp with time zone, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_id uuid; v_a public.appointments%rowtype; v_first public.appointments%rowtype;
  v_c public.customers%rowtype; v_items jsonb; v_all jsonb := '[]'::jsonb;
  v_first_item jsonb; v_sid uuid; v_snm text; v_tnm text := ''; v_rnm text := '';
  v_comm numeric := 0; v_txn uuid; v_pay boolean; v_stamp timestamptz;
  v_already int := 0; v_total int;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  if p_appointment_ids is null or array_length(p_appointment_ids,1) is null then
    return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
      'INVALID_APPOINTMENTS','No appointments were supplied.'; return;
  end if;

  -- The complete group is required; partial check-in is not a valid state.
  if cardinality(p_appointment_ids) <> (select count(distinct s.id)::int from unnest(p_appointment_ids) s(id))
     or cardinality(p_appointment_ids) <> (select count(*)::int from public.appointments a
          where a.appointment_group_id = p_appointment_group_id) then
    return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
      'INVALID_APPOINTMENTS','The complete appointment group is required.'; return;
  end if;

  v_total := cardinality(p_appointment_ids);
  v_stamp := now();

  -- Lock and validate EVERY pax before writing anything, so a rejection leaves
  -- no partial group state.
  for v_id in select unnest(p_appointment_ids) order by 1 loop
    select * into v_a from public.appointments a
    where a.id = v_id and a.appointment_group_id = p_appointment_group_id for update;
    if not found then
      return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
        'INVALID_APPOINTMENTS', format('Pax %s does not belong to this group.', v_id); return;
    end if;
    if v_a.actual_started_at is not null then
      return query select false, p_appointment_group_id, null::uuid, v_a.checked_in_at,
        'ALREADY_STARTED', format('Pax %s has already started.', v_id); return;
    end if;
    if v_a.status::text not in ('pending','confirmed') then
      return query select false, p_appointment_group_id, null::uuid, v_a.checked_in_at,
        'NOT_CHECKABLE', format('Pax %s is not checkable.', v_id); return;
    end if;
    if v_a.appointment_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
      return query select false, p_appointment_group_id, null::uuid, v_a.checked_in_at,
        'WRONG_DATE', format('Pax %s is not scheduled for today.', v_id); return;
    end if;
    if v_a.checked_in_at is not null then v_already := v_already + 1; end if;
    if v_first.id is null then v_first := v_a; end if;
  end loop;

  -- Already fully checked in: idempotent no-op, no re-charge.
  if v_already = v_total then
    select t.id into v_txn from public.transactions t
    where t.appointment_group_id = p_appointment_group_id and t.source = 'appointment_addon'
    order by t.created_at desc limit 1;
    return query select true, p_appointment_group_id, v_txn, v_first.checked_in_at,
      null::text, null::text; return;
  end if;

  -- Mixed state: refuse rather than compound it.
  if v_already > 0 then
    return query select false, p_appointment_group_id, null::uuid, null::timestamptz,
      'PARTIAL_CHECKIN','Some pax are already checked in; resolve them individually.'; return;
  end if;

  v_pay := coalesce(p_total_amount,0) > 0 and exists (
    select 1 from jsonb_each(coalesce(p_addon_items_by_appointment,'{}'::jsonb)) e
    where jsonb_typeof(e.value)='array' and jsonb_array_length(e.value) > 0);

  foreach v_id in array p_appointment_ids loop
    update public.appointments a
    set checked_in_at = v_stamp, checked_in_by = auth.uid(), updated_at = now()
    where a.id = v_id;
    v_items := coalesce(p_addon_items_by_appointment -> v_id::text, '[]'::jsonb);
    v_all := v_all || v_items;
    select * into v_a from public.appointments where id = v_id;
    v_comm := v_comm + public.csp_commission_for_items(v_items, v_a.therapist_id, 'Therapist');
  end loop;

  if v_pay then
    select * into v_c from public.customers where id = v_first.customer_id;
    select coalesce(name,'') into v_tnm from public.therapists where id = v_first.therapist_id;
    select coalesce(name,'') into v_rnm from public.rooms where id = v_first.room_id;
    v_first_item := v_all -> 0;
    v_sid := nullif(coalesce(v_first_item->>'id', v_first_item->>'serviceId'),'')::uuid;
    v_snm := coalesce(v_first_item->>'name','Service add-on');
    insert into public.transactions (
      outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
      service_id, service_name, service_items, item_count,
      therapist_id, therapist_name, counter_staff_id, counter_staff_name,
      room_id, room_name, service_price, sst_amount, total_amount,
      therapist_commission_amount, counter_commission_amount,
      source, payment_method, payment_status, receipt_number, notes)
    values (
      v_first.outlet_id, p_appointment_group_id, v_first.customer_id,
      coalesce(v_c.name,''), coalesce(v_c.phone,''),
      v_sid, v_snm, v_all, jsonb_array_length(v_all),
      v_first.therapist_id, v_tnm, p_counter_staff_id, p_counter_staff_name,
      v_first.room_id, v_rnm, p_service_price, p_sst_amount, p_total_amount,
      v_comm,
      case when p_counter_staff_id is null then 0
        else public.csp_commission_for_items(v_all, p_counter_staff_id,'Counter') end,
      'appointment_addon',
      coalesce(nullif(p_payment_method,''),'cash')::public.payment_method,
      'paid'::public.payment_status, p_receipt_number,
      'Services added during group appointment check-in')
    returning id into v_txn;
  end if;

  return query select true, p_appointment_group_id, v_txn, v_stamp, null::text, null::text;
end;
$$;


--
-- Name: check_in_paid_appointment_group_with_addon(uuid, uuid[], jsonb, jsonb, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_in_paid_appointment_group_with_addon(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_per_appointment_updates jsonb DEFAULT '{}'::jsonb, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r record;
begin
  -- p_per_appointment_updates carried end_time/end_at/late-overlap flags; it is
  -- accepted for caller compatibility and intentionally IGNORED for the same
  -- reason as the single-appointment wrapper.
  select * into r from public.check_in_appointment_group(
    p_appointment_group_id, p_appointment_ids, p_addon_items_by_appointment,
    p_counter_staff_id, p_counter_staff_name,
    p_service_price, p_sst_amount, p_total_amount, p_payment_method, p_receipt_number);
  return query select r.success, r.appointment_group_id, r.transaction_id, r.error_code, r.error_message;
end;
$$;


--
-- Name: check_in_paid_appointment_with_addon(uuid, jsonb, time without time zone, timestamp with time zone, boolean, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_in_paid_appointment_with_addon(p_appointment_id uuid, p_addon_service_items jsonb, p_end_time time without time zone DEFAULT NULL::time without time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_allow_late_extension_overlap boolean DEFAULT false, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r record;
begin
  -- p_end_time / p_end_at / p_allow_late_extension_overlap are accepted for
  -- caller compatibility and intentionally IGNORED: check-in must not move the
  -- operational window. Supply add-on duration to start_appointment_service
  -- (p_expected_end_at) at START instead.
  select * into r from public.check_in_appointment(
    p_appointment_id, p_addon_service_items, p_counter_staff_id, p_counter_staff_name,
    p_service_price, p_sst_amount, p_total_amount, p_payment_method, p_receipt_number);
  return query select r.success, r.appointment_id, r.transaction_id, r.error_code, r.error_message;
end;
$$;


--
-- Name: check_walkin_availability(date, time without time zone, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_walkin_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid) RETURNS TABLE(therapists jsonb, zone_available_now boolean, zone_free_slots integer, can_start_now boolean, next_available_time time without time zone)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
  v_outlet_id uuid;
  v_room_total integer := 1;
  v_room_booked integer := 0;
  v_room_free_at timestamp;
  v_therapist_free_at time;
begin
  select r.outlet_id, greatest(coalesce(r.total_slots, 1), 1)
  into v_outlet_id, v_room_total
  from public.rooms r
  where r.id = p_room_id;

  if v_outlet_id is null then
    therapists := '[]'::jsonb;
    zone_available_now := false;
    zone_free_slots := 0;
    can_start_now := false;
    next_available_time := null;
    return next;
    return;
  end if;

  select count(*)::integer, max(conflict_end)
  into v_room_booked, v_room_free_at
  from (
    select public.csp_appointment_block_end_at(a) as conflict_end
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.room_id = p_room_id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_block_end_at(a) > v_start_at
    union all
    select (h.end_at + make_interval(
      mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
    )) at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    where h.assigned_room_id = p_room_id
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
      and ((h.end_at + make_interval(
        mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
      )) at time zone 'Asia/Kuala_Lumpur') > v_start_at
  ) room_conflicts;

  zone_free_slots := greatest(v_room_total - coalesce(v_room_booked, 0), 0);
  zone_available_now := zone_free_slots > 0;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'therapist_id', availability.therapist_id,
      'name', availability.therapist_name,
      'status', availability.status,
      'free_at', availability.free_at::time,
      'free_in_minutes', case
        when availability.free_at is null then 0
        else greatest(
          ceil(extract(epoch from (availability.free_at - v_start_at)) / 60)::integer,
          0
        )
      end
    )
    order by availability.status_order,
      availability.free_at nulls first,
      availability.therapist_name
  ), '[]'::jsonb), min(availability.free_at::time)
  into therapists, v_therapist_free_at
  from (
    select t.id as therapist_id,
      t.name as therapist_name,
      case
        when conflicts.leave_end is not null then 'on_leave'
        when conflicts.free_at is null then 'free_now'
        else 'busy'
      end as status,
      case
        when conflicts.leave_end is not null then conflicts.leave_end
        else conflicts.free_at
      end as free_at,
      case
        when conflicts.leave_end is not null then 2
        when conflicts.free_at is null then 0
        else 1
      end as status_order
    from public.therapists t
    left join lateral (
      select max(c.conflict_end) as free_at,
        max(c.conflict_end) filter (where c.conflict_kind = 'leave') as leave_end
      from (
        select public.csp_appointment_block_end_at(a) as conflict_end,
          'appointment'::text as conflict_kind
        from public.appointments a
        where a.appointment_date::date between p_today - 1 and p_today + 1
          and a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_end_at
          and public.csp_appointment_block_end_at(a) > v_start_at
        union all
        select u.ends_at at time zone 'Asia/Kuala_Lumpur', 'leave'
        from public.therapist_unavailability u
        where u.therapist_id = t.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
          and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
        union all
        select (h.end_at + make_interval(
          mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
        )) at time zone 'Asia/Kuala_Lumpur', 'hold'
        from public.booking_holds h
        where h.assigned_therapist_id = t.id
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
          and ((h.end_at + make_interval(
            mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
          )) at time zone 'Asia/Kuala_Lumpur') > v_start_at
      ) c
    ) conflicts on true
    where t.outlet_id = v_outlet_id
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
  ) availability;

  can_start_now := zone_available_now and exists (
    select 1
    from jsonb_array_elements(therapists) item
    where item ->> 'status' = 'free_now'
  );
  next_available_time := case
    when can_start_now then p_now_time
    when v_room_free_at is null then v_therapist_free_at
    when v_therapist_free_at is null then v_room_free_at::time
    else greatest(v_room_free_at::time, v_therapist_free_at)
  end;
  return next;
end;
$$;


--
-- Name: check_walkin_protects_future(uuid, timestamp without time zone, integer, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_walkin_protects_future(p_outlet_id uuid, p_start timestamp without time zone, p_duration integer, p_therapist_id uuid, p_exclude_appointment_id uuid DEFAULT NULL::uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_end timestamp without time zone;
  v_checkpoint timestamp without time zone;
  v_scheduled integer;
  v_demand integer;
  v_candidate_reduces_capacity integer;
begin
  if p_outlet_id is null
     or p_start is null
     or coalesce(p_duration, 0) < 1
     or p_therapist_id is null then
    raise exception using
      errcode = '22023',
      message = 'Outlet, start, positive duration, and therapist are required.';
  end if;

  v_end := p_start + make_interval(mins => p_duration);

  if not exists (
    select 1
    from public.therapists therapist
    where therapist.id = p_therapist_id
      and therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
  ) then
    return false;
  end if;

  for v_checkpoint in
    select checkpoint
    from (
      select public.csp_appointment_start_at(appointment) as checkpoint
      from public.appointments appointment
      where appointment.outlet_id = p_outlet_id
        and appointment.id is distinct from p_exclude_appointment_id
        and appointment.type::text = 'appointment'
        and public.csp_blocks_schedule(appointment.status::text)
        and public.csp_appointment_start_at(appointment) >= p_start
        and public.csp_appointment_start_at(appointment) < v_end

      union

      select hold.start_at at time zone 'Asia/Kuala_Lumpur'
      from public.booking_holds hold
      where hold.outlet_id = p_outlet_id
        and hold.assigned_therapist_id is not null
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
        and coalesce(hold.hold_kind, '') <> 'staff_walkin_draft'
        and (hold.start_at at time zone 'Asia/Kuala_Lumpur') >= p_start
        and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end
    ) upcoming
    where checkpoint >= now() at time zone 'Asia/Kuala_Lumpur'
    order by checkpoint
  loop
    select count(*)
    into v_scheduled
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = therapist.id
          and (
            (
              hours.day_of_week = extract(dow from v_checkpoint::date)::integer
              and v_checkpoint::date + hours.start_time <= v_checkpoint
              and v_checkpoint::date + hours.end_time
                + case
                    when hours.end_time <= hours.start_time then interval '1 day'
                    else interval '0'
                  end > v_checkpoint
            )
            or (
              hours.end_time <= hours.start_time
              and hours.day_of_week =
                extract(dow from v_checkpoint::date - 1)::integer
              and (v_checkpoint::date - 1) + hours.start_time <= v_checkpoint
              and (v_checkpoint::date - 1) + hours.end_time
                + interval '1 day' > v_checkpoint
            )
          )
      )
      and not exists (
        select 1
        from public.therapist_unavailability unavailable
        where unavailable.therapist_id = therapist.id
          and (unavailable.starts_at at time zone 'Asia/Kuala_Lumpur')
            <= v_checkpoint
          and (unavailable.ends_at at time zone 'Asia/Kuala_Lumpur')
            > v_checkpoint
      );

    select
      (
        select count(*)
        from public.appointments appointment
        where appointment.outlet_id = p_outlet_id
          and appointment.id is distinct from p_exclude_appointment_id
          and public.csp_blocks_schedule(appointment.status::text)
          and public.csp_appointment_start_at(appointment) <= v_checkpoint
          and public.csp_appointment_block_end_at(appointment) > v_checkpoint
      )
      + (
        select count(*)
        from public.booking_holds hold
        where hold.outlet_id = p_outlet_id
          and hold.assigned_therapist_id is not null
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and coalesce(hold.hold_kind, '') <> 'staff_walkin_draft'
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur') <= v_checkpoint
          and (
            hold.end_at
              + make_interval(
                  mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
                )
          ) at time zone 'Asia/Kuala_Lumpur' > v_checkpoint
      )
    into v_demand;

    select case when exists (
      select 1
      from public.therapist_working_hours hours
      where hours.therapist_id = p_therapist_id
        and (
          (
            hours.day_of_week = extract(dow from v_checkpoint::date)::integer
            and v_checkpoint::date + hours.start_time <= v_checkpoint
            and v_checkpoint::date + hours.end_time
              + case
                  when hours.end_time <= hours.start_time then interval '1 day'
                  else interval '0'
                end > v_checkpoint
          )
          or (
            hours.end_time <= hours.start_time
            and hours.day_of_week =
              extract(dow from v_checkpoint::date - 1)::integer
            and (v_checkpoint::date - 1) + hours.start_time <= v_checkpoint
            and (v_checkpoint::date - 1) + hours.end_time
              + interval '1 day' > v_checkpoint
          )
        )
    ) then 1 else 0 end
    into v_candidate_reduces_capacity;

    if v_scheduled < v_demand + v_candidate_reduces_capacity then
      return false;
    end if;
  end loop;

  return true;
end;
$$;


--
-- Name: checkout_appointment_group_with_payment(uuid, uuid[], uuid, text, text, jsonb, uuid, text, numeric, numeric, numeric, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.checkout_appointment_group_with_payment(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_id uuid, p_customer_name text, p_customer_phone text, p_per_appointment_updates jsonb DEFAULT '{}'::jsonb, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_id uuid;
  v_update jsonb;
  v_row record;
  v_idx integer := 0;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_outlet_id uuid;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  if p_appointment_ids is null or array_length(p_appointment_ids, 1) is null then
    success := false;
    appointment_group_id := p_appointment_group_id;
    transaction_id := null;
    error_code := 'INVALID_ALLOCATIONS';
    error_message := 'No appointments supplied for checkout.';
    return next;
    return;
  end if;

  foreach v_id in array p_appointment_ids loop
    v_idx := v_idx + 1;
    v_update := coalesce(p_per_appointment_updates -> v_id::text, '{}'::jsonb);

    perform set_config(
      'app.allow_late_extension_overlap',
      case
        when coalesce((v_update ->> 'allow_late_extension_overlap')::boolean, false)
        then 'on'
        else 'off'
      end,
      true
    );

    update public.appointments
    set customer_id = p_customer_id,
        booked_date = coalesce((v_update ->> 'booked_date')::date, booked_date),
        booked_start_time = coalesce((v_update ->> 'booked_start_time')::time, booked_start_time),
        booked_end_time = coalesce((v_update ->> 'booked_end_time')::time, booked_end_time),
        booked_start_at = coalesce((v_update ->> 'booked_start_at')::timestamptz, booked_start_at),
        booked_end_at = coalesce((v_update ->> 'booked_end_at')::timestamptz, booked_end_at),
        end_time = coalesce((v_update ->> 'end_time')::time, end_time),
        end_at = coalesce((v_update ->> 'end_at')::timestamptz, end_at),
        actual_started_at = now(),
        status = 'in_progress',
        updated_at = now()
    where id = v_id
    returning therapist_id, room_id, service_id, service_name, service_items, outlet_id
    into v_row;

    if not found then
      raise exception 'Appointment % was not found for group checkout', v_id;
    end if;

    v_all_items := v_all_items || coalesce(v_row.service_items, '[]'::jsonb);
    v_item_count := v_item_count + jsonb_array_length(coalesce(v_row.service_items, '[]'::jsonb));
    v_outlet_id := coalesce(v_outlet_id, v_row.outlet_id);
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(v_row.service_items, v_row.therapist_id, 'Therapist');

    if v_idx = 1 then
      v_first_therapist_id := v_row.therapist_id;
      v_first_room_id := v_row.room_id;
      v_first_service_id := v_row.service_id;
      v_first_service_name := v_row.service_name;
      select name into v_first_therapist_name from public.therapists where id = v_row.therapist_id;
      select name into v_first_room_name from public.rooms where id = v_row.room_id;
    end if;
  end loop;

  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name,
    counter_staff_id, counter_staff_name,
    room_id, room_name,
    service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  )
  values (
    v_outlet_id, p_appointment_group_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items, greatest(v_item_count, 1),
    v_first_therapist_id, coalesce(v_first_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    v_first_room_id, coalesce(v_first_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'appointment', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method, 'paid'::public.payment_status,
    p_receipt_number, coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  success := true;
  appointment_group_id := p_appointment_group_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;


--
-- Name: checkout_appointment_with_payment(uuid, uuid, text, text, date, time without time zone, time without time zone, timestamp with time zone, timestamp with time zone, time without time zone, timestamp with time zone, boolean, uuid, text, numeric, numeric, numeric, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.checkout_appointment_with_payment(p_appointment_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_booked_date date DEFAULT NULL::date, p_booked_start_time time without time zone DEFAULT NULL::time without time zone, p_booked_end_time time without time zone DEFAULT NULL::time without time zone, p_booked_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_booked_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_time time without time zone DEFAULT NULL::time without time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_allow_late_extension_overlap boolean DEFAULT false, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_row record;
  v_therapist_name text;
  v_room_name text;
  v_therapist_commission numeric;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  if p_allow_late_extension_overlap then
    perform set_config('app.allow_late_extension_overlap', 'on', true);
  else
    perform set_config('app.allow_late_extension_overlap', 'off', true);
  end if;

  if not exists (select 1 from public.appointments where id = p_appointment_id) then
    success := false;
    appointment_id := null;
    transaction_id := null;
    error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.';
    return next;
    return;
  end if;

  update public.appointments
  set customer_id = p_customer_id,
      booked_date = coalesce(p_booked_date, booked_date),
      booked_start_time = coalesce(p_booked_start_time, booked_start_time),
      booked_end_time = coalesce(p_booked_end_time, booked_end_time),
      booked_start_at = coalesce(p_booked_start_at, booked_start_at),
      booked_end_at = coalesce(p_booked_end_at, booked_end_at),
      end_time = coalesce(p_end_time, end_time),
      end_at = coalesce(p_end_at, end_at),
      actual_started_at = now(),
      status = 'in_progress',
      updated_at = now()
  where id = p_appointment_id
  returning therapist_id, room_id, service_id, service_name, service_items, item_count, outlet_id
  into v_row;

  select name into v_therapist_name from public.therapists where id = v_row.therapist_id;
  select name into v_room_name from public.rooms where id = v_row.room_id;

  v_therapist_commission := public.csp_commission_for_items(v_row.service_items, v_row.therapist_id, 'Therapist');
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_row.service_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name,
    counter_staff_id, counter_staff_name,
    room_id, room_name,
    service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  )
  values (
    v_row.outlet_id, p_appointment_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_row.service_id, coalesce(v_row.service_name, ''), coalesce(v_row.service_items, '[]'::jsonb), greatest(coalesce(v_row.item_count, 1), 1),
    v_row.therapist_id, coalesce(v_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    v_row.room_id, coalesce(v_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'appointment', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method, 'paid'::public.payment_status,
    p_receipt_number, coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  success := true;
  appointment_id := p_appointment_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;


--
-- Name: claim_billplz_bill_v2(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_billplz_bill_v2(p_token uuid, p_bill_id text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_bill_id text := nullif(trim(p_bill_id), '');
  v_is_group boolean;
  v_existing_bill_id text;
begin
  if v_bill_id is null or length(v_bill_id) > 200 then
    raise exception 'A valid Billplz bill id is required';
  end if;

  select exists (
    select 1
    from public.booking_holds
    where booking_group_token = p_token
  )
  into v_is_group;

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
      hold.status <> 'pending_payment'
      or hold.expires_at <= now()
      or hold.appointment_id is not null
      or hold.appointment_group_id is not null
    )
  ) then
    raise exception 'This booking hold can no longer accept payment';
  end if;

  select hold.billplz_bill_id
  into v_existing_bill_id
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

  if v_existing_bill_id is not null then
    return v_existing_bill_id;
  end if;

  if v_is_group then
    update public.booking_holds
    set billplz_bill_id = case
          when guest_index = 1 then v_bill_id
          else null
        end,
        updated_at = now()
    where booking_group_token = p_token;
  else
    update public.booking_holds
    set billplz_bill_id = v_bill_id,
        updated_at = now()
    where public_token = p_token;
  end if;

  return v_bill_id;
end;
$$;


--
-- Name: claim_booking_bill_cancellation(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_booking_bill_cancellation(p_token uuid, p_target_status text) RETURNS TABLE(hold_id uuid, bill_id text, cancellation_claim_token uuid, claim_acquired boolean, already_cancelled boolean, resulting_status text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_target text := lower(coalesce(p_target_status,''));
  v_is_group boolean;
  v_bill_hold public.booking_holds%rowtype;
  v_status text;
  v_claim uuid;
begin
  if v_target not in ('cancelled','expired') then raise exception 'Invalid booking-hold closure status'; end if;
  select exists(select 1 from public.booking_holds where booking_group_token=p_token) into v_is_group;
  perform 1 from public.booking_holds hold
  where (v_is_group and hold.booking_group_token=p_token) or (not v_is_group and hold.public_token=p_token)
  order by hold.guest_index nulls first,hold.id for update;
  if not found then raise exception 'Booking reference not found'; end if;
  if exists(select 1 from public.booking_holds hold
    where ((v_is_group and hold.booking_group_token=p_token) or (not v_is_group and hold.public_token=p_token))
    and (hold.status in ('confirmed','paid') or hold.appointment_id is not null or hold.appointment_group_id is not null)) then
    raise exception 'A paid booking cannot be cancelled';
  end if;
  if v_target='expired' and exists(select 1 from public.booking_holds hold
    where ((v_is_group and hold.booking_group_token=p_token) or (not v_is_group and hold.public_token=p_token))
    and hold.status='pending_payment' and hold.expires_at > now()) then
    raise exception 'This booking hold has not expired';
  end if;
  update public.booking_holds hold
  set status=v_target,expires_at=case when v_target='cancelled' then least(hold.expires_at,now()) else hold.expires_at end,updated_at=now()
  where ((v_is_group and hold.booking_group_token=p_token) or (not v_is_group and hold.public_token=p_token))
    and hold.status='pending_payment' and (v_target='cancelled' or hold.expires_at <= now());
  select hold.* into v_bill_hold from public.booking_holds hold
  where ((v_is_group and hold.booking_group_token=p_token) or (not v_is_group and hold.public_token=p_token))
    and hold.billplz_bill_id is not null
  order by hold.guest_index nulls first,hold.id limit 1;
  select hold.status into v_status from public.booking_holds hold
  where (v_is_group and hold.booking_group_token=p_token) or (not v_is_group and hold.public_token=p_token)
  order by hold.guest_index nulls first,hold.id limit 1;
  if v_status not in ('expired','cancelled') then raise exception 'This booking hold can no longer be cancelled'; end if;
  if v_bill_hold.billplz_bill_id is null then
    hold_id:=null; bill_id:=null; cancellation_claim_token:=null; claim_acquired:=false; already_cancelled:=false; resulting_status:=v_status; return next; return;
  end if;
  if v_bill_hold.billplz_cancelled_at is not null then
    hold_id:=v_bill_hold.id; bill_id:=v_bill_hold.billplz_bill_id; cancellation_claim_token:=null; claim_acquired:=false; already_cancelled:=true; resulting_status:=v_status; return next; return;
  end if;
  v_claim:=gen_random_uuid();
  update public.booking_holds hold set
    billplz_cancellation_claim_token=v_claim,billplz_cancellation_claimed_at=now(),
    billplz_cancellation_attempts=hold.billplz_cancellation_attempts+1,
    billplz_cancellation_last_attempt_at=now(),billplz_cancellation_last_error=null,updated_at=now()
  where hold.id=v_bill_hold.id and hold.billplz_cancelled_at is null
    and (hold.billplz_cancellation_claimed_at is null or hold.billplz_cancellation_claimed_at <= now()-interval '5 minutes');
  hold_id:=v_bill_hold.id; bill_id:=v_bill_hold.billplz_bill_id; cancellation_claim_token:=v_claim;
  claim_acquired:=found; already_cancelled:=false; resulting_status:=v_status; return next;
end;
$$;


--
-- Name: claim_expired_billplz_cancellations(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_expired_billplz_cancellations(p_limit integer DEFAULT 100) RETURNS TABLE(hold_id uuid, bill_id text, cancellation_claim_token uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.expire_stale_booking_holds();
  return query
  with candidates as (
    select hold.id from public.booking_holds hold
    where hold.billplz_bill_id is not null and hold.billplz_cancelled_at is null and hold.status='expired'
      and hold.appointment_id is null and hold.appointment_group_id is null
      and (hold.billplz_cancellation_claimed_at is null or hold.billplz_cancellation_claimed_at <= now()-interval '5 minutes')
    order by hold.expires_at,hold.id for update skip locked
    limit greatest(1,least(coalesce(p_limit,100),500))
  )
  update public.booking_holds hold set
    billplz_cancellation_claim_token=gen_random_uuid(),billplz_cancellation_claimed_at=now(),
    billplz_cancellation_attempts=hold.billplz_cancellation_attempts+1,
    billplz_cancellation_last_attempt_at=now(),billplz_cancellation_last_error=null,updated_at=now()
  from candidates where hold.id=candidates.id
  returning hold.id,hold.billplz_bill_id,hold.billplz_cancellation_claim_token;
end;
$$;


--
-- Name: clamp_booking_hold_expiry(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clamp_booking_hold_expiry() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.status = 'pending_payment' then
    new.expires_at := least(
      coalesce(new.expires_at, now() + interval '10 minutes'),
      now() + interval '10 minutes'
    );
  end if;
  return new;
end;
$$;


--
-- Name: clear_appointment_resources(uuid, boolean, boolean, boolean, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clear_appointment_resources(p_appointment_id uuid, p_clear_therapist boolean DEFAULT false, p_clear_room boolean DEFAULT false, p_clear_room_unit boolean DEFAULT false, p_clear_requested_therapist boolean DEFAULT false, p_clear_requested_gender boolean DEFAULT false) RETURNS TABLE(success boolean, appointment_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_a public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, 'NOT_FOUND','Appointment was not found.'; return;
  end if;

  -- A started, completed or resource-confirmed row must keep concrete
  -- resources (CHECK appointments_started_requires_concrete).
  if v_a.actual_started_at is not null
     or v_a.resources_confirmed_at is not null
     or v_a.status::text in ('in_progress','completed') then
    return query select false, p_appointment_id, 'NOT_CLEARABLE',
      'Started or resource-confirmed appointments keep their resources.'; return;
  end if;

  update public.appointments a
  set therapist_id = case when p_clear_therapist then null else a.therapist_id end,
      therapist_assignment_state = case when p_clear_therapist then 'pending'
        else a.therapist_assignment_state end,
      therapist_auto_assigned_at = case when p_clear_therapist then null
        else a.therapist_auto_assigned_at end,
      room_id = case when p_clear_room then null else a.room_id end,
      room_assignment_state = case when p_clear_room then 'pending'
        else a.room_assignment_state end,
      room_unit_id = case when p_clear_room or p_clear_room_unit then null else a.room_unit_id end,
      room_unit_name = case when p_clear_room or p_clear_room_unit then '' else a.room_unit_name end,
      requested_therapist_id = case when p_clear_requested_therapist then null
        else a.requested_therapist_id end,
      requested_gender = case when p_clear_requested_gender then null else a.requested_gender end,
      updated_at = now()
  where a.id = p_appointment_id;

  return query select true, p_appointment_id, null::text, null::text;
end;
$$;


--
-- Name: complete_billplz_cancellation(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_billplz_cancellation(p_hold_id uuid, p_claim_token uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_updated integer;
begin
  update public.booking_holds set billplz_cancelled_at=now(),billplz_cancellation_claim_token=null,billplz_cancellation_claimed_at=null,billplz_cancellation_last_error=null,updated_at=now()
  where id=p_hold_id and billplz_cancellation_claim_token=p_claim_token and billplz_cancelled_at is null and status in ('expired','cancelled');
  get diagnostics v_updated=row_count; return v_updated=1;
end;
$$;


--
-- Name: complete_due_appointments(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_due_appointments(p_outlet_id uuid DEFAULT NULL::uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_row record;
  v_expected_end timestamptz;
  v_duration interval;
  v_updated integer := 0;
  v_transaction record;
  v_commission numeric;
begin
  for v_row in
    select appointment.*
    from public.appointments appointment
    where appointment.status::text = 'in_progress'
      and appointment.payment_status::text = 'paid'
      and appointment.actual_started_at is not null
      and (p_outlet_id is null or appointment.outlet_id = p_outlet_id)
    for update of appointment skip locked
  loop
    v_duration := coalesce(
      v_row.booked_end_at - v_row.booked_start_at,
      public.csp_end_at(
        coalesce(v_row.booked_date, v_row.appointment_date),
        coalesce(v_row.booked_start_time, v_row.start_time),
        coalesce(v_row.booked_end_time, v_row.end_time)
      ) - public.csp_start_at(
        coalesce(v_row.booked_date, v_row.appointment_date),
        coalesce(v_row.booked_start_time, v_row.start_time)
      ),
      v_row.end_at - v_row.start_at
    );

    v_expected_end := case
      when v_row.end_at is null then null
      else v_row.end_at at time zone 'Asia/Kuala_Lumpur'
    end;

    if v_expected_end is null
       or v_expected_end <= v_row.actual_started_at then
      if v_duration is null or v_duration <= interval '0 seconds' then
        continue;
      end if;
      v_expected_end := v_row.actual_started_at + v_duration;
    end if;

    if v_expected_end >= now() then
      continue;
    end if;

    update public.appointments
    set status = 'completed',
        actual_completed_at = v_expected_end,
        end_at = v_expected_end at time zone 'Asia/Kuala_Lumpur',
        updated_at = now()
    where id = v_row.id;
    v_updated := v_updated + 1;
  end loop;

  for v_transaction in
    select transaction.id,
           transaction.appointment_id,
           transaction.appointment_group_id
    from public.transactions transaction
    where transaction.source = 'online_booking'
      and transaction.payment_status::text = 'paid'
      and coalesce(transaction.therapist_commission_amount, 0) = 0
      and (p_outlet_id is null or transaction.outlet_id = p_outlet_id)
  loop
    v_commission := 0;
    if v_transaction.appointment_id is not null then
      select public.csp_commission_for_items(
        coalesce(appointment.service_items, '[]'::jsonb),
        appointment.therapist_id,
        'Therapist'
      )
      into v_commission
      from public.appointments appointment
      where appointment.id = v_transaction.appointment_id
        and appointment.status::text = 'completed'
        and appointment.actual_completed_at is not null;
    elsif v_transaction.appointment_group_id is not null
      and not exists (
        select 1
        from public.appointments pending
        where pending.appointment_group_id = v_transaction.appointment_group_id
          and pending.status::text not in (
            'completed', 'cancelled', 'no_show'
          )
      ) then
      select coalesce(sum(public.csp_commission_for_items(
        coalesce(appointment.service_items, '[]'::jsonb),
        appointment.therapist_id,
        'Therapist'
      )), 0)
      into v_commission
      from public.appointments appointment
      where appointment.appointment_group_id
              = v_transaction.appointment_group_id
        and appointment.status::text = 'completed'
        and appointment.actual_completed_at is not null;
    end if;

    if coalesce(v_commission, 0) > 0 then
      update public.transactions
      set therapist_commission_amount = v_commission,
          updated_at = now()
      where id = v_transaction.id
        and therapist_commission_amount = 0;
    end if;
  end loop;

  return v_updated;
end;
$$;


--
-- Name: confirm_and_start_appointment(uuid, text, time without time zone, timestamp with time zone, boolean, uuid, text, text, uuid, text, numeric, numeric, numeric, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_and_start_appointment(p_appointment_id uuid, p_idempotency_key text DEFAULT NULL::text, p_end_time time without time zone DEFAULT NULL::time without time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_allow_late_extension_overlap boolean DEFAULT false, p_customer_id uuid DEFAULT NULL::uuid, p_customer_name text DEFAULT ''::text, p_customer_phone text DEFAULT ''::text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, therapist_id uuid, room_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_appt public.appointments%rowtype; v_txn uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then raise exception 'Not authorised'; end if;
  select * into v_appt from public.appointments a where a.id = p_appointment_id for update;
  if not found then
    return query select false, null::uuid, null::uuid, null::uuid, null::uuid, 'NOT_FOUND', 'Appointment was not found.'; return; end if;
  if v_appt.status in ('cancelled','completed','no_show') or v_appt.payment_status = 'voided' then
    return query select false, p_appointment_id, null::uuid, v_appt.therapist_id, v_appt.room_id, 'INVALID_STATE',
      'Appointment is cancelled, completed, voided or otherwise not startable.'; return; end if;
  if v_appt.actual_started_at is not null then
    select t.id into v_txn from public.transactions t where t.appointment_id = p_appointment_id and t.source = 'appointment' order by t.created_at limit 1;
    return query select true, p_appointment_id, v_txn, v_appt.therapist_id, v_appt.room_id, null::text, null::text; return; end if;
  begin
    v_appt := public.reconcile_appointment_resources(p_appointment_id, true);
  exception when others then
    return query select false, p_appointment_id, null::uuid, v_appt.therapist_id, v_appt.room_id, 'RESOURCE_CONFLICT', sqlerrm; return; end;
  if v_appt.assignment_error_code is not null then
    return query select false, p_appointment_id, null::uuid, v_appt.therapist_id, v_appt.room_id,
      v_appt.assignment_error_code, coalesce(v_appt.assignment_error_message, 'Resource assignment failed.'); return; end if;
  if v_appt.payment_status = 'paid' then
    if p_allow_late_extension_overlap then perform set_config('app.allow_late_extension_overlap','on', true); end if;
    update public.appointments a set actual_started_at = now(), status = 'in_progress',
        end_time = coalesce(p_end_time, a.end_time), end_at = coalesce(p_end_at, a.end_at), updated_at = now()
    where a.id = p_appointment_id returning a.* into v_appt;
    v_txn := null;
  else
    select cw.transaction_id into v_txn from public.checkout_appointment_with_payment(
      p_appointment_id, coalesce(p_customer_id, v_appt.customer_id), p_customer_name, p_customer_phone,
      null, null, null, null, null, p_end_time, p_end_at, p_allow_late_extension_overlap,
      p_counter_staff_id, p_counter_staff_name, p_service_price, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes) cw;
    select * into v_appt from public.appointments a where a.id = p_appointment_id;
  end if;
  return query select true, p_appointment_id, v_txn, v_appt.therapist_id, v_appt.room_id, null::text, null::text;
end;
$$;


--
-- Name: confirm_and_start_group(uuid, text, uuid, text, text, uuid, text, numeric, numeric, numeric, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_and_start_group(p_group_id uuid, p_idempotency_key text DEFAULT NULL::text, p_customer_id uuid DEFAULT NULL::uuid, p_customer_name text DEFAULT ''::text, p_customer_phone text DEFAULT ''::text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_ids uuid[]; v_member record; v_all_started boolean; v_any_invalid boolean; v_payment_status text; v_txn uuid; v_locked int;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then raise exception 'Not authorised'; end if;
  -- Lock the group rows first (FOR UPDATE cannot coexist with aggregates).
  select count(*) into v_locked from (
    select a.id from public.appointments a where a.appointment_group_id = p_group_id order by a.start_time, a.id for update) locked;
  if coalesce(v_locked,0) = 0 then
    return query select false, p_group_id, null::uuid[], null::uuid, 'NOT_FOUND', 'Group was not found.'; return; end if;
  -- Now aggregate the locked rows.
  select array_agg(a.id order by a.start_time, a.id), bool_and(a.actual_started_at is not null),
         bool_or(a.status in ('cancelled','completed','no_show') or a.payment_status = 'voided'), min(a.payment_status::text)
  into v_ids, v_all_started, v_any_invalid, v_payment_status
  from public.appointments a where a.appointment_group_id = p_group_id;
  if v_any_invalid then
    return query select false, p_group_id, v_ids, null::uuid, 'INVALID_STATE', 'A group member is cancelled/completed/voided.'; return; end if;
  if v_all_started then
    select t.id into v_txn from public.transactions t where t.appointment_group_id = p_group_id order by t.created_at limit 1;
    return query select true, p_group_id, v_ids, v_txn, null::text, null::text; return; end if;
  begin
    perform public.reconcile_appointment_resources(v_ids[1], true);
  exception when others then
    return query select false, p_group_id, v_ids, null::uuid, 'RESOURCE_CONFLICT', sqlerrm; return; end;
  for v_member in select a.id, a.assignment_error_code, a.assignment_error_message from public.appointments a where a.appointment_group_id = p_group_id loop
    if v_member.assignment_error_code is not null then
      return query select false, p_group_id, v_ids, null::uuid, v_member.assignment_error_code,
        coalesce(v_member.assignment_error_message, 'Resource assignment failed for a group member.'); return; end if;
  end loop;
  if v_payment_status = 'paid' then
    update public.appointments a set actual_started_at = now(), status = 'in_progress', updated_at = now()
    where a.appointment_group_id = p_group_id and a.actual_started_at is null;
    v_txn := null;
  else
    select cg.transaction_id into v_txn from public.checkout_appointment_group_with_payment(
      p_group_id, v_ids, p_customer_id, p_customer_name, p_customer_phone, '{}'::jsonb,
      p_counter_staff_id, p_counter_staff_name, p_service_price, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes) cg;
  end if;
  return query select true, p_group_id, v_ids, v_txn, null::text, null::text;
end;
$$;


--
-- Name: confirm_public_booking_group_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_public_booking_group_v1(p_token uuid) RETURNS TABLE(appointment_group_id uuid, appointment_ids uuid[], status text, start_at timestamp with time zone, end_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_group_id uuid;
  v_hold record;
  v_confirmed record;
  v_ids uuid[] := '{}'::uuid[];
  v_first public.booking_holds%rowtype;
  v_count integer;
begin
  select * into v_first from public.booking_holds where booking_group_token=p_token order by guest_index limit 1 for update;
  if not found then raise exception 'Booking reference not found'; end if;
  if v_first.appointment_group_id is not null then
    select array_agg(hold.appointment_id order by hold.guest_index), min(hold.start_at), max(hold.end_at)
    into v_ids, start_at, end_at from public.booking_holds hold where hold.booking_group_token=p_token;
    appointment_group_id := v_first.appointment_group_id;
    appointment_ids := v_ids;
    status := 'confirmed';
    return next;
    return;
  end if;
  if exists (select 1 from public.booking_holds hold where hold.booking_group_token=p_token and (hold.status <> 'pending_payment' or hold.expires_at <= now())) then
    raise exception 'Booking hold expired';
  end if;
  for v_hold in select * from public.booking_holds where booking_group_token=p_token order by guest_index for update loop
    select * into v_confirmed from public.confirm_public_booking_hold(v_hold.public_token);
    v_ids := array_append(v_ids, v_confirmed.appointment_id);
  end loop;
  select * into v_first from public.booking_holds where booking_group_token=p_token order by guest_index limit 1;
  v_count := cardinality(v_ids);
  insert into public.appointment_groups(outlet_id,customer_id,group_name,pax_count,appointment_date,status,notes)
  values(v_first.outlet_id,v_first.customer_id,coalesce(nullif(v_first.customer_name,''),'Online') || ' group',v_count,(v_first.start_at at time zone 'Asia/Kuala_Lumpur')::date,'confirmed',v_first.notes)
  returning id into v_group_id;
  update public.appointments set appointment_group_id=v_group_id, updated_at=now() where id=any(v_ids);
  update public.booking_holds set appointment_group_id=v_group_id, updated_at=now() where booking_group_token=p_token;
  appointment_group_id := v_group_id;
  appointment_ids := v_ids;
  status := 'confirmed';
  select min(hold.start_at),max(hold.end_at) into start_at,end_at from public.booking_holds hold where hold.booking_group_token=p_token;
  return next;
end;
$$;


--
-- Name: confirm_public_booking_hold(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_public_booking_hold(p_token uuid) RETURNS TABLE(appointment_id uuid, status text, start_at timestamp with time zone, end_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_hold public.booking_holds%rowtype;
  v_service_id uuid;
  v_service_name text;
  v_duration integer;
  v_customer_id uuid;
  v_local_start timestamp;
  v_local_end timestamp;
  v_appointment_id uuid;
begin
  select * into v_hold
  from public.booking_holds
  where public_token = p_token
  for update;

  if not found then
    raise exception 'Booking reference not found';
  end if;

  -- Idempotent: a retry / double-call returns the appointment already created.
  if v_hold.status = 'confirmed' and v_hold.appointment_id is not null then
    appointment_id := v_hold.appointment_id;
    status := v_hold.status;
    start_at := v_hold.start_at;
    end_at := v_hold.end_at;
    return next;
    return;
  end if;

  if v_hold.status not in ('pending_payment', 'paid')
     or (v_hold.status = 'pending_payment' and v_hold.expires_at <= now()) then
    raise exception 'This booking hold can no longer be confirmed';
  end if;

  if v_hold.assigned_therapist_id is null or v_hold.assigned_room_id is null then
    raise exception 'This booking hold has no assigned therapist or room';
  end if;

  select s.id, s.name, greatest(s.duration, 1)
  into v_service_id, v_service_name, v_duration
  from public.online_booking_services c
  join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
  where c.id = v_hold.online_booking_service_id;

  if v_service_id is null then
    raise exception 'The booked service is no longer available';
  end if;

  -- Find-or-create a customer in this outlet, matched on normalized phone (so
  -- "012 822 0430" / "+012 822 0430" / "0128220430" all resolve to the same
  -- customer). On a match, the name on file is kept as-is (not overwritten).
  select id into v_customer_id
  from public.customers
  where outlet_id = v_hold.outlet_id
    and public.normalize_my_phone(phone) = public.normalize_my_phone(v_hold.customer_phone)
  limit 1;

  if v_customer_id is null then
    insert into public.customers (name, phone, email, outlet_id, join_date)
    values (
      v_hold.customer_name,
      v_hold.customer_phone,
      nullif(v_hold.customer_email, ''),
      v_hold.outlet_id,
      (now() at time zone 'Asia/Kuala_Lumpur')::date
    )
    returning id into v_customer_id;
  end if;

  -- Move the hold off pending_payment BEFORE inserting the appointment so the
  -- resource-overlap trigger does not treat the hold as a competing reservation.
  update public.booking_holds
  set status = 'confirmed',
      confirmed_at = now(),
      customer_id = v_customer_id,
      updated_at = now()
  where id = v_hold.id;

  v_local_start := v_hold.start_at at time zone 'Asia/Kuala_Lumpur';
  v_local_end := v_hold.end_at at time zone 'Asia/Kuala_Lumpur';

  insert into public.appointments (
    outlet_id,
    customer_id,
    therapist_id,
    room_id,
    service_id,
    online_booking_service_id,
    appointment_date,
    start_time,
    end_time,
    start_at,
    end_at,
    booked_date,
    booked_start_time,
    booked_end_time,
    booked_start_at,
    booked_end_at,
    status,
    total_price,
    type,
    service_name,
    service_items,
    item_count,
    buffer_after_minutes,
    notes,
    created_at
  )
  values (
    v_hold.outlet_id,
    v_customer_id,
    v_hold.assigned_therapist_id,
    v_hold.assigned_room_id,
    v_service_id,
    v_hold.online_booking_service_id,
    v_local_start::date,
    v_local_start::time,
    v_local_end::time,
    v_hold.start_at,
    v_hold.end_at,
    v_local_start::date,
    v_local_start::time,
    v_local_end::time,
    v_hold.start_at,
    v_hold.end_at,
    'confirmed',
    v_hold.total_amount,
    'appointment',
    v_service_name,
    jsonb_build_array(jsonb_build_object(
      'id', v_service_id,
      'name', v_service_name,
      'duration', v_duration,
      'price', v_hold.total_amount
    )),
    1,
    greatest(coalesce(v_hold.buffer_after_minutes, 0), 0),
    v_hold.notes,
    now()
  )
  returning id into v_appointment_id;

  update public.booking_holds
  set appointment_id = v_appointment_id,
      updated_at = now()
  where id = v_hold.id;

  appointment_id := v_appointment_id;
  status := 'confirmed';
  start_at := v_hold.start_at;
  end_at := v_hold.end_at;
  return next;
end;
$$;


--
-- Name: consume_queue_on_appointment_start(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_queue_on_appointment_start() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.actual_started_at is null then return new; end if;
  if tg_op = 'UPDATE' and old.actual_started_at is not null then return new; end if;
  if lower(coalesce(new.status::text, '')) in ('cancelled','canceled','no_show','no-show','noshow')
     or lower(coalesce(new.payment_status::text, '')) = 'voided' then
    return new;
  end if;
  -- Project B defensive guard: never consume a queue turn for a NULL therapist.
  if new.therapist_id is null then return new; end if;
  perform public.consume_therapist_queue_turn_for_start(
    new.outlet_id, new.appointment_date, new.therapist_id, new.actual_started_at, new.id
  );
  return new;
end;
$$;


--
-- Name: consume_therapist_queue_turn_for_start(uuid, date, uuid, timestamp with time zone, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_therapist_queue_turn_for_start(p_outlet_id uuid, p_queue_date date, p_therapist_id uuid, p_started_at timestamp with time zone, p_appointment_id uuid DEFAULT NULL::uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_last_consumed_at timestamptz;
begin
  if p_outlet_id is null
     or p_queue_date is null
     or p_therapist_id is null
     or p_started_at is null then
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_queue_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_queue_date);

  select queue_row.turn_consumed_at
  into v_last_consumed_at
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_queue_date
    and queue_row.therapist_id = p_therapist_id
  for update;

  if not found
     or (
       v_last_consumed_at is not null
       and p_started_at <= v_last_consumed_at
     ) then
    return;
  end if;

  update public.therapist_queue
  set turn_consumed_at = p_started_at,
      protected_turn_owed = false,
      protected_turn_reason = null
  where outlet_id = p_outlet_id
    and queue_date = p_queue_date
    and therapist_id = p_therapist_id;
end;
$$;


--
-- Name: FUNCTION consume_therapist_queue_turn_for_start(p_outlet_id uuid, p_queue_date date, p_therapist_id uuid, p_started_at timestamp with time zone, p_appointment_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.consume_therapist_queue_turn_for_start(p_outlet_id uuid, p_queue_date date, p_therapist_id uuid, p_started_at timestamp with time zone, p_appointment_id uuid) IS 'Consumes the started therapist live turn, except an out-of-turn exact customer request.';


--
-- Name: create_appointment_group_with_csp(uuid, text, integer, date, jsonb, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_appointment_group_with_csp(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text DEFAULT 'appointment'::text, p_status text DEFAULT 'confirmed'::text, p_notes text DEFAULT ''::text, p_created_by uuid DEFAULT auth.uid()) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_allocation jsonb; v_new_appointment_id uuid; v_check record;
  v_therapist_id uuid; v_room_id uuid; v_service_id uuid;
  v_start time; v_end time; v_start_at timestamp; v_end_at timestamp;
  v_group_conflicts integer; v_group_room_slots integer;
  v_outlet uuid; v_buffer integer; v_room_type text; v_source text; v_pax integer := 0;
  v_demands jsonb := '[]'::jsonb; v_feasible jsonb; v_use_anon boolean := false;
begin
  appointment_ids := array[]::uuid[];
  if jsonb_typeof(p_allocations) is distinct from 'array' or jsonb_array_length(p_allocations) = 0 then
    success := false; appointment_group_id := null; error_code := 'INVALID_ALLOCATIONS';
    error_message := 'Group booking requires at least one pax allocation.'; return next; return;
  end if;

  select (a ->> 'service_id')::uuid into v_service_id from jsonb_array_elements(p_allocations) a limit 1;
  select s.outlet_id into v_outlet from public.services s where s.id = v_service_id;
  v_use_anon := v_outlet is not null and public.capacity_first_enabled(v_outlet);

  if v_use_anon then
    for v_allocation in select value from jsonb_array_elements(p_allocations) loop
      v_service_id := (v_allocation ->> 'service_id')::uuid;
      v_start := (v_allocation ->> 'start_time')::time; v_end := (v_allocation ->> 'end_time')::time;
      if v_start is null or v_end is null or v_end = v_start then
        success := false; appointment_group_id := null; error_code := 'INVALID_DURATION';
        error_message := 'One pax allocation has an invalid time range.'; return next; return;
      end if;
      v_start_at := public.csp_start_at(p_appointment_date, v_start);
      v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);
      select coalesce(s.buffer_after_minutes,0), lower(coalesce(s.room_type::text,''))
        into v_buffer, v_room_type from public.services s where s.id = v_service_id;
      v_source := coalesce(nullif(v_allocation ->> 'assignment_source',''),'queue');
      v_demands := v_demands || jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at,'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at))/60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', v_service_id::text, 'room_type', v_room_type,
        'requested_gender', nullif(v_allocation ->> 'requested_gender',''),
        'requested_therapist_id', case when v_source in ('specific_customer_request','manual_override')
              then nullif(v_allocation ->> 'requested_therapist_id','') else null end,
        'pax_index', v_pax));
      v_pax := v_pax + 1;
    end loop;
    perform set_config('lock_timeout', '2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_appointment_date::text, 0));
    v_feasible := public.capacity_feasible(v_outlet, v_demands, 'hard');
    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_group_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Group needs more anonymous ' || coalesce(v_feasible ->> 'dimension','therapist') || ' capacity.';
      return next; return;
    end if;
  else
    for v_allocation in select value from jsonb_array_elements(p_allocations) loop
      v_therapist_id := (v_allocation ->> 'therapist_id')::uuid; v_room_id := (v_allocation ->> 'room_id')::uuid;
      v_start := (v_allocation ->> 'start_time')::time; v_end := (v_allocation ->> 'end_time')::time;
      if v_start is null or v_end is null or v_end = v_start then
        success := false; appointment_group_id := null; error_code := 'INVALID_DURATION';
        error_message := 'One pax allocation has an invalid time range.'; return next; return;
      end if;
      v_start_at := public.csp_start_at(p_appointment_date, v_start);
      v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);
      select * into v_check from public.check_booking_availability(p_appointment_date, v_start, v_end, v_therapist_id, v_room_id);
      if not coalesce(v_check.therapist_available, false) then
        success := false; appointment_group_id := null; error_code := 'THERAPIST_UNAVAILABLE';
        error_message := 'One pax allocation has a staff conflict.'; return next; return;
      end if;
      select count(*) into v_group_conflicts from jsonb_array_elements(p_allocations) other
        where (other.value ->> 'therapist_id')::uuid = v_therapist_id
          and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
          and public.csp_end_at(p_appointment_date, (other.value ->> 'start_time')::time, (other.value ->> 'end_time')::time) > v_start_at;
      if v_group_conflicts > 1 then
        success := false; appointment_group_id := null; error_code := 'THERAPIST_UNAVAILABLE';
        error_message := 'The same staff cannot serve overlapping pax in one group.'; return next; return;
      end if;
      select count(*) into v_group_room_slots from jsonb_array_elements(p_allocations) other
        where (other.value ->> 'room_id')::uuid = v_room_id
          and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
          and public.csp_end_at(p_appointment_date, (other.value ->> 'start_time')::time, (other.value ->> 'end_time')::time) > v_start_at;
      if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots > coalesce(v_check.room_total_slots, 1) then
        success := false; appointment_group_id := null; error_code := 'ROOM_FULL';
        error_message := 'A room or zone does not have enough slots for this group.'; return next; return;
      end if;
    end loop;
  end if;

  insert into public.appointment_groups (customer_id, group_name, pax_count, appointment_date, status, notes, created_at, created_by)
  values (p_customer_id, coalesce(p_group_name, ''), greatest(coalesce(p_pax_count, jsonb_array_length(p_allocations)), 1),
          p_appointment_date, coalesce(nullif(p_status, ''), 'confirmed'), coalesce(p_notes, ''), now(), p_created_by)
  returning id into appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid; v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time; v_end := (v_allocation ->> 'end_time')::time;
    v_source := coalesce(nullif(v_allocation ->> 'assignment_source',''),'queue');
    if v_use_anon and v_source in ('queue','gender_preference') then
      v_therapist_id := null; v_room_id := null;
    end if;
    insert into public.appointments (
      appointment_group_id, customer_id, therapist_id, room_id, service_id,
      appointment_date, start_time, end_time, start_at, end_at, status, total_price, type,
      service_name, service_items, item_count, notes, created_at, created_by,
      assignment_source, requested_therapist_id, requested_gender,
      therapist_assignment_state, room_assignment_state)
    values (
      appointment_group_id, p_customer_id, v_therapist_id, v_room_id, v_service_id,
      p_appointment_date, v_start, v_end,
      public.csp_start_at(p_appointment_date, v_start), public.csp_end_at(p_appointment_date, v_start, v_end),
      'confirmed', coalesce((v_allocation ->> 'total_price')::numeric, 0),
      coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
      coalesce(v_allocation ->> 'service_name', ''), coalesce((v_allocation -> 'service_items'), '[]'::jsonb),
      greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1), coalesce(v_allocation ->> 'notes', ''),
      now(), p_created_by, v_source,
      nullif(v_allocation ->> 'requested_therapist_id', '')::uuid, nullif(v_allocation ->> 'requested_gender', ''),
      'pending', 'pending')
    returning id into v_new_appointment_id;
    appointment_ids := array_append(appointment_ids, v_new_appointment_id);
  end loop;
  success := true; error_code := null; error_message := null; return next;
end;
$$;


--
-- Name: create_appointment_with_csp(uuid, uuid, uuid, uuid, date, time without time zone, time without time zone, numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_appointment_with_csp(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_price numeric, p_type text DEFAULT 'appointment'::text, p_created_by uuid DEFAULT auth.uid(), p_service_name text DEFAULT ''::text, p_service_items jsonb DEFAULT '[]'::jsonb, p_item_count integer DEFAULT 1, p_notes text DEFAULT ''::text, p_appointment_group_id uuid DEFAULT NULL::uuid, p_assignment_source text DEFAULT 'queue'::text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text, p_is_provisional boolean DEFAULT false) RETURNS TABLE(success boolean, appointment_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
declare
  v_start_at timestamp;
  v_end_at timestamp;
  v_outlet uuid;
  v_buffer integer;
  v_room_type text;
  v_type text := coalesce(nullif(p_type, ''), 'appointment');
  v_source text := coalesce(nullif(p_assignment_source, ''), 'queue');
  v_feasible jsonb;
  v_therapist_id uuid := p_therapist_id;
  v_room_id uuid := p_room_id;
  v_requested_therapist uuid := p_requested_therapist_id;
  v_room_total_slots integer;
  v_room_overlap_count integer;
  v_hold_overlap_count integer;
begin
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false; appointment_id := null; error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.'; return next; return;
  end if;

  v_start_at := public.csp_start_at(p_date, p_start_time);
  v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);

  select s.outlet_id, coalesce(s.buffer_after_minutes, 0), lower(trim(coalesce(s.room_type::text, '')))
    into v_outlet, v_buffer, v_room_type
  from public.services s where s.id = p_service_id;

  if v_outlet is not null
     and v_type <> 'walkin'
     and public.capacity_first_enabled(v_outlet) then

    if v_source = 'specific_customer_request' then
      v_requested_therapist := coalesce(v_requested_therapist, v_therapist_id);
      if v_therapist_id is null or v_requested_therapist is null
         or v_requested_therapist is distinct from v_therapist_id then
        success := false; appointment_id := null; error_code := 'REQUESTED_THERAPIST_REQUIRED';
        error_message := 'A specific customer request needs an exact matching therapist.'; return next; return;
      end if;
      v_room_id := null;
    elsif v_source = 'manual_override' then
      if v_therapist_id is null and v_room_id is null then
        success := false; appointment_id := null; error_code := 'MANUAL_RESOURCE_REQUIRED';
        error_message := 'A manual override must lock a therapist, a room, or both.'; return next; return;
      end if;
      v_requested_therapist := coalesce(v_requested_therapist, v_therapist_id);
    else
      v_therapist_id := null; v_room_id := null; v_requested_therapist := null;
    end if;

    perform set_config('lock_timeout', '2s', true);
    begin
      perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_date::text, 0));
    exception
      when lock_not_available then
        perform set_config('lock_timeout', '0', true);
        success := false; appointment_id := null; error_code := 'RESOURCE_LOCK_TIMEOUT';
        error_message := 'The outlet is busy. Please retry.'; return next; return;
    end;
    perform set_config('lock_timeout', '0', true);

    if v_room_id is not null then
      select coalesce(sum(greatest(coalesce(r.total_slots, 1), 1)), 0) into v_room_total_slots
      from public.rooms r
      where r.id = v_room_id and r.outlet_id = v_outlet and coalesce(r.is_active, true)
        and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type;

      if coalesce(v_room_total_slots, 0) = 0 then
        success := false; appointment_id := null; error_code := 'INVALID_ROOM';
        error_message := 'The selected room is inactive, in another outlet, or the wrong room type for this service.';
        return next; return;
      end if;

      select count(*) into v_room_overlap_count
      from public.appointments a
      where a.room_id = v_room_id
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < v_end_at + make_interval(mins => greatest(v_buffer, 0))
        and public.csp_appointment_block_end_at(a) > v_start_at;

      select count(*) into v_hold_overlap_count
      from public.booking_holds h
      where h.assigned_room_id = v_room_id and h.status = 'pending_payment'
        and h.expires_at > now() and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at + make_interval(mins => greatest(v_buffer, 0))
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_start_at;

      if v_room_overlap_count + v_hold_overlap_count >= v_room_total_slots then
        success := false; appointment_id := null; error_code := 'ROOM_FULL';
        error_message := 'The selected room is full for the requested time.'; return next; return;
      end if;
    end if;

    v_feasible := public.capacity_feasible(v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', p_service_id::text,
        'room_type', v_room_type, 'requested_gender', p_requested_gender,
        'requested_therapist_id', case when v_source = 'specific_customer_request' then v_requested_therapist::text else null end,
        'manual_lock_id', case when v_source = 'manual_override' and v_therapist_id is not null then v_therapist_id::text else null end,
        'pax_index', 0)), 'hard');

    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough capacity for the requested time.'; return next; return;
    end if;

    insert into public.appointments (
      appointment_group_id, customer_id, therapist_id, room_id, service_id,
      appointment_date, start_time, end_time, start_at, end_at, status, total_price, type,
      booked_date, booked_start_time, booked_end_time, booked_start_at, booked_end_at,
      service_name, service_items, item_count, notes, created_at, created_by,
      assignment_source, requested_therapist_id, requested_gender,
      therapist_assignment_state, room_assignment_state, outlet_id)
    values (
      p_appointment_group_id, p_customer_id, v_therapist_id, v_room_id, p_service_id,
      p_date, p_start_time, p_end_time, v_start_at, v_end_at, 'confirmed', p_total_price,
      v_type::public.appointment_type,
      p_date, p_start_time, p_end_time,
      v_start_at at time zone 'Asia/Kuala_Lumpur', v_end_at at time zone 'Asia/Kuala_Lumpur',
      coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb),
      greatest(coalesce(p_item_count, 1), 1), coalesce(p_notes, ''), now(), p_created_by,
      v_source, v_requested_therapist, p_requested_gender,
      case when v_therapist_id is not null then 'confirmed'::text else 'pending'::text end,
      case when v_room_id is not null then 'confirmed'::text else 'pending'::text end,
      v_outlet)
    returning id into appointment_id;

    success := true; error_code := null; error_message := null; return next; return;
  end if;

  return query select * from public.create_appointment_with_csp_121_legacy(
    p_customer_id, p_therapist_id, p_room_id, p_service_id, p_date, p_start_time, p_end_time,
    p_total_price, p_type, p_created_by, p_service_name, p_service_items, p_item_count,
    p_notes, p_appointment_group_id, p_assignment_source, p_requested_therapist_id,
    p_requested_gender, p_is_provisional);
end;
$$;


--
-- Name: create_appointment_with_csp_121_legacy(uuid, uuid, uuid, uuid, date, time without time zone, time without time zone, numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_appointment_with_csp_121_legacy(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_price numeric, p_type text DEFAULT 'appointment'::text, p_created_by uuid DEFAULT auth.uid(), p_service_name text DEFAULT ''::text, p_service_items jsonb DEFAULT '[]'::jsonb, p_item_count integer DEFAULT 1, p_notes text DEFAULT ''::text, p_appointment_group_id uuid DEFAULT NULL::uuid, p_assignment_source text DEFAULT 'queue'::text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text, p_is_provisional boolean DEFAULT false) RETURNS TABLE(success boolean, appointment_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_check record; v_start_at timestamp; v_end_at timestamp;
  v_outlet uuid; v_buffer integer; v_room_type text;
  v_source text := coalesce(nullif(p_assignment_source, ''), 'queue'); v_feasible jsonb;
begin
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false; appointment_id := null; error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.'; return next; return;
  end if;
  v_start_at := public.csp_start_at(p_date, p_start_time);
  v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);

  select s.outlet_id, coalesce(s.buffer_after_minutes, 0), lower(coalesce(s.room_type::text, ''))
    into v_outlet, v_buffer, v_room_type from public.services s where s.id = p_service_id;

  -- RC-1: a walk-in is an in-progress, physically present customer. It can never
  -- be anonymous future capacity demand, and the walk-in capacity guard rejects
  -- a NULL therapist outright.
  if v_outlet is not null and public.capacity_first_enabled(v_outlet)
     and coalesce(nullif(p_type, ''), 'appointment') <> 'walkin'
     and v_source in ('queue', 'gender_preference') then
    perform set_config('lock_timeout', '2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_date::text, 0));
    v_feasible := public.capacity_feasible(v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', p_service_id::text,
        'room_type', v_room_type, 'requested_gender', p_requested_gender, 'pax_index', 0)), 'hard');
    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough anonymous ' || coalesce(v_feasible ->> 'dimension', 'therapist') || ' capacity for the requested time.';
      return next; return;
    end if;
    insert into public.appointments (
      appointment_group_id, customer_id, therapist_id, room_id, service_id,
      appointment_date, start_time, end_time, start_at, end_at, status, total_price, type,
      service_name, service_items, item_count, notes, created_at, created_by,
      assignment_source, requested_therapist_id, requested_gender,
      therapist_assignment_state, room_assignment_state)
    values (
      p_appointment_group_id, p_customer_id, null, null, p_service_id,
      p_date, p_start_time, p_end_time, v_start_at, v_end_at, 'confirmed', p_total_price,
      coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
      coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb),
      greatest(coalesce(p_item_count, 1), 1), coalesce(p_notes, ''), now(), p_created_by,
      v_source, p_requested_therapist_id, p_requested_gender, 'pending', 'pending')
    returning id into appointment_id;
    success := true; error_code := null; error_message := null; return next; return;
  end if;

  select * into v_check from public.check_booking_availability(p_date, p_start_time, p_end_time, p_therapist_id, p_room_id);
  if not coalesce(v_check.therapist_available, false) then
    success := false; appointment_id := null; error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.'; return next; return;
  end if;
  if coalesce(v_check.room_full, false) then
    success := false; appointment_id := null; error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.'; return next; return;
  end if;
  insert into public.appointments (
    appointment_group_id, customer_id, therapist_id, room_id, service_id,
    appointment_date, start_time, end_time, start_at, end_at, status, total_price, type,
    service_name, service_items, item_count, notes, created_at, created_by,
    assignment_source, requested_therapist_id, requested_gender)
  values (
    p_appointment_group_id, p_customer_id, p_therapist_id, p_room_id, p_service_id,
    p_date, p_start_time, p_end_time, v_start_at, v_end_at, 'confirmed', p_total_price,
    coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
    coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb),
    greatest(coalesce(p_item_count, 1), 1), coalesce(p_notes, ''), now(), p_created_by,
    coalesce(nullif(p_assignment_source, ''), 'queue'), p_requested_therapist_id, p_requested_gender)
  returning id into appointment_id;
  success := true; error_code := null; error_message := null; return next;
end;
$$;


--
-- Name: create_public_booking_group_hold_v1(jsonb, timestamp with time zone, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_public_booking_group_hold_v1(p_allocations jsonb, p_start_at timestamp with time zone, p_customer_name text, p_customer_phone text, p_customer_email text, p_notes text DEFAULT ''::text, p_request_fingerprint text DEFAULT ''::text) RETURNS TABLE(group_token uuid, hold_expires_at timestamp with time zone, total_price numeric, guest_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_group_token uuid := gen_random_uuid();
  v_item record;
  v_hold record;
  v_total numeric := 0;
  v_expiry timestamptz;
  v_count integer := jsonb_array_length(coalesce(p_allocations, '[]'::jsonb));
begin
  if jsonb_typeof(p_allocations) <> 'array' or v_count < 1 or v_count > 6 then
    raise exception 'A group must contain between 1 and 6 guests';
  end if;

  for v_item in
    select a.value, a.ordinality
    from jsonb_array_elements(p_allocations) with ordinality a
    order by (lower(coalesce(a.value->>'therapist_preference', 'none')) = 'none'), a.ordinality
  loop
    select * into v_hold
    from public.create_public_booking_hold_v2(
      (v_item.value->>'catalogue_id')::uuid,
      p_start_at,
      coalesce(v_item.value->>'therapist_preference', 'none'),
      p_customer_name,
      p_customer_phone,
      p_customer_email,
      coalesce(v_item.value->>'therapist_request', ''),
      p_notes,
      p_request_fingerprint
    );

    update public.booking_holds
    set booking_group_token = v_group_token,
        guest_index = v_item.ordinality,
        guest_name = left(coalesce(nullif(trim(v_item.value->>'guest_name'), ''),
          'Guest ' || v_item.ordinality), 80),
        updated_at = now()
    where id = v_hold.hold_id;

    v_total := v_total + v_hold.total_price;
    v_expiry := case when v_expiry is null then v_hold.hold_expires_at
      else least(v_expiry, v_hold.hold_expires_at) end;
  end loop;

  group_token := v_group_token;
  hold_expires_at := v_expiry;
  total_price := v_total;
  guest_count := v_count;
  return next;
end;
$$;


--
-- Name: create_public_booking_hold_v2(uuid, timestamp with time zone, text, text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_public_booking_hold_v2(p_catalogue_id uuid, p_start_at timestamp with time zone, p_therapist_preference text, p_customer_name text, p_customer_phone text, p_customer_email text, p_therapist_request text DEFAULT ''::text, p_notes text DEFAULT ''::text, p_request_fingerprint text DEFAULT ''::text) RETURNS TABLE(hold_id uuid, hold_token uuid, hold_expires_at timestamp with time zone, total_price numeric, deposit_due numeric, duration_minutes integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_cfg public.online_booking_services%rowtype; v_service public.services%rowtype;
  v_pref text := lower(coalesce(p_therapist_preference, 'none'));
  v_local_start timestamp := p_start_at at time zone 'Asia/Kuala_Lumpur';
  v_end_at timestamptz; v_block_start timestamptz; v_block_end timestamptz;
  v_therapist uuid; v_room uuid;
begin
  if length(trim(p_customer_name)) < 2 or length(trim(p_customer_phone)) < 8 or position('@' in p_customer_email) < 2 then
    raise exception 'Valid customer details are required'; end if;
  select * into v_cfg from public.online_booking_services where id = p_catalogue_id;
  if not found then raise exception 'Online treatment is unavailable'; end if;
  select * into v_service from public.services where id = v_cfg.service_id and outlet_id = v_cfg.outlet_id;
  perform pg_advisory_xact_lock(hashtextextended(v_cfg.outlet_id::text || '|' || v_local_start::date::text, 0));
  perform public.expire_stale_booking_holds();
  if not exists(select 1 from public.get_public_booking_slots_v2(v_cfg.id, v_local_start::date, v_pref) s where s.start_at = p_start_at) then
    raise exception 'The selected time is no longer available'; end if;
  if trim(p_request_fingerprint) <> '' and (select count(*) from public.booking_holds h
      where h.request_fingerprint = trim(p_request_fingerprint) and h.created_at > now() - interval '1 hour') >= 12 then
    raise exception 'Too many booking attempts. Please try again later'; end if;

  v_end_at := p_start_at + make_interval(mins => greatest(v_service.duration, 1));
  v_block_start := p_start_at - make_interval(mins => v_cfg.buffer_before_minutes);
  v_block_end := v_end_at + make_interval(mins => v_cfg.buffer_after_minutes);

  select t.id into v_therapist from public.therapists t
  where t.outlet_id = v_cfg.outlet_id and coalesce(t.availability_status, true)
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
    and (v_pref = 'none' or lower(coalesce(t.gender, '')) = v_pref)
    and (coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb or t.service_commissions ? v_cfg.service_id::text)
    and exists (select 1 from public.therapist_working_hours wh where wh.therapist_id = t.id
      and wh.day_of_week = extract(dow from v_local_start)::integer
      and v_local_start::date + wh.start_time <= (v_block_start at time zone 'Asia/Kuala_Lumpur')
      and v_local_start::date + wh.end_time
        + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
        >= (v_block_end at time zone 'Asia/Kuala_Lumpur'))
    and not exists (select 1 from public.therapist_unavailability u where u.therapist_id=t.id and u.starts_at<v_block_end and u.ends_at>v_block_start)
    and not exists (select 1 from public.appointments a where a.therapist_id=t.id and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < (v_block_end at time zone 'Asia/Kuala_Lumpur')
      and public.csp_appointment_block_end_at(a) > (v_block_start at time zone 'Asia/Kuala_Lumpur'))
    and not exists (select 1 from public.booking_holds h where h.assigned_therapist_id=t.id and h.status='pending_payment'
      and h.expires_at>now()
      and h.start_at-make_interval(mins=>h.buffer_before_minutes)<v_block_end
      and h.end_at+make_interval(mins=>h.buffer_after_minutes)>v_block_start)
  order by t.name for update of t skip locked limit 1;
  if v_therapist is null then raise exception 'The selected time is no longer available'; end if;

  select r.id into v_room from public.rooms r join public.online_booking_service_rooms cr on cr.room_id=r.id
  where cr.online_booking_service_id=v_cfg.id and coalesce(r.is_active,true)
    and coalesce(r.total_slots,1) >
      (select count(*) from public.appointments a where a.room_id=r.id and public.csp_blocks_schedule(a.status::text)
       and public.csp_appointment_start_at(a)<(v_block_end at time zone 'Asia/Kuala_Lumpur') and public.csp_appointment_block_end_at(a)>(v_block_start at time zone 'Asia/Kuala_Lumpur')) +
      (select count(*) from public.booking_holds h where h.assigned_room_id=r.id and h.status='pending_payment'
       and h.expires_at>now()
       and h.start_at-make_interval(mins=>h.buffer_before_minutes)<v_block_end
       and h.end_at+make_interval(mins=>h.buffer_after_minutes)>v_block_start)
  order by r.name for update of r skip locked limit 1;
  if v_room is null then raise exception 'The selected time is no longer available'; end if;

  insert into public.booking_holds(outlet_id, online_booking_service_id, customer_name, customer_phone, customer_email,
    therapist_preference, therapist_request, assigned_therapist_id, assigned_room_id, service_items,
    start_at, end_at, total_amount, deposit_amount, buffer_before_minutes, buffer_after_minutes,
    status, expires_at, notes, request_fingerprint)
  values(v_cfg.outlet_id, v_cfg.id, trim(p_customer_name), trim(p_customer_phone), lower(trim(p_customer_email)),
    v_pref, left(trim(p_therapist_request),200), v_therapist, v_room,
    jsonb_build_array(jsonb_build_object('service_id',v_cfg.service_id,'public_name',v_cfg.public_name,
      'duration',v_service.duration,'display_price',v_cfg.display_price,'deposit',v_cfg.deposit_amount)),
    p_start_at, v_end_at, v_cfg.display_price, v_cfg.deposit_amount, v_cfg.buffer_before_minutes, v_cfg.buffer_after_minutes,
    'pending_payment', now()+interval '10 minutes', left(trim(p_notes),500), left(trim(p_request_fingerprint),128))
  returning booking_holds.id, booking_holds.public_token, booking_holds.expires_at
  into hold_id, hold_token, hold_expires_at;
  total_price := v_cfg.display_price; deposit_due := v_cfg.deposit_amount; duration_minutes := v_service.duration; return next;
end; $$;


--
-- Name: create_staff_walkin_and_start_with_payment(uuid, uuid, uuid, uuid, uuid, date, time without time zone, time without time zone, numeric, text, jsonb, integer, text, text, text, uuid, text, numeric, numeric, text, text, text, text, text, uuid, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_staff_walkin_and_start_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text, p_draft_session_id text DEFAULT NULL::text, p_assignment_source text DEFAULT 'queue'::text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT now()) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, actual_started_at timestamp with time zone, expected_end_at timestamp without time zone, therapist_id uuid, room_id uuid, room_unit_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_created record;
  v_started record;
  v_detail text;
  v_state text;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  begin
    select *
    into v_created
    from public.create_staff_walkin_with_payment(
      p_customer_id => p_customer_id,
      p_therapist_id => p_therapist_id,
      p_room_id => p_room_id,
      p_service_id => p_service_id,
      p_date => p_date,
      p_start_time => p_start_time,
      p_end_time => p_end_time,
      p_service_price => p_service_price,
      p_service_name => p_service_name,
      p_service_items => p_service_items,
      p_item_count => p_item_count,
      p_notes => p_notes,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_sst_amount => p_sst_amount,
      p_total_amount => p_total_amount,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number,
      p_transaction_notes => p_transaction_notes,
      p_start_immediately => false,
      p_draft_session_id => p_draft_session_id,
      p_assignment_source => p_assignment_source,
      p_requested_therapist_id => p_requested_therapist_id,
      p_requested_gender => p_requested_gender
    );
    if not coalesce(v_created.success, false) then
      return query select false, null::uuid, null::uuid, null::timestamptz,
        null::timestamp, null::uuid, null::uuid, null::uuid,
        v_created.error_code, v_created.error_message;
      return;
    end if;

    update public.appointments a
    set payment_status = 'paid',
        room_unit_id = p_room_unit_id,
        updated_at = now()
    where a.id = v_created.appointment_id;

    select *
    into v_started
    from public.finalize_and_start_appointment(
      p_appointment_id => v_created.appointment_id,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_guest_name => p_customer_name,
      p_guest_phone => p_customer_phone,
      p_service_items => p_service_items,
      p_payment_items => '[]'::jsonb,
      p_therapist_id => p_therapist_id,
      p_assignment_source => p_assignment_source,
      p_requested_gender => p_requested_gender,
      p_room_id => p_room_id,
      p_room_unit_id => p_room_unit_id,
      p_started_at => p_started_at,
      p_expected_end_at => null,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_service_price => 0,
      p_sst_amount => 0,
      p_total_amount => 0,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number
    );
    if not coalesce(v_started.success, false) then
      raise exception using errcode = 'P0001',
        message = coalesce(v_started.error_message, 'Unable to start service.');
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, null::uuid, null::uuid, null::timestamptz,
      null::timestamp, null::uuid, null::uuid, null::uuid,
      coalesce(v_state, 'WALKIN_START_FAILED'),
      coalesce(v_detail, 'Unable to create and start walk-in service.');
    return;
  end;

  return query select true, v_started.appointment_id,
    v_created.transaction_id, v_started.actual_started_at,
    v_started.expected_end_at, v_started.therapist_id, v_started.room_id,
    v_started.room_unit_id, null::text, null::text;
end;
$$;


--
-- Name: create_staff_walkin_group_and_start_with_payment(uuid, text, integer, date, jsonb, text, text, text, uuid, text, numeric, numeric, numeric, text, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_staff_walkin_group_and_start_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text, p_draft_session_id text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT now()) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], transaction_id uuid, actual_started_at timestamp with time zone, started_count integer, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_created record;
  v_started record;
  v_alloc jsonb;
  v_id uuid;
  v_index integer := 0;
  v_updates jsonb := '{}'::jsonb;
  v_detail text;
  v_state text;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  begin
    select *
    into v_created
    from public.create_staff_walkin_group_with_payment(
      p_customer_id => p_customer_id,
      p_group_name => p_group_name,
      p_pax_count => p_pax_count,
      p_appointment_date => p_appointment_date,
      p_allocations => p_allocations,
      p_notes => p_notes,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_service_price => p_service_price,
      p_sst_amount => p_sst_amount,
      p_total_amount => p_total_amount,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number,
      p_transaction_notes => p_transaction_notes,
      p_start_immediately => false,
      p_draft_session_id => p_draft_session_id
    );
    if not coalesce(v_created.success, false) then
      return query select false, null::uuid, array[]::uuid[], null::uuid,
        null::timestamptz, 0, v_created.error_code, v_created.error_message;
      return;
    end if;

    if cardinality(v_created.appointment_ids)
         <> jsonb_array_length(p_allocations) then
      raise exception 'Created appointment count does not match the walk-in group.';
    end if;

    foreach v_id in array v_created.appointment_ids loop
      v_alloc := p_allocations -> v_index;
      v_updates := v_updates || jsonb_build_object(
        v_id::text,
        jsonb_build_object(
          'guest_name', coalesce(
            nullif(v_alloc ->> 'guest_name', ''),
            format('Guest %s', v_index + 1)
          ),
          'guest_phone', coalesce(v_alloc ->> 'guest_phone', ''),
          'service_items', coalesce(v_alloc -> 'service_items', '[]'::jsonb),
          'therapist_id', v_alloc ->> 'therapist_id',
          'assignment_source', coalesce(
            nullif(v_alloc ->> 'assignment_source', ''),
            'queue'
          ),
          'requested_gender', v_alloc ->> 'requested_gender',
          'room_id', v_alloc ->> 'room_id',
          'room_unit_id', v_alloc ->> 'room_unit_id'
        )
      );
      v_index := v_index + 1;
    end loop;

    update public.appointments a
    set payment_status = 'paid', updated_at = now()
    where a.id = any(v_created.appointment_ids);

    select *
    into v_started
    from public.finalize_and_start_appointment_group(
      p_appointment_group_id => v_created.appointment_group_id,
      p_appointment_ids => v_created.appointment_ids,
      p_customer_name => p_customer_name,
      p_customer_phone => p_customer_phone,
      p_pax_updates => v_updates,
      p_payment_items => '[]'::jsonb,
      p_started_at => p_started_at,
      p_counter_staff_id => p_counter_staff_id,
      p_counter_staff_name => p_counter_staff_name,
      p_service_price => 0,
      p_sst_amount => 0,
      p_total_amount => 0,
      p_payment_method => p_payment_method,
      p_receipt_number => p_receipt_number
    );
    if not coalesce(v_started.success, false) then
      raise exception using errcode = 'P0001',
        message = coalesce(
          v_started.error_message,
          'Unable to start every guest in the group.'
        );
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, null::uuid, array[]::uuid[], null::uuid,
      null::timestamptz, 0,
      coalesce(v_state, 'WALKIN_GROUP_START_FAILED'),
      coalesce(v_detail, 'Unable to create and start walk-in group.');
    return;
  end;

  return query select true, v_started.appointment_group_id,
    v_started.appointment_ids, v_created.transaction_id,
    v_started.actual_started_at, v_started.started_count,
    null::text, null::text;
end;
$$;


--
-- Name: create_staff_walkin_group_with_payment(uuid, text, integer, date, jsonb, text, text, text, uuid, text, numeric, numeric, numeric, text, text, text, boolean, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_staff_walkin_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text, p_start_immediately boolean DEFAULT true, p_draft_session_id text DEFAULT NULL::text, p_created_by uuid DEFAULT auth.uid()) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_existing record;
  v_create record;
  v_alloc jsonb;
  v_therapist_text text;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_outlet_id uuid;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_transaction_id uuid;
  v_idx integer := 0;
  v_appointment_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  for v_therapist_text in
    select distinct value ->> 'therapist_id'
    from jsonb_array_elements(p_allocations)
    order by value ->> 'therapist_id'
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_therapist_text, 0));
  end loop;
  for v_therapist_text in
    select distinct 'room:' || (value ->> 'room_id')
    from jsonb_array_elements(p_allocations)
    order by 'room:' || (value ->> 'room_id')
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_therapist_text, 0));
  end loop;

  if p_draft_session_id is not null then
    update public.booking_holds h
    set status = 'cancelled', updated_at = now()
    where h.hold_kind = 'staff_walkin_draft'
      and h.draft_session_id = p_draft_session_id
      and h.status = 'pending_payment';
  end if;

  if p_start_immediately then
    select * into v_existing
    from public.create_walkin_appointment_group_with_payment(
      p_customer_id, p_group_name, p_pax_count, p_appointment_date, p_allocations,
      p_notes, p_customer_name, p_customer_phone, p_counter_staff_id,
      p_counter_staff_name, p_service_price, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes, p_created_by
    );
    success := v_existing.success;
    appointment_group_id := v_existing.appointment_group_id;
    appointment_ids := v_existing.appointment_ids;
    transaction_id := v_existing.transaction_id;
    error_code := v_existing.error_code;
    error_message := v_existing.error_message;
    return next;
    return;
  end if;

  perform set_config('app.ignore_cleanup_buffer', 'on', true);
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  select * into v_create
  from public.create_appointment_group_with_csp(
    p_customer_id => p_customer_id,
    p_group_name => p_group_name,
    p_pax_count => p_pax_count,
    p_appointment_date => p_appointment_date,
    p_allocations => p_allocations,
    p_type => 'walkin',
    p_status => 'confirmed',
    p_notes => p_notes,
    p_created_by => p_created_by
  );
  if not coalesce(v_create.success, false) then
    success := false;
    appointment_group_id := null;
    appointment_ids := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    v_idx := v_idx + 1;
    v_all_items := v_all_items || coalesce(v_alloc -> 'service_items', '[]'::jsonb);
    v_item_count := v_item_count
      + jsonb_array_length(coalesce(v_alloc -> 'service_items', '[]'::jsonb));
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_alloc -> 'service_items',
          nullif(v_alloc ->> 'therapist_id', '')::uuid,
          'Therapist'
        );
    if v_idx = 1 then
      v_first_therapist_id := nullif(v_alloc ->> 'therapist_id', '')::uuid;
      v_first_room_id := nullif(v_alloc ->> 'room_id', '')::uuid;
      v_first_service_id := nullif(v_alloc ->> 'service_id', '')::uuid;
      v_first_service_name := v_alloc ->> 'service_name';
    end if;
  end loop;

  select t.name into v_first_therapist_name
  from public.therapists t where t.id = v_first_therapist_id;
  select r.name into v_first_room_name
  from public.rooms r where r.id = v_first_room_id;
  select a.outlet_id into v_outlet_id
  from public.appointments a
  where a.appointment_group_id = v_create.appointment_group_id
  limit 1;
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_outlet_id, v_create.appointment_group_id, p_customer_id,
    coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items,
    greatest(v_item_count, 1), v_first_therapist_id,
    coalesce(v_first_therapist_name, ''), p_counter_staff_id,
    p_counter_staff_name, v_first_room_id, coalesce(v_first_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
    coalesce(p_total_amount, 0), v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    coalesce(p_transaction_notes, '')
  ) returning id into v_transaction_id;

  foreach v_appointment_id in array v_create.appointment_ids loop
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    )
    select a.id, a.therapist_id, 1, 'full', p_created_by
    from public.appointments a where a.id = v_appointment_id
    on conflict (appointment_id, therapist_id) do update
      set commission_share = 1, allocation_method = 'full', updated_at = now();
    perform public.recalculate_appointment_therapist_commission(v_appointment_id);
  end loop;

  success := true;
  appointment_group_id := v_create.appointment_group_id;
  appointment_ids := v_create.appointment_ids;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;


--
-- Name: create_staff_walkin_with_payment(uuid, uuid, uuid, uuid, date, time without time zone, time without time zone, numeric, text, jsonb, integer, text, text, text, uuid, text, numeric, numeric, text, text, text, boolean, text, uuid, text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_staff_walkin_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text, p_start_immediately boolean DEFAULT true, p_draft_session_id text DEFAULT NULL::text, p_created_by uuid DEFAULT auth.uid(), p_assignment_source text DEFAULT 'queue'::text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_create record;
  v_outlet_id uuid;
  v_therapist_name text;
  v_room_name text;
  v_therapist_commission numeric;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_therapist_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('room:' || p_room_id::text, 0));

  if p_draft_session_id is not null then
    update public.booking_holds
    set status = 'cancelled', updated_at = now()
    where hold_kind = 'staff_walkin_draft'
      and draft_session_id = p_draft_session_id
      and status = 'pending_payment';
  end if;

  perform set_config('app.ignore_cleanup_buffer', 'on', true);
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  select * into v_create
  from public.create_appointment_with_csp(
    p_customer_id => p_customer_id,
    p_therapist_id => p_therapist_id,
    p_room_id => p_room_id,
    p_service_id => p_service_id,
    p_date => p_date,
    p_start_time => p_start_time,
    p_end_time => p_end_time,
    p_total_price => p_service_price,
    p_type => 'walkin',
    p_created_by => p_created_by,
    p_service_name => p_service_name,
    p_service_items => p_service_items,
    p_item_count => p_item_count,
    p_notes => p_notes,
    p_assignment_source => coalesce(
      nullif(p_assignment_source, ''),
      'queue'
    ),
    p_requested_therapist_id => p_requested_therapist_id,
    p_requested_gender => p_requested_gender
  );

  if not coalesce(v_create.success, false) then
    success := false;
    appointment_id := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  if p_start_immediately then
    update public.appointments appointment
    set status = 'in_progress',
        actual_started_at = now(),
        updated_at = now()
    where appointment.id = v_create.appointment_id
    returning appointment.outlet_id into v_outlet_id;
  else
    select appointment.outlet_id
    into v_outlet_id
    from public.appointments appointment
    where appointment.id = v_create.appointment_id;
  end if;

  select therapist.name into v_therapist_name
  from public.therapists therapist
  where therapist.id = p_therapist_id;

  select room.name into v_room_name
  from public.rooms room
  where room.id = p_room_id;

  v_therapist_commission := public.csp_commission_for_items(
    p_service_items,
    p_therapist_id,
    'Therapist'
  );
  v_counter_commission := case
    when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(
      p_service_items,
      p_counter_staff_id,
      'Counter'
    )
  end;

  insert into public.transactions (
    outlet_id,
    appointment_id,
    customer_id,
    customer_name,
    customer_phone,
    service_id,
    service_name,
    service_items,
    item_count,
    therapist_id,
    therapist_name,
    counter_staff_id,
    counter_staff_name,
    room_id,
    room_name,
    service_price,
    sst_amount,
    total_amount,
    therapist_commission_amount,
    counter_commission_amount,
    source,
    payment_method,
    payment_status,
    receipt_number,
    notes
  ) values (
    v_outlet_id,
    v_create.appointment_id,
    p_customer_id,
    coalesce(p_customer_name, ''),
    coalesce(p_customer_phone, ''),
    p_service_id,
    coalesce(p_service_name, ''),
    coalesce(p_service_items, '[]'::jsonb),
    greatest(coalesce(p_item_count, 1), 1),
    p_therapist_id,
    coalesce(v_therapist_name, ''),
    p_counter_staff_id,
    p_counter_staff_name,
    p_room_id,
    coalesce(v_room_name, ''),
    coalesce(p_service_price, 0),
    coalesce(p_sst_amount, 0),
    coalesce(p_total_amount, 0),
    v_therapist_commission,
    v_counter_commission,
    'walkin',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status,
    p_receipt_number,
    coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  insert into public.appointment_therapist_allocations (
    appointment_id,
    therapist_id,
    commission_share,
    allocation_method,
    created_by
  ) values (
    v_create.appointment_id,
    p_therapist_id,
    1,
    'full',
    p_created_by
  )
  on conflict on constraint
    appointment_therapist_allocatio_appointment_id_therapist_id_key
  do update set
    commission_share = 1,
    allocation_method = 'full',
    updated_at = now();

  perform public.recalculate_appointment_therapist_commission(
    v_create.appointment_id
  );

  success := true;
  appointment_id := v_create.appointment_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;


--
-- Name: create_walkin_appointment_group_with_payment(uuid, text, integer, date, jsonb, text, text, text, uuid, text, numeric, numeric, numeric, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_walkin_appointment_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text, p_created_by uuid DEFAULT auth.uid()) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_create record;
  v_alloc jsonb;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_outlet_id uuid;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_transaction_id uuid;
  v_idx integer := 0;
  v_appointment_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_create
  from public.create_appointment_group_with_csp(
    p_customer_id => p_customer_id,
    p_group_name => p_group_name,
    p_pax_count => p_pax_count,
    p_appointment_date => p_appointment_date,
    p_allocations => p_allocations,
    p_type => 'walkin',
    p_status => 'in_progress',
    p_notes => p_notes,
    p_created_by => p_created_by
  );

  if not coalesce(v_create.success, false) then
    success := false;
    appointment_group_id := null;
    appointment_ids := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  update public.appointments a
  set actual_started_at = now(), updated_at = now()
  where a.appointment_group_id = v_create.appointment_group_id;

  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    v_idx := v_idx + 1;
    v_all_items := v_all_items || coalesce(v_alloc -> 'service_items', '[]'::jsonb);
    v_item_count := v_item_count
      + jsonb_array_length(coalesce(v_alloc -> 'service_items', '[]'::jsonb));
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_alloc -> 'service_items',
          nullif(v_alloc ->> 'therapist_id', '')::uuid,
          'Therapist'
        );
    if v_idx = 1 then
      v_first_therapist_id := nullif(v_alloc ->> 'therapist_id', '')::uuid;
      v_first_room_id := nullif(v_alloc ->> 'room_id', '')::uuid;
      v_first_service_id := nullif(v_alloc ->> 'service_id', '')::uuid;
      v_first_service_name := v_alloc ->> 'service_name';
    end if;
  end loop;

  select t.name into v_first_therapist_name
  from public.therapists t where t.id = v_first_therapist_id;
  select r.name into v_first_room_name
  from public.rooms r where r.id = v_first_room_id;
  select a.outlet_id into v_outlet_id
  from public.appointments a
  where a.appointment_group_id = v_create.appointment_group_id
  limit 1;

  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_outlet_id, v_create.appointment_group_id, p_customer_id,
    coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items,
    greatest(v_item_count, 1), v_first_therapist_id,
    coalesce(v_first_therapist_name, ''), p_counter_staff_id,
    p_counter_staff_name, v_first_room_id, coalesce(v_first_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
    coalesce(p_total_amount, 0), v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    coalesce(p_transaction_notes, '')
  ) returning id into v_transaction_id;

  foreach v_appointment_id in array v_create.appointment_ids loop
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    )
    select a.id, a.therapist_id, 1, 'full', p_created_by
    from public.appointments a where a.id = v_appointment_id
    on conflict (appointment_id, therapist_id) do update
      set commission_share = 1, allocation_method = 'full', updated_at = now();
    perform public.recalculate_appointment_therapist_commission(v_appointment_id);
  end loop;

  success := true;
  appointment_group_id := v_create.appointment_group_id;
  appointment_ids := v_create.appointment_ids;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;


--
-- Name: create_walkin_appointment_with_payment(uuid, uuid, uuid, uuid, date, time without time zone, time without time zone, numeric, text, jsonb, integer, text, text, text, uuid, text, numeric, numeric, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_walkin_appointment_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text, p_transaction_notes text DEFAULT ''::text, p_created_by uuid DEFAULT auth.uid()) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_create record;
  v_outlet_id uuid;
  v_therapist_name text;
  v_room_name text;
  v_therapist_commission numeric;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  select *
  into v_create
  from public.create_appointment_with_csp(
    p_customer_id => p_customer_id,
    p_therapist_id => p_therapist_id,
    p_room_id => p_room_id,
    p_service_id => p_service_id,
    p_date => p_date,
    p_start_time => p_start_time,
    p_end_time => p_end_time,
    p_total_price => p_service_price,
    p_type => 'walkin',
    p_created_by => p_created_by,
    p_service_name => p_service_name,
    p_service_items => p_service_items,
    p_item_count => p_item_count,
    p_notes => p_notes
  );

  if not coalesce(v_create.success, false) then
    success := false;
    appointment_id := null;
    transaction_id := null;
    error_code := v_create.error_code;
    error_message := v_create.error_message;
    return next;
    return;
  end if;

  update public.appointments
  set status = 'in_progress',
      actual_started_at = now(),
      updated_at = now()
  where id = v_create.appointment_id
  returning outlet_id into v_outlet_id;

  select name into v_therapist_name from public.therapists where id = p_therapist_id;
  select name into v_room_name from public.rooms where id = p_room_id;

  v_therapist_commission := public.csp_commission_for_items(p_service_items, p_therapist_id, 'Therapist');
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(p_service_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name,
    counter_staff_id, counter_staff_name,
    room_id, room_name,
    service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  )
  values (
    v_outlet_id, v_create.appointment_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    p_service_id, coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb), greatest(coalesce(p_item_count, 1), 1),
    p_therapist_id, coalesce(v_therapist_name, ''),
    p_counter_staff_id, p_counter_staff_name,
    p_room_id, coalesce(v_room_name, ''),
    coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method, 'paid'::public.payment_status,
    p_receipt_number, coalesce(p_transaction_notes, '')
  )
  returning id into v_transaction_id;

  success := true;
  appointment_id := v_create.appointment_id;
  transaction_id := v_transaction_id;
  error_code := null;
  error_message := null;
  return next;
end;
$$;


--
-- Name: csp_appointment_block_end_at(public.appointments); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_appointment_block_end_at(a public.appointments) RETURNS timestamp without time zone
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select public.csp_appointment_end_at(a)
    + make_interval(mins => greatest(coalesce(a.buffer_after_minutes, 0), 0));
$$;


--
-- Name: csp_appointment_end_at(public.appointments); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_appointment_end_at(a public.appointments) RETURNS timestamp without time zone
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce(a.end_at, public.csp_end_at(a.appointment_date::date, a.start_time::time, a.end_time::time));
$$;


--
-- Name: csp_appointment_start_at(public.appointments); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_appointment_start_at(a public.appointments) RETURNS timestamp without time zone
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce(a.start_at, public.csp_start_at(a.appointment_date::date, a.start_time::time));
$$;


--
-- Name: csp_blocks_schedule(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_blocks_schedule(p_status text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select lower(coalesce(p_status, '')) in ('confirmed', 'in_progress');
$$;


--
-- Name: csp_commission_for_items(jsonb, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_commission_for_items(p_service_items jsonb, p_staff_id uuid, p_role text) RETURNS numeric
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_overrides jsonb;
  v_is_counter boolean := position('counter' in lower(coalesce(p_role, ''))) > 0
    or position('cashier' in lower(coalesce(p_role, ''))) > 0;
  v_item jsonb;
  v_service_id uuid;
  v_total numeric := 0;
  v_default numeric;
begin
  if p_staff_id is null or p_service_items is null then
    return 0;
  end if;

  select coalesce(commission_overrides, '{}'::jsonb)
  into v_overrides
  from public.therapists
  where id = p_staff_id;

  for v_item in
    select value
    from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb))
  loop
    v_service_id := nullif(coalesce(
      v_item ->> 'id',
      v_item ->> 'serviceId',
      v_item ->> 'service_id'
    ), '')::uuid;
    if v_service_id is null then
      continue;
    end if;

    if v_overrides is not null and v_overrides ? v_service_id::text then
      v_total := v_total
        + coalesce((v_overrides ->> v_service_id::text)::numeric, 0);
      continue;
    end if;

    select case
      when v_is_counter then s.counter_commission
      else s.therapist_commission
    end
    into v_default
    from public.services s
    where s.id = v_service_id;

    v_total := v_total + coalesce(v_default, 0);
  end loop;

  return round(v_total, 2);
end;
$$;


--
-- Name: csp_commission_for_transaction_items(jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_commission_for_transaction_items(p_service_items jsonb, p_default_therapist_id uuid DEFAULT NULL::uuid) RETURNS numeric
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_item jsonb;
  v_appointment_id uuid;
  v_therapist_id uuid;
  v_total numeric := 0;
begin
  for v_item in
    select value from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb))
  loop
    v_appointment_id := nullif(coalesce(
      v_item ->> 'appointmentId', v_item ->> 'appointment_id'
    ), '')::uuid;
    v_therapist_id := nullif(coalesce(
      v_item ->> 'assignedTherapistId',
      v_item ->> 'assigned_therapist_id'
    ), '')::uuid;

    if v_therapist_id is null and v_appointment_id is not null then
      select a.therapist_id into v_therapist_id
      from public.appointments a where a.id = v_appointment_id;
    end if;
    v_therapist_id := coalesce(v_therapist_id, p_default_therapist_id);
    v_total := v_total + public.csp_commission_for_items(
      jsonb_build_array(v_item), v_therapist_id, 'Therapist'
    );
  end loop;
  return round(v_total, 2);
end;
$$;


--
-- Name: csp_end_at(date, time without time zone, time without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_end_at(p_date date, p_start_time time without time zone, p_end_time time without time zone) RETURNS timestamp without time zone
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select p_date
    + p_end_time
    + case when p_end_time <= p_start_time then interval '1 day' else interval '0' end;
$$;


--
-- Name: csp_start_at(date, time without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.csp_start_at(p_date date, p_start_time time without time zone) RETURNS timestamp without time zone
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select p_date + p_start_time;
$$;


--
-- Name: current_user_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_user_role() RETURNS public.user_role
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select role
  from public.profiles
  where id = auth.uid()
$$;


--
-- Name: enforce_appointment_outlet_consistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_appointment_outlet_consistency() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.outlet_id is null and new.therapist_id is not null then
    select t.outlet_id into new.outlet_id
    from public.therapists t where t.id = new.therapist_id;
  end if;
  if new.outlet_id is null and new.room_id is not null then
    select r.outlet_id into new.outlet_id
    from public.rooms r where r.id = new.room_id;
  end if;
  if new.outlet_id is null and new.service_id is not null then
    select s.outlet_id into new.outlet_id
    from public.services s where s.id = new.service_id;
  end if;
  if new.outlet_id is null and new.customer_id is not null then
    select c.outlet_id into new.outlet_id
    from public.customers c where c.id = new.customer_id;
  end if;
  if new.outlet_id is null then
    raise exception 'Unable to determine appointment outlet';
  end if;
  if new.customer_id is not null and not exists (
    select 1 from public.customers c where c.id = new.customer_id and c.outlet_id = new.outlet_id
  ) then
    raise exception 'Customer belongs to a different outlet';
  end if;
  if new.therapist_id is not null and not exists (
    select 1 from public.therapists t where t.id = new.therapist_id and t.outlet_id = new.outlet_id
  ) then
    raise exception 'Therapist belongs to a different outlet';
  end if;
  if new.room_id is not null and not exists (
    select 1 from public.rooms r where r.id = new.room_id and r.outlet_id = new.outlet_id
  ) then
    raise exception 'Room belongs to a different outlet';
  end if;
  if new.service_id is not null and not exists (
    select 1 from public.services s where s.id = new.service_id and s.outlet_id = new.outlet_id
  ) then
    raise exception 'Service belongs to a different outlet';
  end if;
  return new;
end;
$$;


--
-- Name: enforce_booking_hold_outlet_consistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_booking_hold_outlet_consistency() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.customer_id is not null and not exists (
    select 1 from public.customers c where c.id = new.customer_id and c.outlet_id = new.outlet_id
  ) then
    raise exception 'Customer belongs to a different outlet';
  end if;
  if new.assigned_therapist_id is not null and not exists (
    select 1 from public.therapists t where t.id = new.assigned_therapist_id and t.outlet_id = new.outlet_id
  ) then
    raise exception 'Therapist belongs to a different outlet';
  end if;
  if new.assigned_room_id is not null and not exists (
    select 1 from public.rooms r where r.id = new.assigned_room_id and r.outlet_id = new.outlet_id
  ) then
    raise exception 'Room belongs to a different outlet';
  end if;
  if new.appointment_id is not null and not exists (
    select 1 from public.appointments a where a.id = new.appointment_id and a.outlet_id = new.outlet_id
  ) then
    raise exception 'Appointment belongs to a different outlet';
  end if;
  return new;
end;
$$;


--
-- Name: enforce_mvp_concrete_appointment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_mvp_concrete_appointment() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_room_mode text;
begin
  -- Turning the preserved flag back on deliberately restores the dormant
  -- capacity-first contract without editing this migration.
  if public.capacity_first_enabled(new.outlet_id) then
    return new;
  end if;

  if new.actual_started_at is null
     and new.status::text in ('pending', 'confirmed') then
    if new.therapist_id is null then
      raise exception using errcode = '23514',
        message = 'A concrete therapist must be locked before saving.';
    end if;
    if new.room_id is null then
      raise exception using errcode = '23514',
        message = 'A concrete room or shared zone must be locked before saving.';
    end if;

    select room.allocation_mode
    into v_room_mode
    from public.rooms room
    where room.id = new.room_id
      and room.outlet_id = new.outlet_id
      and coalesce(room.is_active, true);

    if not found then
      raise exception using errcode = '23514',
        message = 'The locked room is inactive or belongs to another outlet.';
    end if;
    if coalesce(v_room_mode, 'capacity') = 'specific_room'
       and new.room_unit_id is null then
      raise exception using errcode = '23514',
        message = 'A body service must lock an exact numbered room.';
    end if;

    new.therapist_assignment_state := 'confirmed';
    new.room_assignment_state := 'confirmed';
    new.resources_confirmed_at := coalesce(
      new.resources_confirmed_at,
      now()
    );
  end if;

  return new;
end;
$$;


--
-- Name: enforce_no_future_service_progress(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_no_future_service_progress() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.status in ('in_progress', 'completed')
     and new.appointment_date > (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using
      errcode = '23514',
      message = 'Cannot start or complete a service before its appointment date.';
  end if;
  return new;
end;
$$;


--
-- Name: enforce_online_appointment_conversion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_online_appointment_conversion() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: enforce_online_booking_outlet_match(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_online_booking_outlet_match() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_parent_outlet uuid; v_resource_outlet uuid;
begin
  if tg_table_name = 'online_booking_service_rooms' then
    select outlet_id into v_parent_outlet from public.online_booking_services where id = new.online_booking_service_id;
    select outlet_id into v_resource_outlet from public.rooms where id = new.room_id;
  elsif tg_table_name = 'online_booking_service_hours' then
    select outlet_id into v_parent_outlet from public.online_booking_services where id = new.online_booking_service_id;
    v_resource_outlet := new.outlet_id;
  elsif tg_table_name in ('therapist_working_hours', 'therapist_unavailability') then
    select outlet_id into v_resource_outlet from public.therapists where id = new.therapist_id;
    v_parent_outlet := new.outlet_id;
  else
    select outlet_id into v_resource_outlet from public.services where id = new.service_id;
    v_parent_outlet := new.outlet_id;
  end if;
  if v_parent_outlet is null or v_resource_outlet is null or v_parent_outlet <> v_resource_outlet then
    raise exception 'Online booking records must belong to the same outlet';
  end if;
  new.outlet_id := v_parent_outlet;
  return new;
end; $$;


--
-- Name: enforce_online_hold_concrete_resources(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_online_hold_concrete_resources() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: enforce_online_service_buffer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_online_service_buffer() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  new.buffer_before_minutes := 0;

  select coalesce(buffer_after_minutes, 0)
  into new.buffer_after_minutes
  from public.services
  where id = new.service_id;

  new.buffer_after_minutes := coalesce(new.buffer_after_minutes, 0);
  return new;
end;
$$;


--
-- Name: enforce_walkin_future_capacity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_walkin_future_capacity() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_start timestamp without time zone;
  v_block_end timestamp without time zone;
  v_duration integer;
begin
  if new.type::text <> 'walkin'
     or not public.csp_blocks_schedule(new.status::text) then
    return new;
  end if;

  v_start := public.csp_appointment_start_at(new);
  v_block_end := public.csp_appointment_block_end_at(new);
  v_duration := greatest(
    ceil(extract(epoch from (v_block_end - v_start)) / 60.0)::integer,
    1
  );

  perform pg_advisory_xact_lock(
    hashtextextended(
      'walkin-capacity:' || new.outlet_id::text || ':' || new.appointment_date::text,
      0
    )
  );

  if not public.check_walkin_protects_future(
    new.outlet_id,
    v_start,
    v_duration,
    new.therapist_id,
    new.id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'This walk-in would leave too little therapist capacity for an upcoming appointment. Choose another therapist or a later start.';
  end if;

  return new;
end;
$$;


--
-- Name: enqueue_appointment_assignment_invalidation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enqueue_appointment_assignment_invalidation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: expire_stale_booking_holds(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expire_stale_booking_holds() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_count integer;
begin
  update public.booking_holds set status='expired', updated_at=now()
  where status='pending_payment' and expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


--
-- Name: fail_billplz_cancellation(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fail_billplz_cancellation(p_hold_id uuid, p_claim_token uuid, p_error text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_updated integer;
begin
  update public.booking_holds set billplz_cancellation_claim_token=null,billplz_cancellation_claimed_at=null,
    billplz_cancellation_last_error=left(coalesce(nullif(trim(p_error),''),'Unknown Billplz error'),2000),updated_at=now()
  where id=p_hold_id and billplz_cancellation_claim_token=p_claim_token and billplz_cancelled_at is null and status in ('expired','cancelled');
  get diagnostics v_updated=row_count; return v_updated=1;
end;
$$;


--
-- Name: finalize_and_start_appointment(uuid, text, text, text, text, jsonb, jsonb, uuid, text, text, uuid, uuid, timestamp with time zone, timestamp with time zone, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text DEFAULT ''::text, p_guest_phone text DEFAULT ''::text, p_service_items jsonb DEFAULT '[]'::jsonb, p_payment_items jsonb DEFAULT '[]'::jsonb, p_therapist_id uuid DEFAULT NULL::uuid, p_assignment_source text DEFAULT 'queue'::text, p_requested_gender text DEFAULT NULL::text, p_room_id uuid DEFAULT NULL::uuid, p_room_unit_id uuid DEFAULT NULL::uuid, p_started_at timestamp with time zone DEFAULT now(), p_expected_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, actual_started_at timestamp with time zone, expected_end_at timestamp without time zone, therapist_id uuid, room_id uuid, room_unit_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_before public.appointments%rowtype;
  v_after public.appointments%rowtype;
  v_txn uuid;
  v_need_payment boolean;
  v_has_primary boolean;
  v_source text;
  v_tx_items jsonb;
  v_therapist_name text;
  v_room_name text;
  v_service_name text;
  v_detail text;
  v_state text;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select *
  into v_before
  from public.appointments a
  where a.id = p_appointment_id
  for update;
  if not found then
    return query select false, p_appointment_id, null::uuid, null::timestamptz,
      null::timestamp, null::uuid, null::uuid, null::uuid,
      'NOT_FOUND', 'Appointment was not found.';
    return;
  end if;

  if v_before.actual_started_at is not null then
    select t.id
    into v_txn
    from public.transactions t
    where t.appointment_id = p_appointment_id
    order by t.created_at desc
    limit 1;
    return query select true, v_before.id, v_txn, v_before.actual_started_at,
      v_before.end_at, v_before.therapist_id, v_before.room_id,
      v_before.room_unit_id, null::text, null::text;
    return;
  end if;

  begin
    v_need_payment := coalesce(p_total_amount, 0) > 0.005
      and jsonb_typeof(coalesce(p_payment_items, '[]'::jsonb)) = 'array'
      and jsonb_array_length(coalesce(p_payment_items, '[]'::jsonb)) > 0;
    select exists (
      select 1
      from public.transactions t
      where t.appointment_id = p_appointment_id
        and t.payment_status = 'paid'
        and coalesce(t.source, '') <> 'appointment_addon'
    ) into v_has_primary;

    if v_need_payment then
      update public.appointments a
      set payment_status = 'paid', updated_at = now()
      where a.id = p_appointment_id;
    elsif v_before.payment_status::text <> 'paid' then
      raise exception using errcode = 'P0001',
        message = 'Payment is required before starting this service.';
    end if;

    select *
    into v_after
    from public.finalize_and_start_appointment_core(
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

    if v_need_payment then
      v_source := case when v_has_primary
        then 'appointment_addon' else 'appointment' end;
      v_tx_items := case when v_has_primary
        then p_payment_items else v_after.service_items end;
      select t.name into v_therapist_name
      from public.therapists t where t.id = v_after.therapist_id;
      select r.name into v_room_name
      from public.rooms r where r.id = v_after.room_id;
      v_service_name := coalesce(
        nullif(v_tx_items -> 0 ->> 'name', ''),
        v_after.service_name,
        'Service'
      );

      insert into public.transactions (
        outlet_id, appointment_id, customer_id, customer_name, customer_phone,
        service_id, service_name, service_items, item_count,
        therapist_id, therapist_name, counter_staff_id, counter_staff_name,
        room_id, room_name, service_price, sst_amount, total_amount,
        therapist_commission_amount, counter_commission_amount,
        source, payment_method, payment_status, receipt_number, notes
      ) values (
        v_after.outlet_id, v_after.id, v_after.customer_id,
        coalesce(nullif(trim(p_guest_name), ''), p_customer_name, ''),
        coalesce(nullif(trim(p_guest_phone), ''), p_customer_phone, ''),
        v_after.service_id, v_service_name, v_tx_items,
        greatest(jsonb_array_length(v_tx_items), 1),
        v_after.therapist_id, coalesce(v_therapist_name, ''),
        p_counter_staff_id, p_counter_staff_name,
        v_after.room_id, coalesce(v_room_name, ''),
        coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
        coalesce(p_total_amount, 0),
        public.csp_commission_for_items(
          v_tx_items, v_after.therapist_id, 'Therapist'
        ),
        case when p_counter_staff_id is null then 0
          else public.csp_commission_for_items(
            v_tx_items, p_counter_staff_id, 'Counter'
          )
        end,
        v_source,
        coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
        'paid'::public.payment_status,
        p_receipt_number,
        'Finalised at service start'
      )
      returning id into v_txn;
    else
      select t.id
      into v_txn
      from public.transactions t
      where t.appointment_id = p_appointment_id
      order by t.created_at desc
      limit 1;
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, p_appointment_id, null::uuid, null::timestamptz,
      null::timestamp, null::uuid, null::uuid, null::uuid,
      coalesce(v_state, 'FINALIZE_FAILED'), coalesce(v_detail, 'Unable to start service.');
    return;
  end;

  return query select true, v_after.id, v_txn, v_after.actual_started_at,
    v_after.end_at, v_after.therapist_id, v_after.room_id,
    v_after.room_unit_id, null::text, null::text;
end;
$$;


--
-- Name: finalize_and_start_appointment_122t_capacity_first_dormant(uuid, text, text, text, text, jsonb, jsonb, uuid, text, text, uuid, uuid, timestamp with time zone, timestamp with time zone, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text DEFAULT ''::text, p_guest_phone text DEFAULT ''::text, p_service_items jsonb DEFAULT '[]'::jsonb, p_payment_items jsonb DEFAULT '[]'::jsonb, p_therapist_id uuid DEFAULT NULL::uuid, p_assignment_source text DEFAULT 'queue'::text, p_requested_gender text DEFAULT NULL::text, p_room_id uuid DEFAULT NULL::uuid, p_room_unit_id uuid DEFAULT NULL::uuid, p_started_at timestamp with time zone DEFAULT now(), p_expected_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, actual_started_at timestamp with time zone, expected_end_at timestamp without time zone, therapist_id uuid, room_id uuid, room_unit_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_outlet_id uuid;
  v_appointment_date date;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select appointment.outlet_id, appointment.appointment_date
  into v_outlet_id, v_appointment_date
  from public.appointments appointment
  where appointment.id = p_appointment_id;

  if v_outlet_id is not null then
    perform set_config('lock_timeout', '2s', true);
    perform pg_advisory_xact_lock(
      hashtextextended(
        v_outlet_id::text || ':' || v_appointment_date::text,
        0
      )
    );
  end if;

  return query
  select *
  from public.finalize_and_start_appointment_122q_legacy(
    p_appointment_id,
    p_customer_name,
    p_customer_phone,
    p_guest_name,
    p_guest_phone,
    p_service_items,
    p_payment_items,
    p_therapist_id,
    p_assignment_source,
    p_requested_gender,
    p_room_id,
    p_room_unit_id,
    p_started_at,
    p_expected_end_at,
    p_counter_staff_id,
    p_counter_staff_name,
    p_service_price,
    p_sst_amount,
    p_total_amount,
    p_payment_method,
    p_receipt_number
  );
end;
$$;


--
-- Name: FUNCTION finalize_and_start_appointment_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.finalize_and_start_appointment_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) IS '122t: serializes single final start with the bounded outlet/date lock before live therapist matching.';


--
-- Name: finalize_and_start_appointment_core(uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment_core(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: FUNCTION finalize_and_start_appointment_core(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.finalize_and_start_appointment_core(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone) IS 'Atomically validates and starts an appointment, returning the next complete delayed window when no therapist is free now.';


--
-- Name: finalize_and_start_appointment_core_122t_capacity_first_dormant(uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment_core_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_source text := lower(coalesce(
    nullif(trim(p_assignment_source), ''),
    'queue'
  ));
  v_appointment public.appointments%rowtype;
  v_effective_therapist uuid;
  v_items jsonb;
  v_service_ids jsonb;
  v_duration integer;
  v_start_local timestamp;
  v_end_local timestamp;
  v_matches jsonb;
  v_result public.appointments%rowtype;
begin
  select appointment.*
  into v_appointment
  from public.appointments appointment
  where appointment.id = p_appointment_id;

  if v_appointment.id is null
     or v_appointment.actual_started_at is not null
     or v_appointment.type::text = 'walkin'
     or current_setting('app.final_start_preallocated', true) = '1' then
    v_effective_therapist := p_therapist_id;
  else
    if v_source not in (
      'queue',
      'gender_preference',
      'specific_customer_request',
      'manual_override'
    ) then
      raise exception using errcode = '22023',
        message = 'Invalid therapist assignment source.';
    end if;
    if v_source = 'gender_preference'
       and nullif(trim(p_requested_gender), '') is null then
      raise exception using errcode = '22023',
        message = 'Choose a gender for the therapist preference.';
    end if;
    if v_source in ('specific_customer_request', 'manual_override')
       and p_therapist_id is null then
      raise exception using errcode = '22023',
        message = 'Choose the requested therapist.';
    end if;

    v_items := case
      when jsonb_typeof(p_service_items) = 'array'
           and jsonb_array_length(p_service_items) > 0
        then p_service_items
      else coalesce(v_appointment.service_items, '[]'::jsonb)
    end;

    select coalesce(jsonb_agg(distinct service_id), '[]'::jsonb)
    into v_service_ids
    from (
      select nullif(
        coalesce(item ->> 'id', item ->> 'serviceId'),
        ''
      ) service_id
      from jsonb_array_elements(v_items) item
    ) services
    where service_id is not null;
    if jsonb_array_length(v_service_ids) = 0
       and v_appointment.service_id is not null then
      v_service_ids := jsonb_build_array(v_appointment.service_id::text);
    end if;

    select coalesce(sum(greatest(
      coalesce(
        nullif(item ->> 'duration', '')::integer,
        service.duration,
        0
      ),
      0
    )), 0)::integer
    into v_duration
    from jsonb_array_elements(v_items) item
    left join public.services service
      on service.id = nullif(
        coalesce(item ->> 'id', item ->> 'serviceId'),
        ''
      )::uuid;
    if v_duration <= 0 then
      v_duration := greatest(
        ceil(extract(epoch from (
          public.csp_appointment_end_at(v_appointment)
          - public.csp_appointment_start_at(v_appointment)
        )) / 60.0)::integer,
        1
      );
    end if;

    v_start_local := p_started_at at time zone 'Asia/Kuala_Lumpur';
    v_end_local := coalesce(
      p_expected_end_at at time zone 'Asia/Kuala_Lumpur',
      v_start_local + make_interval(mins => v_duration)
    );
    if v_end_local <= v_start_local then
      raise exception using errcode = '22023',
        message = 'Expected end time must be after the actual start time.';
    end if;

    v_matches := public.match_finalize_start_therapists_recursive(
      jsonb_build_array(jsonb_build_object(
        'appointment_id', v_appointment.id,
        'assignment_source', v_source,
        'requested_gender', case
          when v_source = 'gender_preference'
            then nullif(trim(p_requested_gender), '')
          else null
        end,
        'fixed_therapist_id', case
          when v_source in (
            'specific_customer_request',
            'manual_override'
          ) then p_therapist_id
          else null
        end,
        'service_ids', v_service_ids,
        'start_local', v_start_local,
        'reserved_end_local',
          v_end_local + make_interval(
            mins => greatest(
              coalesce(v_appointment.buffer_after_minutes, 0),
              0
            )
          )
      )),
      0,
      array[]::uuid[],
      v_appointment.outlet_id,
      v_appointment.id,
      null
    );
    v_effective_therapist := nullif(
      v_matches ->> v_appointment.id::text,
      ''
    )::uuid;
    if v_effective_therapist is null then
      raise exception using errcode = 'P0001',
        message = case
          when v_source in (
            'specific_customer_request',
            'manual_override'
          ) then 'The selected therapist is no longer available.'
          else 'No eligible therapist is available to start this service.'
        end;
    end if;
  end if;

  select *
  into v_result
  from public.finalize_and_start_appointment_core_122q_legacy(
    p_appointment_id,
    p_customer_name,
    p_customer_phone,
    p_guest_name,
    p_guest_phone,
    p_service_items,
    v_effective_therapist,
    v_source,
    p_requested_gender,
    p_room_id,
    p_room_unit_id,
    p_started_at,
    p_expected_end_at
  );
  return v_result;
end;
$$;


--
-- Name: FUNCTION finalize_and_start_appointment_core_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.finalize_and_start_appointment_core_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone) IS '122t: ignores stale queue/gender therapist IDs and rematches at atomic start.';


--
-- Name: finalize_and_start_appointment_core_124_legacy(uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment_core_124_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_a public.appointments%rowtype;
  v_result public.appointments%rowtype;
  v_source text;
  v_items jsonb;
  v_therapist uuid;
  v_requested_gender text;
  v_start_local timestamp;
  v_end_local timestamp;
  v_duration_minutes integer;
  v_check record;
  v_queue record;
  v_room_mode text;
  v_unit uuid;
begin
  select *
  into v_a
  from public.appointments a
  where a.id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Appointment was not found.';
  end if;

  if v_a.actual_started_at is not null then
    return v_a;
  end if;
  if v_a.status::text not in ('pending', 'confirmed') then
    raise exception using errcode = 'P0001',
      message = 'Only a pending or confirmed appointment can be started.';
  end if;
  if v_a.appointment_date
       <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = 'P0001',
      message = 'Service can only be started on its appointment date.';
  end if;
  if v_a.payment_status::text <> 'paid' then
    raise exception using errcode = 'P0001',
      message = 'Payment must be confirmed before starting this service.';
  end if;

  v_items := case
    when jsonb_typeof(p_service_items) = 'array'
         and jsonb_array_length(p_service_items) > 0
      then p_service_items
    else coalesce(v_a.service_items, '[]'::jsonb)
  end;
  v_source := lower(coalesce(nullif(trim(p_assignment_source), ''), 'queue'));
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
      then nullif(trim(p_requested_gender), '')
    else null
  end;
  if v_source = 'gender_preference' and v_requested_gender is null then
    raise exception using errcode = '22023',
      message = 'Choose a gender for the therapist preference.';
  end if;
  if v_source in ('specific_customer_request', 'manual_override')
     and p_therapist_id is null then
    raise exception using errcode = '22023',
      message = 'Choose the requested therapist.';
  end if;

  v_duration_minutes := (
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
    from jsonb_array_elements(v_items) item
    left join public.services service
      on service.id = nullif(
        coalesce(item ->> 'id', item ->> 'serviceId'),
        ''
      )::uuid
  );
  if v_duration_minutes <= 0 then
    v_duration_minutes := greatest(
      ceil(extract(epoch from (
        coalesce(
          v_a.booked_end_at,
          public.csp_end_at(
            coalesce(v_a.booked_date, v_a.appointment_date),
            coalesce(v_a.booked_start_time, v_a.start_time),
            coalesce(v_a.booked_end_time, v_a.end_time)
          ) at time zone 'Asia/Kuala_Lumpur'
        )
        - coalesce(
          v_a.booked_start_at,
          public.csp_start_at(
            coalesce(v_a.booked_date, v_a.appointment_date),
            coalesce(v_a.booked_start_time, v_a.start_time)
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

  v_therapist := p_therapist_id;
  if v_therapist is null then
    for v_queue in
      select q.*
      from public.get_therapist_queue(
        v_a.outlet_id,
        v_start_local::date,
        v_start_local::time,
        v_duration_minutes
      ) q
      where v_requested_gender is null
         or lower(q.gender) = lower(v_requested_gender)
      order by q.rotation_rank
    loop
      select *
      into v_check
      from public.check_booking_availability(
        v_start_local::date,
        v_start_local::time,
        v_end_local::time,
        v_queue.therapist_id,
        p_room_id,
        p_appointment_id
      );
      if coalesce(v_check.therapist_available, false) then
        v_therapist := v_queue.therapist_id;
        exit;
      end if;
    end loop;
  end if;

  if v_therapist is null then
    raise exception using errcode = 'P0001',
      message = 'No eligible therapist is available to start this service.';
  end if;
  if not exists (
    select 1
    from public.therapists t
    where t.id = v_therapist
      and t.outlet_id = v_a.outlet_id
      and coalesce(t.availability_status, true)
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
  ) then
    raise exception using errcode = 'P0001',
      message = 'The selected therapist is not active in this outlet.';
  end if;

  if p_room_id is null then
    raise exception using errcode = '22023',
      message = 'Choose a room or shared-capacity zone.';
  end if;
  select r.allocation_mode
  into v_room_mode
  from public.rooms r
  join public.services s on s.id = v_a.service_id
  where r.id = p_room_id
    and r.outlet_id = v_a.outlet_id
    and coalesce(r.is_active, true)
    and lower(coalesce(r.room_type::text, ''))
        = lower(coalesce(s.room_type::text, ''));
  if not found then
    raise exception using errcode = 'P0001',
      message = 'The selected room does not support this service.';
  end if;

  select *
  into v_check
  from public.check_booking_availability(
    v_start_local::date,
    v_start_local::time,
    v_end_local::time,
    v_therapist,
    p_room_id,
    p_appointment_id
  );
  if not coalesce(v_check.therapist_available, false) then
    raise exception using errcode = 'P0001',
      message = 'The selected therapist is no longer available.';
  end if;
  if coalesce(v_check.room_full, true) then
    raise exception using errcode = 'P0001',
      message = 'The selected room or zone is no longer available.';
  end if;

  if coalesce(v_room_mode, 'capacity') = 'specific_room' then
    v_unit := public.allocate_specific_room_unit(
      p_room_id,
      v_start_local,
      v_end_local + make_interval(
        mins => greatest(coalesce(v_a.buffer_after_minutes, 0), 0)
      ),
      p_room_unit_id,
      p_appointment_id,
      null
    );
  else
    v_unit := null;
  end if;

  if v_a.customer_id is not null then
    update public.customers c
    set name = coalesce(nullif(trim(p_customer_name), ''), c.name),
        phone = coalesce(nullif(trim(p_customer_phone), ''), c.phone)
    where c.id = v_a.customer_id;
  end if;

  perform set_config('app.therapist_switch_rpc', '1', true);
  update public.appointments a
  set guest_name = coalesce(
        nullif(trim(p_guest_name), ''),
        nullif(trim(p_customer_name), ''),
        a.guest_name
      ),
      guest_phone = coalesce(
        nullif(trim(p_guest_phone), ''),
        nullif(trim(p_customer_phone), ''),
        a.guest_phone
      ),
      service_items = v_items,
      item_count = greatest(jsonb_array_length(v_items), 1),
      therapist_id = v_therapist,
      requested_therapist_id = case
        when v_source = 'specific_customer_request' then v_therapist
        else null
      end,
      requested_gender = v_requested_gender,
      assignment_source = v_source,
      room_id = p_room_id,
      room_unit_id = v_unit,
      therapist_assignment_state = 'confirmed',
      room_assignment_state = 'confirmed',
      resources_confirmed_at = p_started_at,
      resources_confirmed_by = auth.uid(),
      booked_date = coalesce(booked_date, appointment_date),
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
      checked_in_at = p_started_at,
      checked_in_by = auth.uid(),
      actual_started_at = p_started_at,
      status = 'in_progress',
      start_at = v_start_local,
      end_at = v_end_local,
      assignment_last_attempted_at = now(),
      assignment_error_code = null,
      assignment_error_message = null,
      updated_at = now()
  where a.id = p_appointment_id
  returning * into v_result;

  return v_result;
end;
$$;


--
-- Name: finalize_and_start_appointment_core_126_legacy(uuid, text, text, text, text, jsonb, uuid, text, text, uuid, uuid, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment_core_126_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: FUNCTION finalize_and_start_appointment_core_126_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.finalize_and_start_appointment_core_126_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone) IS 'Owner-only atomic-start guard: exact therapist confirmation, actual-window revalidation and structured busy feedback.';


--
-- Name: finalize_and_start_appointment_group(uuid, uuid[], text, text, jsonb, jsonb, timestamp with time zone, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb DEFAULT '{}'::jsonb, p_payment_items jsonb DEFAULT '[]'::jsonb, p_started_at timestamp with time zone DEFAULT now(), p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], transaction_id uuid, actual_started_at timestamp with time zone, started_count integer, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_group public.appointment_groups%rowtype;
  v_before public.appointments%rowtype;
  v_after public.appointments%rowtype;
  v_id uuid;
  v_update jsonb;
  v_ids uuid[] := array[]::uuid[];
  v_txn uuid;
  v_count integer := 0;
  v_started integer := 0;
  v_already_started integer := 0;
  v_need_payment boolean;
  v_has_primary boolean;
  v_source text;
  v_first public.appointments%rowtype;
  v_all_items jsonb := '[]'::jsonb;
  v_therapist_commission numeric := 0;
  v_therapist_name text;
  v_room_name text;
  v_detail text;
  v_state text;
  v_existing_started_at timestamptz;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select *
  into v_group
  from public.appointment_groups g
  where g.id = p_appointment_group_id
  for update;
  if not found then
    return query select false, p_appointment_group_id, v_ids, null::uuid,
      null::timestamptz, 0, 'NOT_FOUND', 'Group was not found.';
    return;
  end if;

  select count(*), count(*) filter (where a.actual_started_at is not null)
  into v_count, v_already_started
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id
    and a.id = any(p_appointment_ids);
  if v_count = 0 or v_count <> cardinality(p_appointment_ids)
     or v_count <> (
       select count(*) from public.appointments a
       where a.appointment_group_id = p_appointment_group_id
     ) then
    return query select false, p_appointment_group_id, v_ids, null::uuid,
      null::timestamptz, 0, 'INVALID_APPOINTMENTS',
      'The complete group appointment list is required.';
    return;
  end if;
  if v_already_started > 0 and v_already_started < v_count then
    return query select false, p_appointment_group_id, p_appointment_ids,
      null::uuid, null::timestamptz, 0, 'PARTIAL_START',
      'The group is already partially started and requires review.';
    return;
  end if;
  if v_already_started = v_count then
    select t.id into v_txn
    from public.transactions t
    where t.appointment_group_id = p_appointment_group_id
    order by t.created_at desc limit 1;
    select min(a.actual_started_at) into v_existing_started_at
    from public.appointments a
    where a.appointment_group_id = p_appointment_group_id;
    return query select true, p_appointment_group_id, p_appointment_ids,
      v_txn, v_existing_started_at, 0, null::text, null::text;
    return;
  end if;

  begin
    v_need_payment := coalesce(p_total_amount, 0) > 0.005
      and jsonb_typeof(coalesce(p_payment_items, '[]'::jsonb)) = 'array'
      and jsonb_array_length(coalesce(p_payment_items, '[]'::jsonb)) > 0;
    select exists (
      select 1 from public.transactions t
      where (
          t.appointment_group_id = p_appointment_group_id
          or t.appointment_id = any(p_appointment_ids)
        )
        and t.payment_status = 'paid'
        and coalesce(t.source, '') <> 'appointment_addon'
    ) into v_has_primary;

    if v_group.customer_id is not null then
      update public.customers c
      set name = coalesce(nullif(trim(p_customer_name), ''), c.name),
          phone = coalesce(nullif(trim(p_customer_phone), ''), c.phone)
      where c.id = v_group.customer_id;
    end if;
    update public.appointment_groups g
    set group_name = coalesce(nullif(trim(p_customer_name), ''), g.group_name),
        status = 'in_progress'
    where g.id = p_appointment_group_id;

    for v_id in
      select a.id
      from public.appointments a
      where a.appointment_group_id = p_appointment_group_id
      order by a.id
    loop
      select * into v_before
      from public.appointments a where a.id = v_id for update;
      v_ids := array_append(v_ids, v_id);
      v_update := coalesce(p_pax_updates -> v_id::text, '{}'::jsonb);
      if v_update = '{}'::jsonb then
        raise exception 'Final details are missing for one guest.';
      end if;

      if v_need_payment then
        update public.appointments a
        set payment_status = 'paid', updated_at = now()
        where a.id = v_id;
      elsif v_before.payment_status::text <> 'paid' then
        raise exception 'Payment is required for every guest before starting.';
      end if;

      select *
      into v_after
      from public.finalize_and_start_appointment_core(
        v_id,
        p_customer_name,
        p_customer_phone,
        coalesce(v_update ->> 'guest_name', p_customer_name),
        coalesce(v_update ->> 'guest_phone', p_customer_phone),
        coalesce(v_update -> 'service_items', v_before.service_items),
        nullif(v_update ->> 'therapist_id', '')::uuid,
        coalesce(v_update ->> 'assignment_source', 'queue'),
        nullif(v_update ->> 'requested_gender', ''),
        nullif(v_update ->> 'room_id', '')::uuid,
        nullif(v_update ->> 'room_unit_id', '')::uuid,
        p_started_at,
        nullif(v_update ->> 'expected_end_at', '')::timestamptz
      );
      v_started := v_started + 1;
      v_all_items := v_all_items || coalesce(v_after.service_items, '[]'::jsonb);
      v_therapist_commission := v_therapist_commission
        + public.csp_commission_for_items(
            v_after.service_items, v_after.therapist_id, 'Therapist'
          );
      if v_first.id is null then v_first := v_after; end if;
    end loop;

    if v_need_payment then
      v_source := case when v_has_primary
        then 'appointment_addon' else 'appointment' end;
      select t.name into v_therapist_name
      from public.therapists t where t.id = v_first.therapist_id;
      select r.name into v_room_name
      from public.rooms r where r.id = v_first.room_id;
      insert into public.transactions (
        outlet_id, appointment_group_id, customer_id,
        customer_name, customer_phone,
        service_id, service_name, service_items, item_count,
        therapist_id, therapist_name, counter_staff_id, counter_staff_name,
        room_id, room_name, service_price, sst_amount, total_amount,
        therapist_commission_amount, counter_commission_amount,
        source, payment_method, payment_status, receipt_number, notes
      ) values (
        v_first.outlet_id, p_appointment_group_id, v_group.customer_id,
        coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
        v_first.service_id, coalesce(v_first.service_name, 'Service'),
        case when v_has_primary then p_payment_items else v_all_items end,
        greatest(jsonb_array_length(
          case when v_has_primary then p_payment_items else v_all_items end
        ), 1),
        v_first.therapist_id, coalesce(v_therapist_name, ''),
        p_counter_staff_id, p_counter_staff_name,
        v_first.room_id, coalesce(v_room_name, ''),
        coalesce(p_service_price, 0), coalesce(p_sst_amount, 0),
        coalesce(p_total_amount, 0),
        v_therapist_commission,
        case when p_counter_staff_id is null then 0
          else public.csp_commission_for_items(
            case when v_has_primary then p_payment_items else v_all_items end,
            p_counter_staff_id,
            'Counter'
          )
        end,
        v_source,
        coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
        'paid'::public.payment_status,
        p_receipt_number,
        'Group finalised at service start'
      )
      returning id into v_txn;
    else
      select t.id into v_txn
      from public.transactions t
      where t.appointment_group_id = p_appointment_group_id
      order by t.created_at desc limit 1;
    end if;
  exception when others then
    get stacked diagnostics
      v_detail = message_text,
      v_state = returned_sqlstate;
    return query select false, p_appointment_group_id, p_appointment_ids,
      null::uuid, null::timestamptz, 0,
      coalesce(v_state, 'FINALIZE_FAILED'),
      coalesce(v_detail, 'Unable to start group service.');
    return;
  end;

  return query select true, p_appointment_group_id, v_ids, v_txn,
    p_started_at, v_started, null::text, null::text;
end;
$$;


--
-- Name: finalize_and_start_appointment_group_122t_capacity_first_dorman(uuid, uuid[], text, text, jsonb, jsonb, timestamp with time zone, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_and_start_appointment_group_122t_capacity_first_dorman(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb DEFAULT '{}'::jsonb, p_payment_items jsonb DEFAULT '[]'::jsonb, p_started_at timestamp with time zone DEFAULT now(), p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], transaction_id uuid, actual_started_at timestamp with time zone, started_count integer, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_matches jsonb;
  v_updates jsonb := coalesce(p_pax_updates, '{}'::jsonb);
  v_match record;
  v_outlet_id uuid;
  v_appointment_date date;
  v_total integer;
  v_started integer;
  v_is_walkin boolean;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select appointment.outlet_id, appointment.appointment_date
  into v_outlet_id, v_appointment_date
  from public.appointments appointment
  where appointment.appointment_group_id = p_appointment_group_id
  order by appointment.id
  limit 1;

  if v_outlet_id is null then
    return query select false, p_appointment_group_id, p_appointment_ids,
      null::uuid, null::timestamptz, 0, 'NOT_FOUND',
      'Group was not found.';
    return;
  end if;

  perform set_config('lock_timeout', '2s', true);
  perform pg_advisory_xact_lock(
    hashtextextended(
      v_outlet_id::text || ':' || v_appointment_date::text,
      0
    )
  );

  -- Re-read after obtaining the bounded outlet/date lock. A concurrent first
  -- request may have completed while this request waited.
  select
    count(*),
    count(*) filter (where appointment.actual_started_at is not null),
    bool_and(appointment.type::text = 'walkin')
  into v_total, v_started, v_is_walkin
  from public.appointments appointment
  where appointment.appointment_group_id = p_appointment_group_id;

  -- Preserve 122q's idempotent, partial-start and concrete walk-in semantics.
  if v_started > 0 or coalesce(v_is_walkin, false) then
    perform set_config('app.final_start_preallocated', '1', true);
    return query
    select *
    from public.finalize_and_start_appointment_group_122q_legacy(
      p_appointment_group_id,
      p_appointment_ids,
      p_customer_name,
      p_customer_phone,
      v_updates,
      p_payment_items,
      p_started_at,
      p_counter_staff_id,
      p_counter_staff_name,
      p_service_price,
      p_sst_amount,
      p_total_amount,
      p_payment_method,
      p_receipt_number
    );
    perform set_config('app.final_start_preallocated', '0', true);
    return;
  end if;

  v_matches := public.match_finalize_start_group_therapists(
    p_appointment_group_id,
    v_updates,
    p_started_at
  );
  if v_matches is null
     or (
       select count(*)
       from jsonb_object_keys(v_matches)
     ) <> v_total then
    return query select false, p_appointment_group_id, p_appointment_ids,
      null::uuid, null::timestamptz, 0, 'NO_THERAPIST_COMBINATION',
      'No eligible therapist combination is available to start every pax together.';
    return;
  end if;

  for v_match in
    select key, value
    from jsonb_each_text(v_matches)
  loop
    v_updates := jsonb_set(
      v_updates,
      array[v_match.key, 'therapist_id'],
      to_jsonb(v_match.value),
      true
    );
  end loop;

  perform set_config('app.final_start_preallocated', '1', true);
  return query
  select *
  from public.finalize_and_start_appointment_group_122q_legacy(
    p_appointment_group_id,
    p_appointment_ids,
    p_customer_name,
    p_customer_phone,
    v_updates,
    p_payment_items,
    p_started_at,
    p_counter_staff_id,
    p_counter_staff_name,
    p_service_price,
    p_sst_amount,
    p_total_amount,
    p_payment_method,
    p_receipt_number
  );
  perform set_config('app.final_start_preallocated', '0', true);
end;
$$;


--
-- Name: FUNCTION finalize_and_start_appointment_group_122t_capacity_first_dorman(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.finalize_and_start_appointment_group_122t_capacity_first_dorman(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) IS '122t: atomically matches a complete distinct therapist combination before 122q group start.';


--
-- Name: get_available_slots(date, uuid, uuid, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid DEFAULT NULL::uuid) RETURNS TABLE(start_time time without time zone, end_time time without time zone, classification text, score integer, reason text, room_available_slots integer)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_interval integer := 10;
  v_outlet_id uuid;
  v_start_at timestamp;
  v_end_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
  v_work_starts timestamp[] := array[]::timestamp[];
  v_work_ends timestamp[] := array[]::timestamp[];
  v_leave_starts timestamp[] := array[]::timestamp[];
  v_leave_ends timestamp[] := array[]::timestamp[];
  v_block_starts timestamp[] := array[]::timestamp[];
  v_block_ends timestamp[] := array[]::timestamp[];
  v_within_hours boolean;
  v_on_leave boolean;
  v_gap_before integer;
  v_gap_after integer;
  v_gap integer;
begin
  if p_duration is null or p_duration <= 0 then return; end if;

  select t.outlet_id
  into v_outlet_id
  from public.therapists t
  join public.rooms r on r.id = p_room_id and r.outlet_id = t.outlet_id
  where t.id = p_therapist_id;

  if v_outlet_id is null then return; end if;

  select
    coalesce(bs.open_time, '09:00'::time),
    coalesce(bs.close_time, '21:00'::time),
    greatest(coalesce(obs.slot_interval_minutes, 10), 5)
  into v_open, v_close, v_interval
  from public.business_settings bs
  left join public.online_booking_outlet_settings obs
    on obs.outlet_id = bs.outlet_id
  where bs.outlet_id = v_outlet_id
  limit 1;

  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);
  v_interval := greatest(coalesce(v_interval, 10), 5);
  v_start_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  -- Day-level facts, loaded once: working shifts, leave windows, and the
  -- therapist's busy block edges used for gap scoring.
  select
    coalesce(array_agg(p_date + wh.start_time order by wh.start_time), '{}'),
    coalesce(array_agg(
      p_date + wh.end_time
        + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
      order by wh.start_time
    ), '{}')
  into v_work_starts, v_work_ends
  from public.therapist_working_hours wh
  where wh.therapist_id = p_therapist_id
    and wh.day_of_week = extract(dow from p_date)::integer;

  select
    coalesce(array_agg(u.starts_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at), '{}'),
    coalesce(array_agg(u.ends_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at), '{}')
  into v_leave_starts, v_leave_ends
  from public.therapist_unavailability u
  where u.therapist_id = p_therapist_id
    and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < p_date + interval '2 days'
    and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > p_date::timestamp;

  select
    coalesce(array_agg(public.csp_appointment_start_at(a)), '{}'),
    coalesce(array_agg(public.csp_appointment_block_end_at(a)), '{}')
  into v_block_starts, v_block_ends
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.outlet_id = v_outlet_id
    and public.csp_blocks_schedule(a.status::text)
    -- Shared rooms may still have capacity while another therapist is using
    -- them. Such rows must not manufacture a fake adjacency recommendation.
    and a.therapist_id = p_therapist_id
    and (p_exclude_id is null or a.id <> p_exclude_id);

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.outlet_id = v_outlet_id
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and a.outlet_id = v_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  while v_start_at + make_interval(mins => p_duration) <= v_close_at loop
    v_end_at := v_start_at + make_interval(mins => p_duration);

    if v_start_at <= v_now_local then
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    start_time := v_start_at::time;
    end_time := v_end_at::time;
    room_available_slots := 0;

    -- Off / outside shift (a missing shift row means the therapist is off).
    v_within_hours := false;
    if v_work_starts is not null then
      for i in 1 .. coalesce(array_length(v_work_starts, 1), 0) loop
        if v_work_starts[i] <= v_start_at and v_work_ends[i] >= v_end_at then
          v_within_hours := true;
          exit;
        end if;
      end loop;
    end if;
    if not v_within_hours then
      classification := 'unavailable';
      score := 0;
      reason := 'outside_working_hours';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    -- Leave / blocked time.
    v_on_leave := false;
    for i in 1 .. coalesce(array_length(v_leave_starts, 1), 0) loop
      if v_leave_starts[i] < v_end_at and v_leave_ends[i] > v_start_at then
        v_on_leave := true;
        exit;
      end if;
    end loop;
    if v_on_leave then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_on_leave';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    -- Real conflicts: appointments, buffers, pending online holds, room
    -- capacity - all decided by check_booking_availability.
    select * into v_check
    from public.check_booking_availability(
      v_start_at::date,
      v_start_at::time,
      v_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    if not coalesce(v_check.therapist_available, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    elsif coalesce(v_check.room_full, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    room_available_slots := greatest(coalesce(v_check.room_available_slots, 0), 0);

    -- Gap scoring against existing busy blocks (therapist or room):
    -- v_gap_before = minutes of idle time this slot leaves after the previous
    -- booking, v_gap_after = idle minutes before the next booking.
    v_gap_before := null;
    v_gap_after := null;
    for i in 1 .. coalesce(array_length(v_block_starts, 1), 0) loop
      if v_block_ends[i] <= v_start_at then
        v_gap := (extract(epoch from v_start_at - v_block_ends[i]) / 60)::integer;
        if v_gap_before is null or v_gap < v_gap_before then
          v_gap_before := v_gap;
        end if;
      end if;
      if v_block_starts[i] >= v_end_at then
        v_gap := (extract(epoch from v_block_starts[i] - v_end_at) / 60)::integer;
        if v_gap_after is null or v_gap < v_gap_after then
          v_gap_after := v_gap;
        end if;
      end if;
    end loop;

    if v_gap_before = 0 and v_gap_after = 0 then
      v_score := 300;
      v_reason := 'fills_between_bookings';
    elsif v_gap_before = 0 then
      v_score := 200;
      v_reason := 'starts_after_booking';
    elsif v_gap_after = 0 then
      v_score := 150;
      v_reason := 'ends_before_booking';
    elsif (v_gap_before is not null and v_gap_before < 30)
       or (v_gap_after is not null and v_gap_after < 30) then
      -- Bookable, but it strands a sliver of idle time too short to sell.
      v_score := -20;
      v_reason := 'leaves_short_gap';
    elsif v_average_count > 0 and v_therapist_count < v_average_count then
      v_score := 10;
      v_reason := 'balances_workload';
    else
      v_score := 0;
      v_reason := 'standard_slot';
    end if;

    classification := case when v_score >= 150 then 'recommended' else 'standard' end;
    score := v_score;
    reason := v_reason;
    return next;

    v_start_at := v_start_at + make_interval(mins => v_interval);
  end loop;
end;
$$;


--
-- Name: get_available_slots(date, uuid, uuid, integer, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid, p_buffer_after_minutes integer) RETURNS TABLE(start_time time without time zone, end_time time without time zone, classification text, score integer, reason text, room_available_slots integer, previous_block_end time without time zone, next_block_start time without time zone, gap_before_minutes integer, gap_after_minutes integer)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_interval integer := 30;
  v_buffer integer := greatest(coalesce(p_buffer_after_minutes, 0), 0);
  v_outlet_id uuid;
  v_open_at timestamp;
  v_close_at timestamp;
  v_start_at timestamp;
  v_end_at timestamp;
  v_reserved_end_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
  v_work_starts timestamp[] := array[]::timestamp[];
  v_work_ends timestamp[] := array[]::timestamp[];
  v_leave_starts timestamp[] := array[]::timestamp[];
  v_leave_ends timestamp[] := array[]::timestamp[];
  v_block_starts timestamp[] := array[]::timestamp[];
  v_block_ends timestamp[] := array[]::timestamp[];
  v_candidates timestamp[] := array[]::timestamp[];
  v_within_hours boolean;
  v_on_leave boolean;
  v_previous_end timestamp;
  v_next_start timestamp;
  v_gap_before integer;
  v_gap_after integer;
begin
  if p_duration is null or p_duration <= 0 then return; end if;

  select t.outlet_id
  into v_outlet_id
  from public.therapists t
  join public.rooms r on r.id = p_room_id and r.outlet_id = t.outlet_id
  where t.id = p_therapist_id;

  if v_outlet_id is null then return; end if;

  -- Staff suggestions use a 30-minute convenience grid.
  select
    coalesce(bs.open_time, '09:00'::time),
    coalesce(bs.close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings bs
  where bs.outlet_id = v_outlet_id
  limit 1;

  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);
  v_interval := 30;
  v_open_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select
    coalesce(array_agg(window_start order by window_start), array[]::timestamp[]),
    coalesce(array_agg(window_end order by window_start), array[]::timestamp[])
  into v_work_starts, v_work_ends
  from (
    select
      p_date + wh.start_time as window_start,
      p_date + wh.end_time
        + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
        as window_end
    from public.therapist_working_hours wh
    where wh.therapist_id = p_therapist_id
      and wh.day_of_week = extract(dow from p_date)::integer

    union all

    select
      (p_date - 1) + wh.start_time as window_start,
      (p_date - 1) + wh.end_time + interval '1 day' as window_end
    from public.therapist_working_hours wh
    where wh.therapist_id = p_therapist_id
      and wh.end_time <= wh.start_time
      and wh.day_of_week = extract(dow from p_date - 1)::integer
  ) shifts;

  select
    coalesce(
      array_agg(u.starts_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at),
      array[]::timestamp[]
    ),
    coalesce(
      array_agg(u.ends_at at time zone 'Asia/Kuala_Lumpur' order by u.starts_at),
      array[]::timestamp[]
    )
  into v_leave_starts, v_leave_ends
  from public.therapist_unavailability u
  where u.therapist_id = p_therapist_id
    and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_close_at
    and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_open_at;

  select
    coalesce(array_agg(block_start order by block_start), array[]::timestamp[]),
    coalesce(array_agg(block_end order by block_start), array[]::timestamp[])
  into v_block_starts, v_block_ends
  from (
    select
      public.csp_appointment_start_at(a) as block_start,
      public.csp_appointment_block_end_at(a) as block_end
    from public.appointments a
    where a.appointment_date::date between p_date - 1 and p_date + 1
      and a.outlet_id = v_outlet_id
      and a.therapist_id = p_therapist_id
      and public.csp_blocks_schedule(a.status::text)
      and (p_exclude_id is null or a.id <> p_exclude_id)

    union all

    select
      hold.start_at at time zone 'Asia/Kuala_Lumpur' as block_start,
      (
        hold.end_at
        + make_interval(
            mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
          )
      ) at time zone 'Asia/Kuala_Lumpur' as block_end
    from public.booking_holds hold
    where hold.outlet_id = v_outlet_id
      and hold.assigned_therapist_id = p_therapist_id
      and hold.status = 'pending_payment'
      and hold.expires_at > now()
  ) therapist_blocks
  where block_start < v_close_at and block_end > v_open_at;

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date = p_date
    and a.outlet_id = v_outlet_id
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and a.outlet_id = v_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  select coalesce(array_agg(candidate order by candidate), array[]::timestamp[])
  into v_candidates
  from (
    select distinct raw_candidate as candidate
    from (
      select generate_series(
        v_open_at,
        v_close_at - make_interval(mins => p_duration + v_buffer),
        make_interval(mins => v_interval)
      ) as raw_candidate

      union all
      select unnest(v_block_ends)

      union all
      select unnest(v_block_starts)
        - make_interval(mins => p_duration + v_buffer)

      union all
      select unnest(v_work_starts)

      union all
      select unnest(v_work_ends)
        - make_interval(mins => p_duration + v_buffer)

      union all
      select unnest(v_leave_ends)

      union all
      select public.csp_appointment_block_end_at(a)
      from public.appointments a
      where a.appointment_date::date between p_date - 1 and p_date + 1
        and a.outlet_id = v_outlet_id
        and a.room_id = p_room_id
        and public.csp_blocks_schedule(a.status::text)
        and (p_exclude_id is null or a.id <> p_exclude_id)

      union all
      select public.csp_appointment_start_at(a)
        - make_interval(mins => p_duration + v_buffer)
      from public.appointments a
      where a.appointment_date::date between p_date - 1 and p_date + 1
        and a.outlet_id = v_outlet_id
        and a.room_id = p_room_id
        and public.csp_blocks_schedule(a.status::text)
        and (p_exclude_id is null or a.id <> p_exclude_id)

      union all
      select (
        hold.end_at
        + make_interval(
            mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
          )
      ) at time zone 'Asia/Kuala_Lumpur'
      from public.booking_holds hold
      where hold.outlet_id = v_outlet_id
        and hold.assigned_room_id = p_room_id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()

      union all
      select (hold.start_at at time zone 'Asia/Kuala_Lumpur')
        - make_interval(mins => p_duration + v_buffer)
      from public.booking_holds hold
      where hold.outlet_id = v_outlet_id
        and hold.assigned_room_id = p_room_id
        and hold.status = 'pending_payment'
        and hold.expires_at > now()
    ) sources
    where raw_candidate >= v_open_at
      and raw_candidate + make_interval(mins => p_duration + v_buffer)
        <= v_close_at
  ) candidates;

  foreach v_start_at in array v_candidates loop
    if v_start_at <= v_now_local then continue; end if;

    v_end_at := v_start_at + make_interval(mins => p_duration);
    v_reserved_end_at := v_end_at + make_interval(mins => v_buffer);
    start_time := v_start_at::time;
    end_time := v_end_at::time;
    room_available_slots := 0;
    previous_block_end := null;
    next_block_start := null;
    gap_before_minutes := null;
    gap_after_minutes := null;

    v_within_hours := false;
    for i in 1 .. coalesce(array_length(v_work_starts, 1), 0) loop
      if v_work_starts[i] <= v_start_at
         and v_work_ends[i] >= v_reserved_end_at then
        v_within_hours := true;
        exit;
      end if;
    end loop;
    if not v_within_hours then
      classification := 'unavailable';
      score := 0;
      reason := 'outside_working_hours';
      return next;
      continue;
    end if;

    v_on_leave := false;
    for i in 1 .. coalesce(array_length(v_leave_starts, 1), 0) loop
      if v_leave_starts[i] < v_reserved_end_at
         and v_leave_ends[i] > v_start_at then
        v_on_leave := true;
        exit;
      end if;
    end loop;
    if v_on_leave then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_on_leave';
      return next;
      continue;
    end if;

    select * into v_check
    from public.check_booking_availability(
      v_start_at::date,
      v_start_at::time,
      v_reserved_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    if not coalesce(v_check.therapist_available, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
      continue;
    elsif coalesce(v_check.room_full, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
      continue;
    end if;

    room_available_slots := greatest(
      coalesce(v_check.room_available_slots, 0),
      0
    );

    v_previous_end := null;
    v_next_start := null;
    for i in 1 .. coalesce(array_length(v_block_starts, 1), 0) loop
      if v_block_ends[i] <= v_start_at
         and (v_previous_end is null or v_block_ends[i] > v_previous_end) then
        v_previous_end := v_block_ends[i];
      end if;
      if v_block_starts[i] >= v_reserved_end_at
         and (v_next_start is null or v_block_starts[i] < v_next_start) then
        v_next_start := v_block_starts[i];
      end if;
    end loop;

    v_gap_before := case
      when v_previous_end is null then null
      else (extract(epoch from v_start_at - v_previous_end) / 60)::integer
    end;
    v_gap_after := case
      when v_next_start is null then null
      else (extract(epoch from v_next_start - v_reserved_end_at) / 60)::integer
    end;

    previous_block_end := v_previous_end::time;
    next_block_start := v_next_start::time;
    gap_before_minutes := v_gap_before;
    gap_after_minutes := v_gap_after;

    if v_gap_before = 0 and v_gap_after = 0 then
      v_score := 300;
      v_reason := 'fills_between_bookings';
    elsif v_gap_before = 0
       and v_gap_after is not null
       and v_gap_after > 0
       and v_gap_after < 30 then
      v_score := 205;
      v_reason := 'starts_after_booking_short_gap';
    elsif v_gap_after = 0
       and v_gap_before is not null
       and v_gap_before > 0
       and v_gap_before < 30 then
      v_score := 200;
      v_reason := 'ends_before_booking_short_gap';
    elsif v_gap_before = 0 then
      v_score := 240;
      v_reason := 'starts_after_booking';
    elsif v_gap_after = 0 then
      v_score := 220;
      v_reason := 'ends_before_booking';
    elsif exists (
      select 1
      from unnest(v_leave_ends) leave_end
      where leave_end = v_start_at
    ) then
      v_score := 190;
      v_reason := 'starts_after_unavailability';
    elsif exists (
      select 1
      from unnest(v_work_starts) work_start
      where work_start = v_start_at
    ) then
      v_score := 160;
      v_reason := 'starts_at_shift';
    elsif (v_gap_before is not null and v_gap_before < 30)
       or (v_gap_after is not null and v_gap_after < 30) then
      v_score := -50;
      v_reason := 'leaves_short_gap';
    elsif v_average_count > 0 and v_therapist_count < v_average_count then
      v_score := 10;
      v_reason := 'balances_workload';
    else
      v_score := 0;
      v_reason := 'standard_slot';
    end if;

    classification := case
      when v_score >= 150 then 'recommended'
      else 'standard'
    end;
    score := v_score;
    reason := v_reason;
    return next;
  end loop;
end;
$$;


--
-- Name: get_booking_group_for_payment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_booking_group_for_payment(p_token uuid) RETURNS TABLE(customer_name text, customer_phone text, customer_email text, total_amount numeric, status text, expires_at timestamp with time zone, outlet_name text, service_summary text, duration_minutes integer, start_at timestamp with time zone, pax_count integer, notes text, receipt_number text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with holds as (
    select h.outlet_id,
           h.customer_name,
           h.customer_phone,
           h.customer_email,
           h.total_amount,
           h.status,
           h.expires_at,
           h.start_at,
           h.guest_index,
           h.notes,
           h.appointment_group_id,
           coalesce(nullif(c.public_name, ''), s.name, 'Service') as service_name,
           greatest(
             round(extract(epoch from (h.end_at - h.start_at)) / 60.0)::integer, 1
           ) as minutes
    from public.booking_holds h
    left join public.online_booking_services c on c.id = h.online_booking_service_id
    left join public.services s on s.id = c.service_id
    where h.booking_group_token = p_token
  ),
  summary as (
    select string_agg(label, ' + ' order by label) as service_summary
    from (
      select service_name || ' ' || minutes || 'min'
             || case when count(*) > 1 then ' x' || count(*)::text else '' end as label
      from holds
      group by service_name, minutes
    ) labelled
  ),
  booking as (
    select min(customer_name) as customer_name,
           min(customer_phone) as customer_phone,
           min(customer_email) as customer_email,
           (array_agg(outlet_id order by guest_index))[1] as outlet_id,
           sum(total_amount) as display_total,
           case
             when bool_and(status = 'pending_payment') then 'pending_payment'
             when bool_and(status = 'confirmed') then 'confirmed'
             else 'mixed'
           end as status,
           min(expires_at) as expires_at,
           min(start_at) as start_at,
           max(minutes) as minutes,
           count(*)::integer as pax_count,
           min(notes) as notes,
           (array_agg(appointment_group_id) filter (where appointment_group_id is not null))[1]
             as appointment_group_id
    from holds
    having count(*) > 0
  )
  select booking.customer_name,
         booking.customer_phone,
         booking.customer_email,
         price.total_amount,
         booking.status,
         booking.expires_at,
         coalesce(o.name, 'The Best Wellness'),
         summary.service_summary,
         booking.minutes,
         booking.start_at,
         booking.pax_count,
         booking.notes,
         (
           select t.receipt_number from public.transactions t
           where t.appointment_group_id = booking.appointment_group_id
             and t.source = 'online_booking'
           order by t.created_at limit 1
         )
  from booking
  cross join summary
  left join public.outlets o on o.id = booking.outlet_id
  cross join lateral public.outlet_payment_breakdown(
    booking.outlet_id, booking.display_total, 'billplz'
  ) price;
$$;


--
-- Name: get_booking_group_token_by_bill(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_booking_group_token_by_bill(p_bill_id text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select booking_group_token from public.booking_holds
  where billplz_bill_id = p_bill_id limit 1;
$$;


--
-- Name: get_booking_hold_for_payment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_booking_hold_for_payment(p_token uuid) RETURNS TABLE(hold_id uuid, customer_name text, customer_phone text, customer_email text, total_amount numeric, status text, expires_at timestamp with time zone, outlet_name text, service_summary text, duration_minutes integer, start_at timestamp with time zone, pax_count integer, notes text, receipt_number text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select h.id,
         h.customer_name,
         h.customer_phone,
         h.customer_email,
         price.total_amount,
         h.status,
         h.expires_at,
         coalesce(o.name, 'The Best Wellness'),
         coalesce(nullif(c.public_name, ''), s.name, 'Service'),
         greatest(round(extract(epoch from (h.end_at - h.start_at)) / 60.0)::integer, 1),
         h.start_at,
         1,
         h.notes,
         (
           select t.receipt_number from public.transactions t
           where t.appointment_id = h.appointment_id and t.source = 'online_booking'
           order by t.created_at limit 1
         )
  from public.booking_holds h
  left join public.outlets o on o.id = h.outlet_id
  left join public.online_booking_services c on c.id = h.online_booking_service_id
  left join public.services s on s.id = c.service_id
  cross join lateral public.outlet_payment_breakdown(
    h.outlet_id, h.total_amount, 'billplz'
  ) price
  where h.public_token = p_token;
$$;


--
-- Name: get_booking_hold_token_by_bill(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_booking_hold_token_by_bill(p_bill_id text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select public_token from public.booking_holds where billplz_bill_id = p_bill_id limit 1;
$$;


--
-- Name: get_counter_capacity_slots(uuid, date, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(start_time time without time zone, end_time time without time zone, therapist_free integer, room_free integer)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_is_closed boolean := false;
  v_hours_found boolean := false;
  v_open_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_start timestamp;
  v_requirement_count integer;
  v_max_duration integer;
  v_max_reserved_minutes integer;
  v_allocated integer;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception using
      errcode = '22023',
      message = 'p_requirements must be a non-empty JSON array.';
  end if;

  v_requirement_count := jsonb_array_length(p_requirements);

  if exists (
    select 1
    from jsonb_array_elements(p_requirements) requirement
    where jsonb_typeof(requirement) is distinct from 'object'
      or coalesce((requirement ->> 'pax_index')::integer, 0) < 1
      or coalesce((requirement ->> 'duration_minutes')::integer, 0) < 1
      or coalesce(nullif(trim(requirement ->> 'room_type'), ''), '') = ''
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every pax requirement needs a positive pax_index, duration_minutes, and room_type.';
  end if;

  select
    max((requirement ->> 'duration_minutes')::integer),
    max(
      (requirement ->> 'duration_minutes')::integer
        + greatest(
            coalesce((requirement ->> 'buffer_after_minutes')::integer, 0),
            0
          )
    )
  into v_max_duration, v_max_reserved_minutes
  from jsonb_array_elements(p_requirements) requirement;

  select hours.open_time, hours.close_time, hours.is_closed, true
  into v_open, v_close, v_is_closed, v_hours_found
  from public.business_hours hours
  where hours.outlet_id = p_outlet_id
    and hours.day_of_week = extract(dow from p_date)::integer
  limit 1;

  if not coalesce(v_hours_found, false) then
    select
      coalesce(settings.open_time, '09:00'::time),
      coalesce(settings.close_time, '21:00'::time)
    into v_open, v_close
    from public.business_settings settings
    where settings.outlet_id = p_outlet_id
    limit 1;
  end if;

  if coalesce(v_is_closed, false) then
    return;
  end if;

  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);
  v_open_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  for v_start in
    select candidate
    from generate_series(
      v_open_at,
      v_close_at - make_interval(mins => v_max_reserved_minutes),
      interval '30 minutes'
    ) candidate
  loop
    if v_start <= v_now_local then
      continue;
    end if;

    select count(*)
    into v_allocated
    from public.allocate_provisional_slots(
      p_outlet_id,
      p_date,
      v_start::time,
      p_requirements,
      p_exclude_appointment_group_id
    );

    if v_allocated <> v_requirement_count then
      continue;
    end if;

    start_time := v_start::time;
    end_time := (v_start + make_interval(mins => v_max_duration))::time;
    -- These columns remain for the existing result model. With heterogeneous
    -- windows/types, the meaningful guarantee is that every requirement was
    -- matched, so report the matched pax count rather than one shared pool.
    therapist_free := v_allocated;
    room_free := v_allocated;
    return next;
  end loop;
end;
$$;


--
-- Name: get_counter_capacity_slots(uuid, date, integer, integer, text, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_duration integer, p_pax integer, p_room_type text DEFAULT NULL::text, p_buffer_after_minutes integer DEFAULT 0, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid) RETURNS TABLE(start_time time without time zone, end_time time without time zone, therapist_free integer, room_free integer)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_buffer integer := greatest(coalesce(p_buffer_after_minutes, 0), 0);
  v_open_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_dow integer := extract(dow from p_date - 1)::integer;
  v_s timestamp;
  v_treat_end timestamp;
  v_e timestamp;
  v_tfree integer;
  v_rfree integer;
begin
  if p_duration is null or p_duration <= 0 or coalesce(p_pax, 0) < 1 then
    return;
  end if;

  select coalesce(bs.open_time, '09:00'::time), coalesce(bs.close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings bs
  where bs.outlet_id = p_outlet_id
  limit 1;
  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);

  v_open_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  for v_s in
    select g
    from generate_series(
      v_open_at,
      v_close_at - make_interval(mins => p_duration + v_buffer),
      interval '30 minutes'
    ) g
  loop
    if v_s <= v_now_local then continue; end if;

    v_treat_end := v_s + make_interval(mins => p_duration);
    v_e := v_treat_end + make_interval(mins => v_buffer);

    select count(*) into v_tfree
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true) = true
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
      and exists (
        select 1 from public.therapist_working_hours wh
        where wh.therapist_id = t.id
          and (
            (
              wh.day_of_week = v_dow
              and p_date + wh.start_time <= v_s
              and p_date + wh.end_time
                + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
                >= v_e
            )
            or (
              wh.end_time <= wh.start_time
              and wh.day_of_week = v_prev_dow
              and (p_date - 1) + wh.start_time <= v_s
              and (p_date - 1) + wh.end_time + interval '1 day' >= v_e
            )
          )
      )
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = t.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_e
          and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_s
      )
      and not exists (
        select 1 from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and a.therapist_id = t.id
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) < v_e
          and public.csp_appointment_block_end_at(a) > v_s
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1 from public.booking_holds hold
        where hold.assigned_therapist_id = t.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_e
          and ((
            hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
          ) at time zone 'Asia/Kuala_Lumpur') > v_s
      );

    if coalesce(v_tfree, 0) < p_pax then continue; end if;

    select coalesce(sum(greatest(rr.total_slots - rr.booked, 0)), 0) into v_rfree
    from (
      select
        greatest(coalesce(r.total_slots, 1), 1) as total_slots,
        (
          select count(*)
          from public.appointments a
          where a.appointment_date::date between p_date - 1 and p_date + 1
            and a.room_id = r.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_e
            and public.csp_appointment_block_end_at(a) > v_s
            and (
              p_exclude_appointment_group_id is null
              or a.appointment_group_id is distinct from p_exclude_appointment_group_id
            )
        )
        + (
          select count(*)
          from public.booking_holds hold
          where hold.assigned_room_id = r.id
            and hold.status = 'pending_payment'
            and hold.expires_at > now()
            and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_e
            and ((
              hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0))
            ) at time zone 'Asia/Kuala_Lumpur') > v_s
        ) as booked
      from public.rooms r
      where r.outlet_id = p_outlet_id
        and (
          p_room_type is null
          or p_room_type = ''
          or lower(coalesce(r.room_type, '')) = lower(p_room_type)
        )
    ) rr;

    if coalesce(v_rfree, 0) < p_pax then continue; end if;

    start_time := v_s::time;
    end_time := v_treat_end::time;
    therapist_free := v_tfree;
    room_free := v_rfree;
    return next;
  end loop;
end;
$$;


--
-- Name: get_counter_preference_capacity_slots(uuid, date, jsonb, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_counter_preference_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid, p_exclude_appointment_id uuid DEFAULT NULL::uuid) RETURNS TABLE(start_time time without time zone, end_time time without time zone, therapist_free integer, room_free integer, is_available boolean, unavailable_dimension text, unavailable_at timestamp without time zone, conflict_therapist_id uuid, conflict_start time without time zone, conflict_end time without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.validate_one_based_capacity_requirements_122s(p_requirements);

  return query
  select *
  from public.get_counter_preference_capacity_slots_122r_impl(
    p_outlet_id,
    p_date,
    p_requirements,
    p_exclude_appointment_group_id,
    p_exclude_appointment_id
  );
end;
$$;


--
-- Name: get_counter_preference_capacity_slots_122r_impl(uuid, date, jsonb, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_counter_preference_capacity_slots_122r_impl(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid, p_exclude_appointment_id uuid DEFAULT NULL::uuid) RETURNS TABLE(start_time time without time zone, end_time time without time zone, therapist_free integer, room_free integer, is_available boolean, unavailable_dimension text, unavailable_at timestamp without time zone, conflict_therapist_id uuid, conflict_start time without time zone, conflict_end time without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_open time := '09:00';
  v_close time := '21:00';
  v_closed boolean := false;
  v_start timestamp;
  v_close_at timestamp;
  v_max_duration integer;
  v_max_reserved integer;
  v_demands jsonb;
  v_verdict jsonb;
  v_specific uuid;
  v_allocated integer;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception 'Every pax needs a capacity requirement.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_requirements) r
    where coalesce((r ->> 'duration_minutes')::integer, 0) <= 0
      or nullif(r ->> 'room_type', '') is null
      or coalesce(r ->> 'assignment_source', 'queue') not in (
        'queue', 'gender_preference', 'specific_customer_request'
      )
      or (
        r ->> 'assignment_source' = 'gender_preference'
        and nullif(r ->> 'requested_gender', '') is null
      )
      or (
        r ->> 'assignment_source' = 'specific_customer_request'
        and nullif(r ->> 'requested_therapist_id', '') is null
      )
  ) then
    raise exception 'One or more therapist preferences is incomplete.';
  end if;
  if (
    select count(distinct r ->> 'requested_therapist_id')
    from jsonb_array_elements(p_requirements) r
    where r ->> 'assignment_source' = 'specific_customer_request'
  ) <> (
    select count(*)
    from jsonb_array_elements(p_requirements) r
    where r ->> 'assignment_source' = 'specific_customer_request'
  ) then
    raise exception 'The same therapist cannot be requested for simultaneous pax.';
  end if;

  select h.open_time, h.close_time, h.is_closed
  into v_open, v_close, v_closed
  from public.business_hours h
  where h.outlet_id = p_outlet_id
    and h.day_of_week = extract(dow from p_date)::integer
  limit 1;
  if coalesce(v_closed, false) then return; end if;
  v_open := coalesce(v_open, '09:00');
  v_close := coalesce(v_close, '21:00');
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select max((r ->> 'duration_minutes')::integer),
    max((r ->> 'duration_minutes')::integer
      + greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0))
  into v_max_duration, v_max_reserved
  from jsonb_array_elements(p_requirements) r;

  for v_start in
    select candidate from generate_series(
      p_date + v_open,
      v_close_at - make_interval(mins => v_max_reserved),
      interval '30 minutes'
    ) candidate
  loop
    if v_start <= now() at time zone 'Asia/Kuala_Lumpur' then continue; end if;
    select jsonb_agg(
      jsonb_build_object(
        'start', v_start,
        'duration_minutes', (r ->> 'duration_minutes')::integer,
        'buffer_after_minutes',
          greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0),
        'service_id', r -> 'service_ids' ->> 0,
        'room_type', r ->> 'room_type',
        'requested_gender', case
          when r ->> 'assignment_source' = 'gender_preference'
            then r ->> 'requested_gender'
          else null
        end,
        'requested_therapist_id', case
          when r ->> 'assignment_source' = 'specific_customer_request'
            then r ->> 'requested_therapist_id'
          else null
        end,
        'manual_lock_id', null,
        'pax_index', r ->> 'pax_index'
      )
    )
    into v_demands
    from jsonb_array_elements(p_requirements) r;

    v_verdict := public.capacity_feasible(
      p_outlet_id, v_demands, 'soft', p_exclude_appointment_id,
      p_exclude_appointment_group_id
    );
    if coalesce((v_verdict ->> 'feasible')::boolean, false)
       and jsonb_array_length(p_requirements) > 1 then
      select count(*)
      into v_allocated
      from public.allocate_preference_provisional_slots(
        p_outlet_id, p_date, v_start::time, p_requirements,
        p_exclude_appointment_group_id
      );
      if v_allocated <> jsonb_array_length(p_requirements) then
        v_verdict := jsonb_build_object(
          'feasible', false,
          'dimension', 'therapist',
          'at', v_start
        );
      end if;
    end if;
    start_time := v_start::time;
    end_time := (
      v_start + make_interval(mins => v_max_duration)
    )::time;
    is_available := coalesce((v_verdict ->> 'feasible')::boolean, false);
    therapist_free := case when is_available
      then jsonb_array_length(p_requirements) else 0 end;
    room_free := therapist_free;
    unavailable_dimension := v_verdict ->> 'dimension';
    unavailable_at := nullif(v_verdict ->> 'at', '')::timestamp;
    conflict_start := null;
    conflict_end := null;
    conflict_therapist_id := null;

    if not is_available and unavailable_dimension = 'therapist' then
      select nullif(r ->> 'requested_therapist_id', '')::uuid
      into v_specific
      from jsonb_array_elements(p_requirements) r
      where r ->> 'assignment_source' = 'specific_customer_request'
      limit 1;
      if v_specific is not null then
        conflict_therapist_id := v_specific;
        select public.csp_appointment_start_at(a)::time,
          public.csp_appointment_block_end_at(a)::time
        into conflict_start, conflict_end
        from public.appointments a
        where a.therapist_id = v_specific
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a)
              < v_start + make_interval(mins => v_max_reserved)
          and public.csp_appointment_block_end_at(a) > v_start
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from
              p_exclude_appointment_group_id
          )
          and a.id is distinct from p_exclude_appointment_id
        order by public.csp_appointment_start_at(a)
        limit 1;
      end if;
    end if;
    return next;
  end loop;
end;
$$;


--
-- Name: get_counter_preference_capacity_slots_v2(uuid, date, jsonb, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_counter_preference_capacity_slots_v2(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid DEFAULT NULL::uuid, p_exclude_appointment_id uuid DEFAULT NULL::uuid) RETURNS TABLE(start_time time without time zone, end_time time without time zone, therapist_free integer, room_free integer, is_available boolean, unavailable_dimension text, unavailable_at timestamp without time zone, conflict_therapist_id uuid, conflict_start time without time zone, conflict_end time without time zone, candidate_kind text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_open time := '09:00';
  v_close time := '21:00';
  v_closed boolean := false;
  v_close_at timestamp;
  v_max_duration integer;
  v_max_reserved integer;
  v_candidate record;
  v_start timestamp;
  v_demands jsonb;
  v_verdict jsonb;
  v_specific uuid;
  v_allocated integer;
  v_now timestamp := now() at time zone 'Asia/Kuala_Lumpur';
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception using errcode = '42501', message = 'Staff access required.';
  end if;
  perform public.validate_one_based_capacity_requirements_122s(p_requirements);
  if jsonb_typeof(p_requirements) is distinct from 'array'
     or jsonb_array_length(p_requirements) = 0 then
    raise exception 'Every pax needs a capacity requirement.';
  end if;

  select h.open_time, h.close_time, h.is_closed
  into v_open, v_close, v_closed
  from public.business_hours h
  where h.outlet_id = p_outlet_id
    and h.day_of_week = extract(dow from p_date)::integer
  limit 1;
  if coalesce(v_closed, false) then return; end if;
  v_open := coalesce(v_open, '09:00');
  v_close := coalesce(v_close, '21:00');
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select
    max((r ->> 'duration_minutes')::integer),
    max(
      (r ->> 'duration_minutes')::integer
      + greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0)
    )
  into v_max_duration, v_max_reserved
  from jsonb_array_elements(p_requirements) r;

  for v_candidate in
    with raw_candidates(candidate, kind) as (
      -- Anchored to the clock hour, not to opening time: staff say "book them
      -- for 8", never "book them for 8:30 because we opened at 10:30".
      select candidate, 'standard'
      from generate_series(
        date_trunc('hour', p_date + v_open)
          + case
              when date_trunc('hour', p_date + v_open) < p_date + v_open
                then interval '1 hour'
              else interval '0'
            end,
        v_close_at - make_interval(mins => v_max_reserved),
        interval '1 hour'
      ) candidate
      union all
      -- ... but never lose the first bookable minutes of an outlet whose
      -- opening time is off the hour.
      select p_date + v_open, 'standard'
      where date_trunc('hour', p_date + v_open) <> p_date + v_open
      union all
      -- The soonest bookable moment. For today that is the next 5-minute mark
      -- from now (clean to read, and always in the future); for a later date
      -- it is opening time. The shared bounds filter below drops it when it
      -- falls outside trading hours, and capacity_feasible still decides
      -- whether it is actually offerable.
      select
        greatest(
          p_date + v_open,
          -- floor + 5, never ceil: with ceil, a clock already sitting on a
          -- 5-minute mark (19:05:30) would produce 19:05:00, which the
          -- `candidate > now()` bound below then discards.
          date_trunc('hour', v_now)
            + make_interval(
                mins => (floor(extract(minute from v_now) / 5.0) * 5)::int + 5
              )
        ),
        'earliest'
      union all
      select public.csp_appointment_block_end_at(a), 'best_fit'
      from public.appointments a
      where a.outlet_id = p_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and a.appointment_date between p_date - 1 and p_date + 1
        and a.id is distinct from p_exclude_appointment_id
        and (
          p_exclude_appointment_group_id is null
          or a.appointment_group_id is distinct from
            p_exclude_appointment_group_id
        )
      union all
      select
        public.csp_appointment_start_at(a)
          - make_interval(mins => v_max_reserved),
        'best_fit'
      from public.appointments a
      where a.outlet_id = p_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and a.appointment_date between p_date - 1 and p_date + 1
        and a.id is distinct from p_exclude_appointment_id
        and (
          p_exclude_appointment_group_id is null
          or a.appointment_group_id is distinct from
            p_exclude_appointment_group_id
        )
      union all
      select h.end_at at time zone 'Asia/Kuala_Lumpur'
        + make_interval(
            mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
          ),
        'best_fit'
      from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
      union all
      select
        h.start_at at time zone 'Asia/Kuala_Lumpur'
          - make_interval(mins => v_max_reserved),
        'best_fit'
      from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
    ),
    bounded as (
      select candidate, kind
      from raw_candidates
      where candidate >= p_date + v_open
        and candidate <= v_close_at - make_interval(mins => v_max_reserved)
        and candidate > now() at time zone 'Asia/Kuala_Lumpur'
    )
    select
      candidate,
      case
        when bool_or(kind = 'earliest') then 'earliest'
        when bool_or(kind = 'best_fit') then 'best_fit'
        else 'standard'
      end as kind
    from bounded
    group by candidate
    order by candidate
  loop
    v_start := v_candidate.candidate;
    select jsonb_agg(
      jsonb_build_object(
        'start', v_start,
        'duration_minutes', (r ->> 'duration_minutes')::integer,
        'buffer_after_minutes',
          greatest(coalesce((r ->> 'buffer_after_minutes')::integer, 0), 0),
        'service_id', r -> 'service_ids' ->> 0,
        'room_type', r ->> 'room_type',
        'requested_gender', case
          when r ->> 'assignment_source' = 'gender_preference'
            then r ->> 'requested_gender'
          else null
        end,
        'requested_therapist_id', case
          when r ->> 'assignment_source' = 'specific_customer_request'
            then r ->> 'requested_therapist_id'
          else null
        end,
        'manual_lock_id', null,
        'pax_index', r ->> 'pax_index'
      )
    )
    into v_demands
    from jsonb_array_elements(p_requirements) r;

    v_verdict := public.capacity_feasible(
      p_outlet_id,
      v_demands,
      'soft',
      p_exclude_appointment_id,
      p_exclude_appointment_group_id
    );
    if coalesce((v_verdict ->> 'feasible')::boolean, false)
       and jsonb_array_length(p_requirements) > 1 then
      select count(*)
      into v_allocated
      from public.allocate_preference_provisional_slots(
        p_outlet_id,
        p_date,
        v_start::time,
        p_requirements,
        p_exclude_appointment_group_id
      );
      if v_allocated <> jsonb_array_length(p_requirements) then
        v_verdict := jsonb_build_object(
          'feasible', false, 'dimension', 'therapist', 'at', v_start
        );
      end if;
    end if;

    start_time := v_start::time;
    end_time := (
      v_start + make_interval(mins => v_max_duration)
    )::time;
    is_available := coalesce((v_verdict ->> 'feasible')::boolean, false);
    therapist_free := case when is_available
      then jsonb_array_length(p_requirements) else 0 end;
    room_free := therapist_free;
    unavailable_dimension := v_verdict ->> 'dimension';
    unavailable_at := nullif(v_verdict ->> 'at', '')::timestamp;
    conflict_start := null;
    conflict_end := null;
    conflict_therapist_id := null;
    candidate_kind := v_candidate.kind;

    if not is_available and unavailable_dimension = 'therapist' then
      select nullif(r ->> 'requested_therapist_id', '')::uuid
      into v_specific
      from jsonb_array_elements(p_requirements) r
      where r ->> 'assignment_source' = 'specific_customer_request'
      limit 1;
      if v_specific is not null then
        conflict_therapist_id := v_specific;
        select
          public.csp_appointment_start_at(a)::time,
          public.csp_appointment_block_end_at(a)::time
        into conflict_start, conflict_end
        from public.appointments a
        where a.therapist_id = v_specific
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a)
            < v_start + make_interval(mins => v_max_reserved)
          and public.csp_appointment_block_end_at(a) > v_start
          and a.id is distinct from p_exclude_appointment_id
          and (
            p_exclude_appointment_group_id is null
            or a.appointment_group_id is distinct from
              p_exclude_appointment_group_id
          )
        order by public.csp_appointment_start_at(a)
        limit 1;
      end if;
    end if;
    return next;
  end loop;
end;
$$;


--
-- Name: get_public_booking_dates_v2(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_dates_v2(p_catalogue_id uuid, p_therapist_preference text DEFAULT 'none'::text) RETURNS TABLE(booking_date date, available boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_date date;
  v_maximum_days integer;
  v_same_day boolean;
begin
  select
    greatest(coalesce(s.maximum_booking_days, 7), 1),
    coalesce(s.same_day_booking_allowed, false)
  into v_maximum_days, v_same_day
  from public.online_booking_services c
  join public.online_booking_outlet_settings s on s.outlet_id = c.outlet_id
  where c.id = p_catalogue_id;

  if v_maximum_days is null then return; end if;
  if v_same_day then v_today := v_today - 1; end if;

  for i in 1..v_maximum_days loop
    v_date := v_today + i;
    booking_date := v_date;
    available := exists(
      select 1
      from public.get_public_booking_slots_v2(
        p_catalogue_id,
        v_date,
        p_therapist_preference
      )
    );
    return next;
  end loop;
end;
$$;


--
-- Name: get_public_booking_grid_times_v1(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_grid_times_v1(p_catalogue_id uuid, p_date date) RETURNS TABLE(start_at timestamp with time zone, end_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_cfg public.online_booking_services%rowtype;
  v_settings public.online_booking_outlet_settings%rowtype;
  v_business public.business_settings%rowtype;
  v_service public.services%rowtype;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_window record;
  v_open time;
  v_close time;
  v_anchor timestamp;
  v_slot_local timestamp;
  v_end_local timestamp;
  v_block_start_local timestamp;
  v_block_end_local timestamp;
  v_interval integer;
  v_maximum_days integer;
  v_steps integer;
begin
  select * into v_cfg from public.online_booking_services where id = p_catalogue_id;
  if not found then return; end if;
  select * into v_settings from public.online_booking_outlet_settings where outlet_id = v_cfg.outlet_id;
  select * into v_business from public.business_settings where outlet_id = v_cfg.outlet_id;
  select * into v_service from public.services where id = v_cfg.service_id and outlet_id = v_cfg.outlet_id;

  v_interval := greatest(coalesce(v_settings.slot_interval_minutes, 30), 5);
  v_maximum_days := greatest(coalesce(v_settings.maximum_booking_days, 7), 1);

  if not coalesce(v_settings.online_booking_enabled, false)
     or not v_cfg.enabled
     or not coalesce(v_service.is_active, true)
     or p_date < v_today + 1
     or p_date > v_today + v_maximum_days then return; end if;

  if exists (
    select 1 from public.online_booking_closures c
    where c.outlet_id = v_cfg.outlet_id and c.closure_date = p_date and c.is_full_day
  ) then return; end if;

  for v_window in
    select h.start_time, h.end_time
    from public.online_booking_service_hours h
    where v_cfg.use_custom_hours
      and h.online_booking_service_id = v_cfg.id
      and h.day_of_week = extract(dow from p_date)::integer
    union all
    select v_settings.public_open_time, v_settings.public_close_time
    where not v_cfg.use_custom_hours
  loop
    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);
    v_close := least(v_window.end_time, v_settings.public_close_time, v_business.close_time);
    if v_close <= v_open then continue; end if;

    v_anchor := p_date + greatest(v_settings.public_open_time, v_business.open_time);
    v_steps := greatest(
      ceil(extract(epoch from ((p_date + v_open) - v_anchor)) / 60.0 / v_interval)::integer,
      0
    );
    v_slot_local := v_anchor + make_interval(mins => v_steps * v_interval);

    while v_slot_local + make_interval(
      mins => greatest(v_service.duration, 1) + v_cfg.buffer_after_minutes
    ) <= p_date + v_close loop
      v_end_local := v_slot_local + make_interval(mins => greatest(v_service.duration, 1));
      v_block_start_local := v_slot_local - make_interval(mins => v_cfg.buffer_before_minutes);
      v_block_end_local := v_end_local + make_interval(mins => v_cfg.buffer_after_minutes);

      if (v_slot_local at time zone 'Asia/Kuala_Lumpur')
          < now() + make_interval(mins => v_settings.minimum_advance_minutes)
         or v_block_start_local < p_date + v_open
         or exists (
           select 1 from public.online_booking_closures c
           where c.outlet_id = v_cfg.outlet_id
             and c.closure_date = p_date
             and not c.is_full_day
             and (p_date + c.start_time) < v_block_end_local
             and (p_date + c.end_time) > v_block_start_local
         ) then
        v_slot_local := v_slot_local + make_interval(mins => v_interval);
        continue;
      end if;

      start_at := v_slot_local at time zone 'Asia/Kuala_Lumpur';
      end_at := v_end_local at time zone 'Asia/Kuala_Lumpur';
      return next;
      v_slot_local := v_slot_local + make_interval(mins => v_interval);
    end loop;
  end loop;
end; $$;


--
-- Name: get_public_booking_group_date_range_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_group_date_range_v1(p_allocations jsonb) RETURNS TABLE(booking_date date)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_maximum_days integer;
  v_same_day_allowed boolean;
  v_first_offset integer;
begin
  if jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) < 1
     or jsonb_array_length(p_allocations) > 6 then return; end if;

  select greatest(coalesce(s.maximum_booking_days, 7), 1),
         coalesce(s.same_day_booking_allowed, false)
  into v_maximum_days, v_same_day_allowed
  from public.online_booking_services c
  join public.online_booking_outlet_settings s on s.outlet_id = c.outlet_id
  where c.id = (p_allocations->0->>'catalogue_id')::uuid;
  if v_maximum_days is null then return; end if;

  v_first_offset := case when v_same_day_allowed then 0 else 1 end;
  for i in v_first_offset..(v_first_offset + v_maximum_days - 1) loop
    booking_date := v_today + i;
    return next;
  end loop;
end;
$$;


--
-- Name: get_public_booking_group_dates_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_group_dates_v1(p_allocations jsonb) RETURNS TABLE(booking_date date, available boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_maximum_days integer;
  v_same_day_allowed boolean;
  v_first_offset integer;
begin
  if jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) < 1
     or jsonb_array_length(p_allocations) > 6 then return; end if;

  select greatest(coalesce(s.maximum_booking_days, 7), 1),
         coalesce(s.same_day_booking_allowed, false)
  into v_maximum_days, v_same_day_allowed
  from public.online_booking_services c
  join public.online_booking_outlet_settings s on s.outlet_id = c.outlet_id
  where c.id = (p_allocations->0->>'catalogue_id')::uuid;
  if v_maximum_days is null then return; end if;

  v_first_offset := case when v_same_day_allowed then 0 else 1 end;
  for i in v_first_offset..(v_first_offset + v_maximum_days - 1) loop
    booking_date := v_today + i;
    available := exists(
      select 1
      from public.get_public_booking_group_slots_scan_v1(
        p_allocations,
        v_today + i,
        true
      )
    );
    return next;
  end loop;
end;
$$;


--
-- Name: get_public_booking_group_slot_status_v1(jsonb, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_group_slot_status_v1(p_allocations jsonb, p_date date) RETURNS TABLE(start_at timestamp with time zone, end_at timestamp with time zone, status text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_first_cat uuid;
  v_outlet uuid;
begin
  if jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) < 1
     or jsonb_array_length(p_allocations) > 6 then return; end if;

  v_first_cat := (p_allocations->0->>'catalogue_id')::uuid;
  select c.outlet_id into v_outlet from public.online_booking_services c where c.id = v_first_cat;
  if v_outlet is null then return; end if;

  return query
  with feasible as (
    select s.start_at, min(s.end_at) as end_at
    from public.get_public_booking_group_slots_v1(p_allocations, p_date) s
    group by s.start_at
  ),
  grid as (
    select g.start_at, min(g.end_at) as end_at
    from public.get_public_booking_grid_times_v1(v_first_cat, p_date) g
    group by g.start_at
  ),
  merged as (
    select f.start_at from feasible f
    union
    select g.start_at from grid g
  ),
  requested as (
    select distinct (a.value->>'catalogue_id')::uuid as cfg_id
    from jsonb_array_elements(p_allocations) a
  )
  select
    m.start_at,
    coalesce(f.end_at, g.end_at) as end_at,
    case
      when f.start_at is null then 'full'
      when exists (
        select 1
        from requested rq
        where exists (
          select 1 from public.booking_holds h
          where h.online_booking_service_id = rq.cfg_id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at < coalesce(f.end_at, g.end_at)
            and h.end_at > m.start_at
        ) or exists (
          select 1 from public.appointments ap
          where ap.online_booking_service_id = rq.cfg_id
            and public.csp_blocks_schedule(ap.status::text)
            and public.csp_appointment_start_at(ap)
              < (coalesce(f.end_at, g.end_at) at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_block_end_at(ap)
              > (m.start_at at time zone 'Asia/Kuala_Lumpur')
        )
      ) then 'selling_fast'
      else 'available'
    end as status
  from merged m
  left join feasible f on f.start_at = m.start_at
  left join grid g on g.start_at = m.start_at
  order by m.start_at;
end; $$;


--
-- Name: get_public_booking_group_slots_scan_v1(jsonb, date, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_group_slots_scan_v1(p_allocations jsonb, p_date date, p_stop_after_first boolean DEFAULT false) RETURNS TABLE(start_at timestamp with time zone, end_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_count integer := jsonb_array_length(coalesce(p_allocations, '[]'::jsonb));
  v_outlet uuid;
  v_distinct_outlets integer;
  v_female_needed integer;
  v_male_needed integer;
  v_female_avail integer;
  v_male_avail integer;
  v_total_avail integer;
  v_guest record;
  v_cand record;
  v_sets jsonb := '[]'::jsonb;
  v_one jsonb;
  v_taken uuid[];
  v_rooms_taken uuid[];
  v_therapist uuid;
  v_room uuid;
  v_ok boolean;
  v_guest_end timestamptz;
  v_bs timestamptz;
  v_be timestamptz;
  v_cat record;
  v_remaining integer;
begin
  if jsonb_typeof(p_allocations) <> 'array' or v_count < 1 or v_count > 6 then return; end if;

  select count(distinct c.outlet_id), min(c.outlet_id::text)::uuid
  into v_distinct_outlets, v_outlet
  from jsonb_array_elements(p_allocations) a
  join public.online_booking_services c on c.id = (a.value->>'catalogue_id')::uuid;
  if v_distinct_outlets is distinct from 1 then return; end if;

  -- Fast infeasibility check: the outlet must employ at least as many active
  -- therapists of each preferred gender as there are guests preferring it.
  select count(*) filter (where lower(coalesce(t.gender, '')) = 'female'),
         count(*) filter (where lower(coalesce(t.gender, '')) = 'male'),
         count(*)
  into v_female_avail, v_male_avail, v_total_avail
  from public.therapists t
  where t.outlet_id = v_outlet
    and coalesce(t.availability_status, true)
    and lower(coalesce(t.role, 'therapist')) = 'therapist';

  select count(*) filter (where lower(coalesce(a.value->>'therapist_preference', 'none')) = 'female'),
         count(*) filter (where lower(coalesce(a.value->>'therapist_preference', 'none')) = 'male')
  into v_female_needed, v_male_needed
  from jsonb_array_elements(p_allocations) a;

  if v_female_avail < v_female_needed
     or v_male_avail < v_male_needed
     or v_total_avail < v_count then return; end if;

  -- Candidate times: every guest must individually have the slot.
  for v_guest in
    select (a.value->>'catalogue_id')::uuid as catalogue_id,
           lower(coalesce(a.value->>'therapist_preference', 'none')) as pref
    from jsonb_array_elements(p_allocations) a
  loop
    select coalesce(jsonb_agg(jsonb_build_object('s', s.start_at, 'e', s.end_at)), '[]'::jsonb)
    into v_one
    from public.get_public_booking_slots_v2(v_guest.catalogue_id, p_date, v_guest.pref) s;
    if v_one = '[]'::jsonb then return; end if;
    v_sets := v_sets || jsonb_build_array(v_one);
  end loop;

  for v_cand in
    select (slot->>'s')::timestamptz as cand_start,
           max((slot->>'e')::timestamptz) as cand_end
    from jsonb_array_elements(v_sets) with ordinality gs(guest_set, gi)
    cross join jsonb_array_elements(gs.guest_set) slot
    group by slot->>'s'
    having count(distinct gs.gi) = v_count
    order by 1
  loop
    if v_count = 1 then
      start_at := v_cand.cand_start;
      end_at := v_cand.cand_end;
      return next;
      if p_stop_after_first then return; end if;
      continue;
    end if;

    -- Simulate the exact greedy assignment hold creation performs: gendered
    -- preferences first, then original order; each guest takes the first
    -- eligible therapist by name and the first room with a free slot.
    v_taken := '{}'::uuid[];
    v_rooms_taken := '{}'::uuid[];
    v_ok := true;

    for v_guest in
      select c.id as cfg_id, c.outlet_id, c.service_id, c.buffer_before_minutes, c.buffer_after_minutes,
             greatest(s.duration, 1) as duration,
             lower(coalesce(a.value->>'therapist_preference', 'none')) as pref
      from jsonb_array_elements(p_allocations) with ordinality a
      join public.online_booking_services c on c.id = (a.value->>'catalogue_id')::uuid
      join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
      order by (lower(coalesce(a.value->>'therapist_preference', 'none')) = 'none'), a.ordinality
    loop
      v_guest_end := v_cand.cand_start + make_interval(mins => v_guest.duration);
      v_bs := v_cand.cand_start - make_interval(mins => v_guest.buffer_before_minutes);
      v_be := v_guest_end + make_interval(mins => v_guest.buffer_after_minutes);

      select t.id into v_therapist from public.therapists t
      where t.outlet_id = v_guest.outlet_id
        and coalesce(t.availability_status, true)
        and lower(coalesce(t.role, 'therapist')) = 'therapist'
        and (v_guest.pref = 'none' or lower(coalesce(t.gender, '')) = v_guest.pref)
        and (coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb
             or t.service_commissions ? v_guest.service_id::text)
        and t.id <> all(v_taken)
        and exists (
          select 1 from public.therapist_working_hours wh
          where wh.therapist_id = t.id
            and wh.day_of_week = extract(dow from p_date)::integer
            and p_date + wh.start_time <= (v_bs at time zone 'Asia/Kuala_Lumpur')
            and p_date + wh.end_time
              + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
              >= (v_be at time zone 'Asia/Kuala_Lumpur')
        )
        and not exists (
          select 1 from public.therapist_unavailability u
          where u.therapist_id = t.id and u.starts_at < v_be and u.ends_at > v_bs
        )
        and not exists (
          select 1 from public.appointments ap
          where ap.therapist_id = t.id and public.csp_blocks_schedule(ap.status::text)
            and public.csp_appointment_start_at(ap) < (v_be at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_end_at(ap) > (v_bs at time zone 'Asia/Kuala_Lumpur')
        )
        and not exists (
          select 1 from public.booking_holds h
          where h.assigned_therapist_id = t.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes) < v_be
            and h.end_at + make_interval(mins => h.buffer_after_minutes) > v_bs
        )
      order by t.name limit 1;

      if v_therapist is null then v_ok := false; exit; end if;
      v_taken := array_append(v_taken, v_therapist);

      select r.id into v_room
      from public.rooms r
      join public.online_booking_service_rooms cr on cr.room_id = r.id
      where cr.online_booking_service_id = v_guest.cfg_id
        and coalesce(r.is_active, true)
        and coalesce(r.total_slots, 1) >
          (select count(*) from public.appointments ap
           where ap.room_id = r.id and public.csp_blocks_schedule(ap.status::text)
             and public.csp_appointment_start_at(ap) < (v_be at time zone 'Asia/Kuala_Lumpur')
             and public.csp_appointment_end_at(ap) > (v_bs at time zone 'Asia/Kuala_Lumpur'))
          + (select count(*) from public.booking_holds h
             where h.assigned_room_id = r.id
               and h.status = 'pending_payment' and h.expires_at > now()
               and h.start_at - make_interval(mins => h.buffer_before_minutes) < v_be
               and h.end_at + make_interval(mins => h.buffer_after_minutes) > v_bs)
          + (select count(*) from unnest(v_rooms_taken) taken_room where taken_room = r.id)
      order by r.name limit 1;

      if v_room is null then v_ok := false; exit; end if;
      v_rooms_taken := array_append(v_rooms_taken, v_room);
    end loop;

    -- Per-catalogue public concurrency cap must cover every guest on it.
    if v_ok then
      for v_cat in
        select c.id as cfg_id, c.maximum_concurrent_bookings,
               c.buffer_before_minutes, c.buffer_after_minutes,
               greatest(s.duration, 1) as duration,
               count(*)::integer as guests_on_it
        from jsonb_array_elements(p_allocations) a
        join public.online_booking_services c on c.id = (a.value->>'catalogue_id')::uuid
        join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
        group by c.id, c.maximum_concurrent_bookings, c.buffer_before_minutes,
                 c.buffer_after_minutes, s.duration
      loop
        v_guest_end := v_cand.cand_start + make_interval(mins => v_cat.duration);
        v_bs := v_cand.cand_start - make_interval(mins => v_cat.buffer_before_minutes);
        v_be := v_guest_end + make_interval(mins => v_cat.buffer_after_minutes);
        select v_cat.maximum_concurrent_bookings
          - (select count(*) from public.booking_holds h
             where h.online_booking_service_id = v_cat.cfg_id
               and h.status = 'pending_payment' and h.expires_at > now()
               and h.start_at - make_interval(mins => h.buffer_before_minutes) < v_be
               and h.end_at + make_interval(mins => h.buffer_after_minutes) > v_bs)
          - (select count(*) from public.appointments ap
             where ap.online_booking_service_id = v_cat.cfg_id
               and public.csp_blocks_schedule(ap.status::text)
               and public.csp_appointment_start_at(ap) < (v_be at time zone 'Asia/Kuala_Lumpur')
               and public.csp_appointment_block_end_at(ap) > (v_bs at time zone 'Asia/Kuala_Lumpur'))
        into v_remaining;
        if coalesce(v_remaining, 0) < v_cat.guests_on_it then v_ok := false; exit; end if;
      end loop;
    end if;

    if v_ok then
      start_at := v_cand.cand_start;
      end_at := v_cand.cand_end;
      return next;
      if p_stop_after_first then return; end if;
    end if;
  end loop;
end;
$$;


--
-- Name: get_public_booking_group_slots_v1(jsonb, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_group_slots_v1(p_allocations jsonb, p_date date) RETURNS TABLE(start_at timestamp with time zone, end_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select *
  from public.get_public_booking_group_slots_scan_v1(
    p_allocations,
    p_date,
    false
  );
$$;


--
-- Name: get_public_booking_group_status_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_group_status_v1(p_token uuid) RETURNS TABLE(token uuid, status text, expires_at timestamp with time zone, total_price numeric, start_at timestamp with time zone, end_at timestamp with time zone, guest_count integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select p_token,
    case when bool_and(h.status = 'confirmed') then 'confirmed'
         when bool_or(h.status = 'payment_failed') then 'payment_failed'
         when bool_or(h.status = 'expired') then 'expired'
         when bool_or(h.status = 'cancelled') then 'cancelled'
         else 'pending_payment' end,
    min(h.expires_at), sum(h.total_amount), min(h.start_at), max(h.end_at), count(*)::integer
  from public.booking_holds h where h.booking_group_token = p_token
  having count(*) > 0;
$$;


--
-- Name: get_public_booking_hold_status_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_hold_status_v2(p_token uuid) RETURNS TABLE(token uuid, status text, expires_at timestamp with time zone, total_price numeric, deposit_due numeric, start_at timestamp with time zone, end_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select h.public_token, h.status, h.expires_at, h.total_amount, h.deposit_amount, h.start_at, h.end_at
  from public.booking_holds h where h.public_token = p_token;
$$;


--
-- Name: get_public_booking_slots_v2(uuid, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_booking_slots_v2(p_catalogue_id uuid, p_date date, p_therapist_preference text DEFAULT 'none'::text) RETURNS TABLE(start_at timestamp with time zone, end_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_cfg public.online_booking_services%rowtype;
  v_settings public.online_booking_outlet_settings%rowtype;
  v_business public.business_settings%rowtype;
  v_service public.services%rowtype;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_pref text := lower(coalesce(p_therapist_preference, 'none'));
  v_window record;
  v_open time;
  v_close time;
  v_close_at timestamp;
  v_anchor timestamp;
  v_slot_local timestamp;
  v_end_local timestamp;
  v_block_start_local timestamp;
  v_block_end_local timestamp;
  v_interval integer;
  v_maximum_days integer;
  v_steps integer;
  v_therapists integer;
  v_rooms integer;
  v_public_remaining integer;
begin
  select * into v_cfg from public.online_booking_services where id = p_catalogue_id;
  if not found then return; end if;
  select * into v_settings from public.online_booking_outlet_settings where outlet_id = v_cfg.outlet_id;
  select * into v_business from public.business_settings where outlet_id = v_cfg.outlet_id;
  select * into v_service from public.services where id = v_cfg.service_id and outlet_id = v_cfg.outlet_id;

  v_interval := greatest(coalesce(v_settings.slot_interval_minutes, 30), 5);
  v_maximum_days := greatest(coalesce(v_settings.maximum_booking_days, 7), 1);

  if coalesce(v_settings.same_day_booking_allowed, false) then
    v_today := v_today - 1;
  end if;

  if not coalesce(v_settings.online_booking_enabled, false)
     or not v_cfg.enabled
     or not coalesce(v_service.is_active, true)
     or p_date < v_today + 1
     or p_date > v_today + v_maximum_days
     or v_pref not in ('none', 'female', 'male') then return; end if;

  if exists (
    select 1 from public.online_booking_closures c
    where c.outlet_id = v_cfg.outlet_id and c.closure_date = p_date and c.is_full_day
  ) then return; end if;

  for v_window in
    select h.start_time, h.end_time
    from public.online_booking_service_hours h
    where v_cfg.use_custom_hours
      and h.online_booking_service_id = v_cfg.id
      and h.day_of_week = extract(dow from p_date)::integer
    union all
    select v_settings.public_open_time, v_settings.public_close_time
    where not v_cfg.use_custom_hours
  loop
    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);
    v_close_at := least(
      p_date + v_window.end_time
        + case when v_window.end_time <= v_window.start_time then interval '1 day' else interval '0' end,
      p_date + v_settings.public_close_time
        + case when v_settings.public_close_time <= v_settings.public_open_time then interval '1 day' else interval '0' end,
      p_date + v_business.close_time
        + case when v_business.close_time <= v_business.open_time then interval '1 day' else interval '0' end
    );
    if v_close_at <= p_date + v_open then continue; end if;

    v_anchor := p_date;
    v_steps := greatest(
      ceil(extract(epoch from ((p_date + v_open) - v_anchor)) / 60.0 / v_interval)::integer,
      0
    );
    v_slot_local := v_anchor + make_interval(mins => v_steps * v_interval);

    while v_slot_local + make_interval(
      mins => greatest(v_service.duration, 1) + v_cfg.buffer_after_minutes
    ) <= v_close_at loop
      v_end_local := v_slot_local + make_interval(mins => greatest(v_service.duration, 1));
      v_block_start_local := v_slot_local - make_interval(mins => v_cfg.buffer_before_minutes);
      v_block_end_local := v_end_local + make_interval(mins => v_cfg.buffer_after_minutes);

      if (v_slot_local at time zone 'Asia/Kuala_Lumpur')
          < now() + make_interval(mins => v_settings.minimum_advance_minutes)
         or v_block_start_local < p_date + v_open
         or exists (
           select 1 from public.online_booking_closures c
           where c.outlet_id = v_cfg.outlet_id
             and c.closure_date = p_date
             and not c.is_full_day
             and (p_date + c.start_time) < v_block_end_local
             and (p_date + c.end_time) > v_block_start_local
         ) then
        v_slot_local := v_slot_local + make_interval(mins => v_interval);
        continue;
      end if;

      select greatest(
        v_cfg.maximum_concurrent_bookings
        - (
          select count(*) from public.booking_holds h
          where h.online_booking_service_id = v_cfg.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes)
              < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and h.end_at + make_interval(mins => h.buffer_after_minutes)
              > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        )
        - (
          select count(*) from public.appointments a
          where a.online_booking_service_id = v_cfg.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_block_end_local
            and public.csp_appointment_block_end_at(a) > v_block_start_local
        ), 0
      )::integer into v_public_remaining;

      select count(*)::integer into v_therapists
      from public.therapists t
      where t.outlet_id = v_cfg.outlet_id
        and coalesce(t.availability_status, true)
        and lower(coalesce(t.role, 'therapist')) = 'therapist'
        and (v_pref = 'none' or lower(coalesce(t.gender, '')) = v_pref)
        and (
          coalesce(t.service_commissions, '{}'::jsonb) = '{}'::jsonb
          or t.service_commissions ? v_cfg.service_id::text
        )
        and exists (
          select 1 from public.therapist_working_hours wh
          where wh.therapist_id = t.id and wh.outlet_id = v_cfg.outlet_id
            and wh.day_of_week = extract(dow from p_date)::integer
            and p_date + wh.start_time <= v_block_start_local
            and p_date + wh.end_time
              + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
              >= v_block_end_local
        )
        and not exists (
          select 1 from public.therapist_unavailability u
          where u.therapist_id = t.id
            and u.starts_at < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and u.ends_at > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        )
        and not exists (
          select 1 from public.appointments a
          where a.therapist_id = t.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_block_end_local
            and public.csp_appointment_block_end_at(a) > v_block_start_local
        )
        and not exists (
          select 1 from public.booking_holds h
          where h.assigned_therapist_id = t.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes)
              < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and h.end_at + make_interval(mins => h.buffer_after_minutes)
              > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        );

      select coalesce(sum(greatest(
        coalesce(r.total_slots, 1)
        - (
          select count(*) from public.appointments a
          where a.room_id = r.id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < v_block_end_local
            and public.csp_appointment_block_end_at(a) > v_block_start_local
        )
        - (
          select count(*) from public.booking_holds h
          where h.assigned_room_id = r.id
            and h.status = 'pending_payment' and h.expires_at > now()
            and h.start_at - make_interval(mins => h.buffer_before_minutes)
              < (v_block_end_local at time zone 'Asia/Kuala_Lumpur')
            and h.end_at + make_interval(mins => h.buffer_after_minutes)
              > (v_block_start_local at time zone 'Asia/Kuala_Lumpur')
        ), 0
      )), 0)::integer into v_rooms
      from public.rooms r
      join public.online_booking_service_rooms cr on cr.room_id = r.id
      where cr.online_booking_service_id = v_cfg.id
        and cr.outlet_id = v_cfg.outlet_id
        and coalesce(r.is_active, true);

      if least(v_public_remaining, v_therapists, v_rooms) > 0 then
        start_at := v_slot_local at time zone 'Asia/Kuala_Lumpur';
        end_at := v_end_local at time zone 'Asia/Kuala_Lumpur';
        return next;
      end if;
      v_slot_local := v_slot_local + make_interval(mins => v_interval);
    end loop;
  end loop;
end;
$$;


--
-- Name: get_queue_schedule_status(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_queue_schedule_status(p_outlet_id uuid, p_date date) RETURNS TABLE(active_count integer, scheduled_count integer, unscheduled_active_count integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with active_t as (
    select t.id
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true) = true
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
  ),
  scheduled as (
    select a.id
    from active_t a
    where exists (
      select 1 from public.therapist_working_hours wh
      join public.business_hours bh
        on bh.outlet_id = p_outlet_id
       and bh.day_of_week = wh.day_of_week
       and not coalesce(bh.is_closed, false)
      where wh.therapist_id = a.id
        and wh.day_of_week = extract(dow from p_date)::integer
    )
  ),
  has_any_hours as (
    select a.id
    from active_t a
    where exists (
      select 1 from public.therapist_working_hours wh
      where wh.therapist_id = a.id
    )
  )
  select
    (select count(*) from active_t)::integer,
    (select count(*) from scheduled)::integer,
    ((select count(*) from active_t) - (select count(*) from has_any_hours))::integer;
$$;


--
-- Name: get_room_unit_availability(uuid, date, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_room_unit_availability(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer) RETURNS TABLE(room_unit_id uuid, room_unit_name text, status text, available_for_requested_time boolean, available_at time without time zone)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  with requested as (
    select public.csp_start_at(p_date, p_start_time) as starts_at,
           public.csp_start_at(p_date, p_start_time)
             + make_interval(mins => greatest(p_duration, 1)) as ends_at,
           (now() at time zone 'Asia/Kuala_Lumpur') as now_local
  ), conflicts as (
    select u.id,
      max(public.csp_appointment_block_end_at(a)) filter (
        where public.csp_appointment_block_end_at(a) > r.now_local
      ) as appointment_free_at,
      max((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
        at time zone 'Asia/Kuala_Lumpur') filter (where h.expires_at > now()) as hold_free_at,
      bool_or(public.csp_appointment_start_at(a) <= r.now_local
        and public.csp_appointment_end_at(a) > r.now_local) as in_service,
      bool_or(public.csp_appointment_end_at(a) <= r.now_local
        and public.csp_appointment_block_end_at(a) > r.now_local) as cleaning
    from public.room_units u cross join requested r
    left join public.appointments a on a.room_unit_id = u.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < r.ends_at
      and public.csp_appointment_block_end_at(a) > least(r.starts_at, r.now_local)
    left join public.booking_holds h on h.assigned_room_unit_id = u.id
      and h.status = 'pending_payment' and h.expires_at > now()
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < r.ends_at
      and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
        at time zone 'Asia/Kuala_Lumpur') > least(r.starts_at, r.now_local)
    where u.zone_id = p_zone_id and u.is_active
    group by u.id
  )
  select u.id, u.name,
    case when coalesce(c.in_service, false) then 'occupied'
         when coalesce(c.cleaning, false) then 'cleaning'
         else 'available' end,
    not exists (
      select 1 from public.appointments a, requested r
      where a.room_unit_id = u.id and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < r.ends_at
        and public.csp_appointment_block_end_at(a) > r.starts_at
    ) and not exists (
      select 1 from public.booking_holds h, requested r
      where h.assigned_room_unit_id = u.id and h.status = 'pending_payment'
        and h.expires_at > now()
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < r.ends_at
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
          at time zone 'Asia/Kuala_Lumpur') > r.starts_at
    ),
    greatest(c.appointment_free_at, c.hold_free_at)::time
  from public.room_units u
  left join conflicts c on c.id = u.id
  where u.zone_id = p_zone_id and u.is_active
  order by 4 desc, 5 nulls last, u.unit_number;
$$;


--
-- Name: get_room_unit_availability_v2(uuid, date, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_room_unit_availability_v2(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer) RETURNS TABLE(room_unit_id uuid, room_unit_name text, status text, available_for_requested_time boolean, available_at time without time zone, reservation_start_at time without time zone, reservation_end_at time without time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with requested as (
    select
      public.csp_start_at(p_date, p_start_time) as starts_at,
      public.csp_start_at(p_date, p_start_time)
        + make_interval(mins => greatest(p_duration, 1)) as ends_at
  ),
  base as (
    select *
    from public.get_room_unit_availability(
      p_zone_id, p_date, p_start_time, p_duration
    )
  ),
  reservations as (
    select
      a.room_unit_id,
      public.csp_appointment_start_at(a) as starts_at,
      public.csp_appointment_block_end_at(a) as ends_at
    from public.appointments a
    cross join requested r
    where a.room_unit_id is not null
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < r.ends_at
      and public.csp_appointment_block_end_at(a) > r.starts_at
    union all
    select
      h.assigned_room_unit_id,
      h.start_at at time zone 'Asia/Kuala_Lumpur',
      (h.end_at + make_interval(
        mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
      )) at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    cross join requested r
    where h.assigned_room_unit_id is not null
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and h.start_at at time zone 'Asia/Kuala_Lumpur' < r.ends_at
      and (h.end_at + make_interval(
        mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
      )) at time zone 'Asia/Kuala_Lumpur' > r.starts_at
  ),
  ranges as (
    select
      room_unit_id,
      min(starts_at)::time as reservation_start_at,
      max(ends_at)::time as reservation_end_at
    from reservations
    group by room_unit_id
  )
  select
    b.room_unit_id,
    b.room_unit_name,
    case
      when not b.available_for_requested_time and b.status = 'available'
        then 'reserved'
      else b.status
    end,
    b.available_for_requested_time,
    b.available_at,
    r.reservation_start_at,
    r.reservation_end_at
  from base b
  left join ranges r using (room_unit_id)
  order by b.available_for_requested_time desc, b.available_at nulls last,
    b.room_unit_name;
$$;


--
-- Name: get_staff_booking_schedule_context(date, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_staff_booking_schedule_context(p_date date, p_therapist_id uuid, p_exclude_id uuid DEFAULT NULL::uuid) RETURNS TABLE(start_time time without time zone, end_time time without time zone, blocked_until time without time zone, kind text, label text)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  with day_window as (
    select
      p_date + coalesce(bs.open_time, '09:00'::time) as starts_at,
      p_date + coalesce(bs.close_time, '21:00'::time)
        + case
            when coalesce(bs.close_time, '21:00'::time)
              <= coalesce(bs.open_time, '09:00'::time)
            then interval '1 day'
            else interval '0'
          end as ends_at
    from public.therapists t
    left join public.business_settings bs on bs.outlet_id = t.outlet_id
    where t.id = p_therapist_id
    limit 1
  ),
  blocks as (
    select
      public.csp_appointment_start_at(a) as starts_at,
      public.csp_appointment_end_at(a) as ends_at,
      public.csp_appointment_block_end_at(a) as blocked_until,
      'appointment'::text as kind,
      coalesce(nullif(trim(a.service_name), ''), 'Booked service')::text as label
    from public.appointments a
    where a.appointment_date::date between p_date - 1 and p_date + 1
      and a.therapist_id = p_therapist_id
      and public.csp_blocks_schedule(a.status::text)
      and (p_exclude_id is null or a.id <> p_exclude_id)

    union all

    select
      hold.start_at at time zone 'Asia/Kuala_Lumpur' as starts_at,
      hold.end_at at time zone 'Asia/Kuala_Lumpur' as ends_at,
      (
        hold.end_at
        + make_interval(
            mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
          )
      ) at time zone 'Asia/Kuala_Lumpur' as blocked_until,
      'hold'::text as kind,
      'Pending online booking'::text as label
    from public.booking_holds hold
    where hold.assigned_therapist_id = p_therapist_id
      and hold.status = 'pending_payment'
      and hold.expires_at > now()

    union all

    select
      u.starts_at at time zone 'Asia/Kuala_Lumpur' as starts_at,
      u.ends_at at time zone 'Asia/Kuala_Lumpur' as ends_at,
      u.ends_at at time zone 'Asia/Kuala_Lumpur' as blocked_until,
      'leave'::text as kind,
      coalesce(
        nullif(trim(u.internal_reason), ''),
        'Therapist unavailable'
      )::text as label
    from public.therapist_unavailability u
    where u.therapist_id = p_therapist_id
  )
  select
    blocks.starts_at::time,
    blocks.ends_at::time,
    blocks.blocked_until::time,
    blocks.kind,
    blocks.label
  from blocks
  cross join day_window
  where blocks.starts_at < day_window.ends_at
    and blocks.blocked_until > day_window.starts_at
  order by blocks.starts_at, blocks.blocked_until;
$$;


--
-- Name: get_therapist_queue(uuid, date, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_therapist_queue(p_outlet_id uuid, p_date date, p_now_time time without time zone, p_duration integer) RETURNS TABLE(therapist_id uuid, name text, gender text, queue_position integer, status text, free_at time without time zone, reservation_start_at time without time zone, reservation_end_at time without time zone, free_in_minutes integer, protected_turn_owed boolean, is_recommended boolean, rotation_rank bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  return query
  with raw_availability as (
    select a.therapist_id, a.status, a.free_at, a.free_in_minutes
    from public.get_walkin_therapist_availability(
      p_date,
      p_now_time,
      p_duration
    ) a
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
            and appointment.actual_started_at <=
                ((p_date + p_now_time) at time zone 'Asia/Kuala_Lumpur')
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'busy_now'
        when exists (
          select 1
          from public.appointments appointment
          where appointment.therapist_id = raw.therapist_id
            and public.csp_blocks_schedule(appointment.status::text)
            and public.csp_appointment_start_at(appointment)
                  < p_date + p_now_time
                      + make_interval(mins => greatest(p_duration, 1))
            and public.csp_appointment_block_end_at(appointment)
                  > p_date + p_now_time
        ) then 'reserved'
        else 'busy'
      end status,
      raw.free_at,
      reservation.reservation_start_at,
      reservation.reservation_end_at,
      raw.free_in_minutes
    from raw_availability raw
    left join lateral (
      select
        public.csp_appointment_start_at(appointment)::time,
        public.csp_appointment_end_at(appointment)::time
      from public.appointments appointment
      where appointment.outlet_id = p_outlet_id
        and appointment.therapist_id = raw.therapist_id
        and appointment.actual_started_at is null
        and public.csp_blocks_schedule(appointment.status::text)
        and public.csp_appointment_start_at(appointment)
              < p_date + p_now_time
                  + make_interval(mins => greatest(p_duration, 1))
        and public.csp_appointment_block_end_at(appointment)
              > p_date + p_now_time
      order by public.csp_appointment_start_at(appointment), appointment.id
      limit 1
    ) reservation(
      reservation_start_at,
      reservation_end_at
    ) on raw.status <> 'free_now'
  ),
  ordered as (
    select
      queue_row.therapist_id,
      therapist.name,
      therapist.gender,
      queue_row.queue_position,
      availability.status,
      availability.free_at,
      availability.reservation_start_at,
      availability.reservation_end_at,
      availability.free_in_minutes,
      row_number() over (
        order by queue_row.queue_position, queue_row.therapist_id
      ) rotation_rank
    from public.therapist_queue queue_row
    join public.therapists therapist
      on therapist.id = queue_row.therapist_id
    join availability
      on availability.therapist_id = queue_row.therapist_id
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
  )
  select
    ordered.therapist_id,
    ordered.name,
    ordered.gender,
    ordered.queue_position,
    ordered.status,
    ordered.free_at,
    ordered.reservation_start_at,
    ordered.reservation_end_at,
    ordered.free_in_minutes,
    false,
    ordered.rotation_rank = (
      select min(candidate.rotation_rank)
      from ordered candidate
      where candidate.status = 'free_now'
    ),
    ordered.rotation_rank
  from ordered
  order by ordered.rotation_rank;
end;
$$;


--
-- Name: FUNCTION get_therapist_queue(p_outlet_id uuid, p_date date, p_now_time time without time zone, p_duration integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_therapist_queue(p_outlet_id uuid, p_date date, p_now_time time without time zone, p_duration integer) IS 'Returns the duration-aware live therapist queue in authoritative queue_position order.';


--
-- Name: get_today_queue_management(uuid, date, time without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_today_queue_management(p_outlet_id uuid, p_date date, p_now_time time without time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  perform public.seed_therapist_queue(p_outlet_id, p_date);

  with live_queue as (
    select queue_entry.*, therapist.profile_image_url
    from public.get_therapist_queue(
      p_outlet_id, p_date, p_now_time, 1
    ) queue_entry
    join public.therapists therapist
      on therapist.id = queue_entry.therapist_id
  ),
  current_next as (
    select live_queue.*
    from live_queue
    order by
      case when live_queue.is_recommended then 0 else 1 end,
      live_queue.rotation_rank
    limit 1
  )
  select jsonb_build_object(
    'queue_date', p_date,
    'starter', (
      select jsonb_build_object(
        'therapist_id', starter.id,
        'name', starter.name,
        'profile_image_url', starter.profile_image_url
      )
      from public.therapist_queue_day day_state
      join public.therapists starter
        on starter.id = day_state.starter_therapist_id
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'is_manual_override', coalesce((
      select day_state.is_manual_override
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ), false),
    'changed_by', (
      select day_state.changed_by
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'changed_at', (
      select day_state.changed_at
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'reason', (
      select day_state.override_reason
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'first_turn_consumed_at', public.today_queue_has_started(
      p_outlet_id, p_date
    ),
    'requires_reset_warning', public.today_queue_has_started(
      p_outlet_id, p_date
    ) is not null,
    'current_next', (
      select jsonb_build_object(
        'therapist_id', current_next.therapist_id,
        'name', current_next.name,
        'profile_image_url', current_next.profile_image_url,
        'status', current_next.status
      )
      from current_next
    ),
    'live_queue', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'therapist_id', live_queue.therapist_id,
          'name', live_queue.name,
          'gender', live_queue.gender,
          'profile_image_url', live_queue.profile_image_url,
          'queue_position', live_queue.queue_position,
          'status', live_queue.status,
          'free_at', live_queue.free_at,
          'protected_turn_owed', live_queue.protected_turn_owed,
          'is_recommended', live_queue.is_recommended,
          'rotation_rank', live_queue.rotation_rank
        ) order by live_queue.rotation_rank
      )
      from live_queue
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;


--
-- Name: get_walkin_room_availability(date, time without time zone, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_walkin_room_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid) RETURNS TABLE(available_now boolean, free_slots integer, total_slots integer, free_at time without time zone)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at
    + make_interval(mins => greatest(p_duration, 1));
  v_room_total integer := 1;
  v_room_booked integer := 0;
  v_free_at timestamp;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  select count(*), max(conflicts.ends_at)
  into v_room_booked, v_free_at
  from (
    select public.csp_appointment_end_at(a) as ends_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.room_id = p_room_id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_end_at(a) > v_start_at

    union all

    select h.end_at at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    where h.assigned_room_id = p_room_id
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
      and (h.end_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
  ) conflicts;

  free_slots := greatest(v_room_total - v_room_booked, 0);
  total_slots := v_room_total;
  available_now := free_slots > 0;
  free_at := v_free_at::time;
  return next;
end;
$$;


--
-- Name: get_walkin_therapist_availability(date, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_walkin_therapist_availability(p_today date, p_now_time time without time zone, p_duration integer) RETURNS TABLE(therapist_id uuid, name text, status text, free_at time without time zone, free_in_minutes integer)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at
    + make_interval(mins => greatest(p_duration, 1));
begin
  return query
  select
    staff.id,
    staff.name,
    case when busy.free_at is null then 'free_now' else 'busy' end,
    busy.free_at::time,
    case
      when busy.free_at is null then 0
      else greatest(
        floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer,
        0
      )
    end
  from public.therapists staff
  left join lateral (
    select max(public.csp_appointment_block_end_at(a)) as free_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.therapist_id = staff.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_block_end_at(a) > v_start_at
  ) busy on true
  where coalesce(staff.availability_status, true) = true
    and lower(coalesce(staff.role, 'therapist')) = 'therapist'
    and exists (
      select 1
      from public.therapist_working_hours wh
      join public.business_hours hours
        on hours.outlet_id = staff.outlet_id
       and hours.day_of_week = wh.day_of_week
       and not hours.is_closed
      where wh.therapist_id = staff.id
        and (
          (
            wh.day_of_week = extract(dow from p_today)::integer
            and p_today + wh.start_time <= v_start_at
            and p_today + wh.end_time
              + case
                  when wh.end_time <= wh.start_time then interval '1 day'
                  else interval '0'
                end >= v_end_at
          )
          or (
            wh.end_time <= wh.start_time
            and wh.day_of_week = extract(dow from p_today - 1)::integer
            and (p_today - 1) + wh.start_time <= v_start_at
            and (p_today - 1) + wh.end_time + interval '1 day' >= v_end_at
          )
        )
    )
    and not exists (
      select 1
      from public.therapist_unavailability unavailable
      where unavailable.therapist_id = staff.id
        and (unavailable.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
        and (unavailable.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
    )
  order by
    case when busy.free_at is null then 0 else 1 end,
    busy.free_at nulls first,
    staff.name;
end;
$$;


--
-- Name: initialize_appointment_therapist_allocation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.initialize_appointment_therapist_allocation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_started_at timestamptz;
begin
  if new.therapist_id is null then return new; end if;

  if new.therapist_id is distinct from old.therapist_id
    and coalesce(current_setting('app.therapist_switch_rpc', true), '') <> '1'
    and new.actual_started_at is null then
    delete from public.appointment_therapist_allocations where appointment_id = new.id;
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    ) values (new.id, new.therapist_id, 1, 'full', auth.uid());
  end if;

  if new.actual_started_at is not null and old.actual_started_at is null then
    v_started_at := new.actual_started_at;
    insert into public.appointment_therapist_segments (
      appointment_id, therapist_id, started_at, change_type, created_by
    ) values (new.id, new.therapist_id, v_started_at, 'initial', auth.uid())
    on conflict do nothing;

    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    ) values (new.id, new.therapist_id, 1, 'full', auth.uid())
    on conflict (appointment_id, therapist_id) do update
      set commission_share = 1, allocation_method = 'full', updated_at = now();
  end if;

  if new.status = 'completed' and old.status is distinct from 'completed' then
    update public.appointment_therapist_segments
    set ended_at = coalesce(new.actual_completed_at, now())
    where appointment_id = new.id and ended_at is null;
    perform public.recalculate_appointment_therapist_commission(new.id);
  end if;
  return new;
end;
$$;


--
-- Name: initialize_transaction_therapist_commission(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.initialize_transaction_therapist_commission() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_appointment_id uuid;
begin
  if new.payment_status <> 'paid' then return new; end if;
  if new.appointment_id is not null then
    perform public.recalculate_appointment_therapist_commission(new.appointment_id);
  elsif new.appointment_group_id is not null then
    for v_appointment_id in
      select id from public.appointments
      where appointment_group_id = new.appointment_group_id
    loop
      perform public.recalculate_appointment_therapist_commission(v_appointment_id);
    end loop;
  end if;
  return new;
end;
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  )
$$;


--
-- Name: is_staff_or_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_staff_or_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role in ('admin', 'staff')
  )
$$;


--
-- Name: list_public_booking_catalogue(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_public_booking_catalogue(p_outlet_code text) RETURNS TABLE(catalogue_id uuid, public_name text, short_description text, public_image_url text, display_price numeric, deposit_amount numeric, show_price boolean, duration_minutes integer, display_order integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select c.id, c.public_name, c.short_description, c.public_image_url,
         case when c.show_price then c.display_price else null end,
         c.deposit_amount, c.show_price, greatest(s.duration, 1)::integer, c.display_order
  from public.online_booking_services c
  join public.outlets o on o.id = c.outlet_id
  join public.online_booking_outlet_settings os on os.outlet_id = o.id
  join public.services s on s.id = c.service_id and s.outlet_id = c.outlet_id
  where o.code = lower(trim(p_outlet_code)) and o.is_active and os.online_booking_enabled
    and coalesce(s.is_active, true) and c.enabled
    and trim(c.public_name) <> '' and trim(c.short_description) <> '' and trim(c.public_image_url) <> ''
    and exists (select 1 from public.online_booking_service_rooms cr where cr.online_booking_service_id = c.id)
  order by c.display_order, c.public_name;
$$;


--
-- Name: list_public_booking_outlets(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_public_booking_outlets() RETURNS TABLE(code text, name text, address text, phone text, customer_therapist_selection_allowed boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select o.code, o.name, o.address, o.phone, s.customer_therapist_selection_allowed
  from public.outlets o
  join public.online_booking_outlet_settings s on s.outlet_id = o.id
  where o.is_active and s.online_booking_enabled
  order by o.name;
$$;


--
-- Name: list_public_booking_outlets_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_public_booking_outlets_v2() RETURNS TABLE(code text, name text, address text, phone text, customer_therapist_selection_allowed boolean, female_masseurs integer, male_masseurs integer, total_masseurs integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select o.code, o.name, o.address, o.phone, s.customer_therapist_selection_allowed,
    (select count(*) from public.therapists t
     where t.outlet_id = o.id and coalesce(t.availability_status, true)
       and lower(coalesce(t.role, 'therapist')) = 'therapist'
       and lower(coalesce(t.gender, '')) = 'female')::integer,
    (select count(*) from public.therapists t
     where t.outlet_id = o.id and coalesce(t.availability_status, true)
       and lower(coalesce(t.role, 'therapist')) = 'therapist'
       and lower(coalesce(t.gender, '')) = 'male')::integer,
    (select count(*) from public.therapists t
     where t.outlet_id = o.id and coalesce(t.availability_status, true)
       and lower(coalesce(t.role, 'therapist')) = 'therapist')::integer
  from public.outlets o
  join public.online_booking_outlet_settings s on s.outlet_id = o.id
  where o.is_active and s.online_booking_enabled
  order by o.name;
$$;


--
-- Name: mark_booking_group_payment_failed(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_booking_group_payment_failed(p_token uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  update public.booking_holds set status = 'payment_failed', updated_at = now()
  where booking_group_token = p_token and status = 'pending_payment';
$$;


--
-- Name: mark_booking_hold_payment_failed(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_booking_hold_payment_failed(p_token uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update public.booking_holds
  set status = 'payment_failed',
      updated_at = now()
  where public_token = p_token
    and status = 'pending_payment';
end;
$$;


--
-- Name: mark_past_appointments_no_show(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_past_appointments_no_show(p_outlet_id uuid DEFAULT NULL::uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_updated integer := 0;
begin
  update public.appointments a
  set status = 'no_show'::public.appointment_status,
      updated_at = now()
  where lower(a.status::text) in ('pending', 'confirmed')
    and coalesce(a.type::text, 'appointment') = 'appointment'
    and a.actual_started_at is null
    and (p_outlet_id is null or a.outlet_id = p_outlet_id)
    and coalesce(
      a.booked_start_at,
      a.start_at at time zone 'Asia/Kuala_Lumpur',
      public.csp_start_at(a.appointment_date::date, a.start_time::time)
        at time zone 'Asia/Kuala_Lumpur'
    ) + make_interval(
      mins => greatest(coalesce((
        select bs.no_show_threshold_minutes
        from public.business_settings bs
        where bs.outlet_id = a.outlet_id
        limit 1
      ), 30), 0)
    ) < now();

  get diagnostics v_updated = row_count;

  update public.booking_holds h
  set status = 'expired',
      expires_at = least(h.expires_at, now()),
      updated_at = now()
  where h.status = 'pending_payment'
    and (
      exists (
        select 1
        from public.appointments a
        where a.id = h.appointment_id
          and a.status = 'no_show'
      )
      or exists (
        select 1
        from public.appointments a
        where a.appointment_group_id = h.appointment_group_id
        group by a.appointment_group_id
        having bool_or(a.status = 'no_show')
          and bool_and(a.status in ('completed', 'cancelled', 'no_show'))
      )
    );

  update public.appointment_groups g
  set status = 'no_show'
  where (p_outlet_id is null or g.outlet_id = p_outlet_id)
    and exists (
      select 1
      from public.appointments a
      where a.appointment_group_id = g.id
      group by a.appointment_group_id
      having bool_or(a.status = 'no_show')
        and bool_and(a.status in ('completed', 'cancelled', 'no_show'))
    )
    and lower(coalesce(g.status, '')) <> 'no_show';

  return v_updated;
end;
$$;


--
-- Name: match_finalize_start_group_therapists(uuid, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.match_finalize_start_group_therapists(p_appointment_group_id uuid, p_pax_updates jsonb, p_started_at timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_appointment public.appointments%rowtype;
  v_update jsonb;
  v_items jsonb;
  v_requirements jsonb := '[]'::jsonb;
  v_source text;
  v_gender text;
  v_fixed uuid;
  v_service_ids jsonb;
  v_duration integer;
  v_start_local timestamp :=
    p_started_at at time zone 'Asia/Kuala_Lumpur';
  v_end_local timestamp;
  v_outlet_id uuid;
begin
  for v_appointment in
    select appointment.*
    from public.appointments appointment
    where appointment.appointment_group_id = p_appointment_group_id
    order by appointment.id
  loop
    if v_outlet_id is null then
      v_outlet_id := v_appointment.outlet_id;
    elsif v_outlet_id is distinct from v_appointment.outlet_id then
      return null;
    end if;

    v_update := coalesce(
      p_pax_updates -> v_appointment.id::text,
      '{}'::jsonb
    );
    if v_update = '{}'::jsonb then
      return null;
    end if;

    v_source := lower(coalesce(
      nullif(v_update ->> 'assignment_source', ''),
      nullif(v_appointment.assignment_source, ''),
      'queue'
    ));
    if v_source not in (
      'queue',
      'gender_preference',
      'specific_customer_request',
      'manual_override'
    ) then
      return null;
    end if;

    v_gender := case
      when v_source = 'gender_preference' then coalesce(
        nullif(v_update ->> 'requested_gender', ''),
        nullif(v_appointment.requested_gender, '')
      )
      else null
    end;
    if v_source = 'gender_preference' and v_gender is null then
      return null;
    end if;

    v_fixed := case
      when v_source in (
        'specific_customer_request',
        'manual_override'
      ) then coalesce(
        nullif(v_update ->> 'therapist_id', '')::uuid,
        v_appointment.requested_therapist_id,
        v_appointment.therapist_id
      )
      else null
    end;
    if v_source in (
      'specific_customer_request',
      'manual_override'
    ) and v_fixed is null then
      return null;
    end if;

    v_items := case
      when jsonb_typeof(v_update -> 'service_items') = 'array'
           and jsonb_array_length(v_update -> 'service_items') > 0
        then v_update -> 'service_items'
      else coalesce(v_appointment.service_items, '[]'::jsonb)
    end;

    select coalesce(
      jsonb_agg(distinct service_id),
      '[]'::jsonb
    )
    into v_service_ids
    from (
      select nullif(
        coalesce(item ->> 'id', item ->> 'serviceId'),
        ''
      ) service_id
      from jsonb_array_elements(v_items) item
    ) services
    where service_id is not null;
    if jsonb_array_length(v_service_ids) = 0
       and v_appointment.service_id is not null then
      v_service_ids := jsonb_build_array(v_appointment.service_id::text);
    end if;

    select coalesce(sum(greatest(
      coalesce(
        nullif(item ->> 'duration', '')::integer,
        service.duration,
        0
      ),
      0
    )), 0)::integer
    into v_duration
    from jsonb_array_elements(v_items) item
    left join public.services service
      on service.id = nullif(
        coalesce(item ->> 'id', item ->> 'serviceId'),
        ''
      )::uuid;

    if v_duration <= 0 then
      v_duration := greatest(
        ceil(extract(epoch from (
          public.csp_appointment_end_at(v_appointment)
          - public.csp_appointment_start_at(v_appointment)
        )) / 60.0)::integer,
        1
      );
    end if;

    v_end_local := coalesce(
      nullif(v_update ->> 'expected_end_at', '')::timestamptz
        at time zone 'Asia/Kuala_Lumpur',
      v_start_local + make_interval(mins => v_duration)
    );
    if v_end_local <= v_start_local then
      return null;
    end if;

    v_requirements := v_requirements || jsonb_build_array(
      jsonb_build_object(
        'appointment_id', v_appointment.id,
        'assignment_source', v_source,
        'requested_gender', v_gender,
        'fixed_therapist_id', v_fixed,
        'service_ids', v_service_ids,
        'start_local', v_start_local,
        'reserved_end_local',
          v_end_local + make_interval(
            mins => greatest(
              coalesce(v_appointment.buffer_after_minutes, 0),
              0
            )
          )
      )
    );
  end loop;

  if v_outlet_id is null or jsonb_array_length(v_requirements) = 0 then
    return null;
  end if;

  return public.match_finalize_start_therapists_recursive(
    v_requirements,
    0,
    array[]::uuid[],
    v_outlet_id,
    null,
    p_appointment_group_id
  );
end;
$$;


--
-- Name: match_finalize_start_therapists_recursive(jsonb, integer, uuid[], uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.match_finalize_start_therapists_recursive(p_requirements jsonb, p_requirement_index integer, p_used_therapists uuid[], p_outlet_id uuid, p_exclude_appointment_id uuid, p_exclude_appointment_group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_requirement jsonb;
  v_candidate record;
  v_tail jsonb;
  v_source text;
  v_start timestamp;
  v_reserved_end timestamp;
begin
  if p_requirement_index >= jsonb_array_length(p_requirements) then
    return '{}'::jsonb;
  end if;

  v_requirement := p_requirements -> p_requirement_index;
  v_source := lower(coalesce(
    nullif(v_requirement ->> 'assignment_source', ''),
    'queue'
  ));
  v_start := (v_requirement ->> 'start_local')::timestamp;
  v_reserved_end := (v_requirement ->> 'reserved_end_local')::timestamp;

  for v_candidate in
    select therapist.id
    from public.therapists therapist
    left join public.therapist_queue queue_row
      on queue_row.therapist_id = therapist.id
     and queue_row.outlet_id = p_outlet_id
     and queue_row.queue_date = v_start::date
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and not (therapist.id = any(coalesce(
        p_used_therapists,
        array[]::uuid[]
      )))
      and (
        v_source not in (
          'specific_customer_request',
          'manual_override'
        )
        or therapist.id = (
          v_requirement ->> 'fixed_therapist_id'
        )::uuid
      )
      and (
        v_source <> 'gender_preference'
        or lower(coalesce(therapist.gender, '')) = lower(
          v_requirement ->> 'requested_gender'
        )
      )
      and not exists (
        select 1
        from jsonb_array_elements_text(
          coalesce(v_requirement -> 'service_ids', '[]'::jsonb)
        ) service_id(value)
        where coalesce(therapist.service_commissions, '{}'::jsonb)
              <> '{}'::jsonb
          and not (therapist.service_commissions ? service_id.value)
      )
      and exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = therapist.id
          and (
            (
              hours.day_of_week = extract(dow from v_start::date)::integer
              and v_start::date + hours.start_time <= v_start
              and v_start::date + hours.end_time
                + case
                    when hours.end_time <= hours.start_time
                      then interval '1 day'
                    else interval '0'
                  end
                >= v_reserved_end
            )
            or (
              hours.end_time <= hours.start_time
              and hours.day_of_week =
                extract(dow from v_start::date - 1)::integer
              and (v_start::date - 1) + hours.start_time <= v_start
              and (v_start::date - 1) + hours.end_time + interval '1 day'
                >= v_reserved_end
            )
          )
      )
      and not exists (
        select 1
        from public.therapist_unavailability unavailable
        where unavailable.therapist_id = therapist.id
          and unavailable.starts_at at time zone 'Asia/Kuala_Lumpur'
              < v_reserved_end
          and unavailable.ends_at at time zone 'Asia/Kuala_Lumpur'
              > v_start
      )
      and not exists (
        select 1
        from public.appointments appointment
        where appointment.therapist_id = therapist.id
          and appointment.id is distinct from p_exclude_appointment_id
          and public.csp_blocks_schedule(appointment.status::text)
          and public.csp_appointment_start_at(appointment) < v_reserved_end
          and public.csp_appointment_block_end_at(appointment) > v_start
          and (
            p_exclude_appointment_group_id is null
            or appointment.appointment_group_id is distinct from
              p_exclude_appointment_group_id
          )
      )
      and not exists (
        select 1
        from public.booking_holds hold
        where hold.assigned_therapist_id = therapist.id
          and hold.status = 'pending_payment'
          and hold.expires_at > now()
          and coalesce(hold.hold_kind, '') <> 'staff_walkin_draft'
          and hold.start_at at time zone 'Asia/Kuala_Lumpur'
              < v_reserved_end
          and (
            hold.end_at + make_interval(
              mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)
            )
          ) at time zone 'Asia/Kuala_Lumpur' > v_start
      )
    order by
      case
        when v_source in (
          'specific_customer_request',
          'manual_override'
        ) then 0
        else 1
      end,
      case when coalesce(queue_row.protected_turn_owed, false) then 0 else 1 end,
      queue_row.queue_position nulls last,
      therapist.display_order nulls last,
      therapist.name,
      therapist.id
  loop
    v_tail := public.match_finalize_start_therapists_recursive(
      p_requirements,
      p_requirement_index + 1,
      array_append(
        coalesce(p_used_therapists, array[]::uuid[]),
        v_candidate.id
      ),
      p_outlet_id,
      p_exclude_appointment_id,
      p_exclude_appointment_group_id
    );
    if v_tail is not null then
      return jsonb_build_object(
        v_requirement ->> 'appointment_id',
        v_candidate.id
      ) || v_tail;
    end if;
  end loop;

  return null;
end;
$$;


--
-- Name: normalize_appointment_addon_transaction(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_appointment_addon_transaction() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_item jsonb;
  v_owner_id uuid;
  v_first_owner_id uuid;
  v_multiple_owners boolean := false;
begin
  if new.source::text <> 'appointment_addon' then return new; end if;

  for v_item in
    select value from jsonb_array_elements(coalesce(new.service_items, '[]'::jsonb))
  loop
    v_owner_id := nullif(coalesce(
      v_item ->> 'appointmentId', v_item ->> 'appointment_id'
    ), '')::uuid;
    if v_owner_id is null then continue; end if;
    if v_first_owner_id is null then
      v_first_owner_id := v_owner_id;
    elsif v_first_owner_id <> v_owner_id then
      v_multiple_owners := true;
    end if;
  end loop;

  if v_first_owner_id is not null and not v_multiple_owners then
    new.appointment_id := v_first_owner_id;
    select
      a.therapist_id,
      coalesce(t.name, ''),
      a.room_id,
      coalesce(r.name, '')
    into new.therapist_id, new.therapist_name, new.room_id, new.room_name
    from public.appointments a
    left join public.therapists t on t.id = a.therapist_id
    left join public.rooms r on r.id = a.room_id
    where a.id = v_first_owner_id;
  elsif v_multiple_owners then
    new.appointment_id := null;
    new.therapist_id := null;
    new.therapist_name := 'Multiple therapists';
    new.room_id := null;
    new.room_name := 'Multiple rooms';
  end if;

  new.therapist_commission_amount :=
    public.csp_commission_for_transaction_items(
      new.service_items, new.therapist_id
    );
  return new;
end;
$$;


--
-- Name: normalize_appointment_assignment_states(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_appointment_assignment_states() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
declare
  v_cf_enabled boolean;
begin
  -- Deployed prologue, shared by both branches.
  new.therapist_assignment_state := coalesce(nullif(new.therapist_assignment_state, ''), 'pending');
  new.room_assignment_state := coalesce(nullif(new.room_assignment_state, ''), 'pending');

  v_cf_enabled := public.capacity_first_enabled(new.outlet_id);

  if not v_cf_enabled then
    -- Preserve exact deployed behavior.
    if new.actual_started_at is not null
       or new.status::text in ('in_progress', 'completed')
       or new.type::text = 'walkin' then
      new.therapist_assignment_state := 'confirmed';
      new.room_assignment_state := 'confirmed';
      new.resources_confirmed_at := coalesce(new.resources_confirmed_at, new.actual_started_at, now());
      new.resources_confirmed_by := coalesce(new.resources_confirmed_by, auth.uid());
    elsif new.assignment_source in ('specific_customer_request', 'manual_override') then
      new.therapist_assignment_state := 'confirmed';
    end if;

    if new.therapist_assignment_state = 'auto_assigned' then
      new.therapist_auto_assigned_at := coalesce(new.therapist_auto_assigned_at, now());
    end if;

    if new.therapist_assignment_state = 'confirmed'
       and new.room_assignment_state = 'confirmed' then
      new.resources_confirmed_at := coalesce(new.resources_confirmed_at, now());
    end if;

    return new;
  end if;

  -- Capacity-first (flag ON): an absent concrete resource reads back as pending.
  if new.therapist_id is null then
    new.therapist_assignment_state := 'pending';
    new.therapist_auto_assigned_at := null;
  end if;

  if new.room_id is null then
    new.room_assignment_state := 'pending';
    new.room_unit_id := null;
    new.room_unit_name := '';
  end if;

  if new.actual_started_at is not null
     or new.status::text in ('in_progress', 'completed')
     or new.type::text = 'walkin' then
    new.therapist_assignment_state := 'confirmed';
    new.room_assignment_state := 'confirmed';
    new.resources_confirmed_at := coalesce(new.resources_confirmed_at, new.actual_started_at, now());
    new.resources_confirmed_by := coalesce(new.resources_confirmed_by, auth.uid());
  else
    if new.assignment_source = 'specific_customer_request'
       and new.therapist_id is not null then
      new.therapist_assignment_state := 'confirmed';
    elsif new.assignment_source = 'manual_override' then
      if new.therapist_id is not null then
        new.therapist_assignment_state := 'confirmed';
      end if;
      if new.room_id is not null then
        new.room_assignment_state := 'confirmed';
      end if;
    end if;
  end if;

  if new.therapist_assignment_state = 'auto_assigned'
     and new.therapist_id is not null then
    new.therapist_auto_assigned_at := coalesce(new.therapist_auto_assigned_at, now());
  end if;

  if new.therapist_assignment_state = 'confirmed'
     and new.room_assignment_state = 'confirmed' then
    new.resources_confirmed_at := coalesce(new.resources_confirmed_at, now());
  elsif new.actual_started_at is null
        and new.status::text not in ('in_progress', 'completed') then
    new.resources_confirmed_at := null;
    new.resources_confirmed_by := null;
  end if;

  return new;
end;
$$;


--
-- Name: normalize_my_phone(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_my_phone(p_phone text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select case
    when p_phone is null or regexp_replace(p_phone, '\D', '', 'g') = '' then null
    when regexp_replace(p_phone, '\D', '', 'g') like '60%' then regexp_replace(p_phone, '\D', '', 'g')
    when regexp_replace(p_phone, '\D', '', 'g') like '0%' then '6' || regexp_replace(p_phone, '\D', '', 'g')
    else '60' || regexp_replace(p_phone, '\D', '', 'g')
  end;
$$;


--
-- Name: notify_appointment_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_appointment_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_customer text;
  v_when text;
  v_type text;
  v_title text;
begin
  if new.actual_started_at is not null
     and old.actual_started_at is null then
    v_type := 'appointment_checked_in';
    v_title := 'Customer checked in';
  -- The app's void action sets status=cancelled and payment_status=voided in
  -- the same update. Check void first so that action is not mislabeled as a
  -- plain cancellation.
  elsif new.payment_status::text = 'voided'
     and old.payment_status::text <> 'voided' then
    v_type := 'appointment_voided';
    v_title := 'Appointment voided';
  elsif new.status::text = 'cancelled' and old.status::text <> 'cancelled' then
    v_type := 'appointment_cancelled';
    v_title := 'Appointment cancelled';
  else
    return new;
  end if;

  -- One notification per group action, not one per pax.
  if new.appointment_group_id is not null and exists (
    select 1 from public.notifications n
    where n.appointment_group_id = new.appointment_group_id
      and n.type = v_type
      and n.created_at > now() - interval '1 minute'
  ) then
    return new;
  end if;

  select coalesce(c.name, 'Guest') into v_customer
  from public.customers c where c.id = new.customer_id;
  v_customer := coalesce(v_customer, 'Guest');

  v_when := format(
    '%s %s',
    to_char(new.appointment_date::date, 'DD Mon'),
    left(new.start_time::text, 5)
  );

  insert into public.notifications (
    outlet_id, type, title, body, appointment_id, appointment_group_id
  ) values (
    new.outlet_id,
    v_type,
    format('%s - %s', v_title, v_customer),
    format('%s on %s', coalesce(nullif(new.service_name, ''), 'Appointment'), v_when),
    new.id,
    new.appointment_group_id
  );

  return new;
end;
$$;


--
-- Name: notify_booking_hold_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_booking_hold_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_service_name text := '';
  v_when text := '';
  v_event_type text;
  v_already boolean := false;
begin
  -- confirm_public_booking_hold flips status to 'confirmed' BEFORE the
  -- appointment exists and backfills appointment_id in a later update, so
  -- the trigger listens to both columns and only notifies once the
  -- appointment link is in place.
  if new.status = 'confirmed' then
    if new.appointment_id is null then return new; end if;
    v_event_type := 'new_online_appointment';
  elsif new.status = 'payment_failed' and old.status = 'pending_payment' then
    v_event_type := 'payment_failed';
  elsif new.status = 'expired'
     and old.status is distinct from 'expired'
     and new.billplz_bill_id is not null then
    v_event_type := 'payment_expired';
  else
    return new;
  end if;

  -- Never notify twice for the same hold, and for group bookings (several
  -- holds flipped one after another) notify once per group per event type.
  select exists (
    select 1
    from public.notifications n
    join public.booking_holds h on h.id = n.booking_hold_id
    where n.type = v_event_type
      and (
        h.id = new.id
        or (
          new.booking_group_token is not null
          and h.booking_group_token = new.booking_group_token
        )
      )
  ) into v_already;
  if v_already then
    -- Group confirmation creates the individual appointments before it creates
    -- the appointment_group row. When that later link arrives, enrich the one
    -- deduplicated notification instead of leaving it attached to Pax 1 only.
    if v_event_type = 'new_online_appointment'
       and new.appointment_group_id is not null then
      update public.notifications n
      set appointment_group_id = new.appointment_group_id
      from public.booking_holds h
      where h.id = n.booking_hold_id
        and n.type = v_event_type
        and (
          h.id = new.id
          or (
            new.booking_group_token is not null
            and h.booking_group_token = new.booking_group_token
          )
        );
    end if;
    return new;
  end if;

  select coalesce(s.name, c.public_name, 'Online booking')
  into v_service_name
  from public.online_booking_services c
  left join public.services s on s.id = c.service_id
  where c.id = new.online_booking_service_id;
  v_service_name := coalesce(v_service_name, 'Online booking');

  v_when := to_char(new.start_at at time zone 'Asia/Kuala_Lumpur', 'DD Mon, HH24:MI');

  if new.status = 'confirmed' then
    insert into public.notifications (
      outlet_id, type, title, body,
      appointment_id, appointment_group_id, booking_hold_id
    ) values (
      new.outlet_id,
      'new_online_appointment',
      case when new.booking_group_token is not null
        then format('New online group booking - %s', coalesce(new.customer_name, 'Customer'))
        else format('New online booking - %s', coalesce(new.customer_name, 'Customer'))
      end,
      format('%s on %s', v_service_name, v_when),
      new.appointment_id, new.appointment_group_id, new.id
    );
  elsif new.status = 'payment_failed' then
    insert into public.notifications (
      outlet_id, type, title, body, booking_hold_id, appointment_group_id
    ) values (
      new.outlet_id,
      'payment_failed',
      format('Online payment failed - %s', coalesce(new.customer_name, 'Customer')),
      format('%s on %s (RM %s)', v_service_name, v_when,
             to_char(coalesce(new.total_amount, 0), 'FM999G999D00')),
      new.id, new.appointment_group_id
    );
  elsif new.status = 'expired' then
    -- Only holds where the customer actually reached the payment page
    -- (billplz_bill_id set); silently abandoned carts would just be noise.
    insert into public.notifications (
      outlet_id, type, title, body, booking_hold_id, appointment_group_id
    ) values (
      new.outlet_id,
      'payment_expired',
      format('Online booking expired unpaid - %s', coalesce(new.customer_name, 'Customer')),
      format('%s on %s was not paid in time', v_service_name, v_when),
      new.id, new.appointment_group_id
    );
  end if;

  return new;
end;
$$;


--
-- Name: notify_transaction_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_transaction_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_amount text;
  v_payment_type text;
  v_payment_title text;
begin
  v_amount := to_char(coalesce(new.total_amount, 0), 'FM999G999D00');

  -- Every successful payment belongs in the operational feed. Online
  -- payments keep their more specific label.
  if new.payment_status::text = 'paid'
     and (tg_op = 'INSERT' or old.payment_status::text <> 'paid') then
    v_payment_type := case
      when new.source::text = 'online_booking' then 'online_payment_received'
      else 'payment_received'
    end;
    v_payment_title := case
      when new.source::text = 'online_booking' then 'Online payment received'
      else 'Payment received'
    end;
    if not exists (
      select 1 from public.notifications n
      where n.transaction_id = new.id and n.type = v_payment_type
    ) then
      insert into public.notifications (
        outlet_id, type, title, body,
        transaction_id, appointment_id, appointment_group_id
      ) values (
        new.outlet_id,
        v_payment_type,
        format('%s - RM %s', v_payment_title, v_amount),
        format('%s (%s)',
               coalesce(nullif(new.customer_name, ''), 'Customer'),
               coalesce(nullif(new.service_name, ''), 'Service')),
        new.id, new.appointment_id, new.appointment_group_id
      );
    end if;
  end if;

  if tg_op = 'UPDATE' then
    -- Refund completed.
    if new.payment_status::text = 'refunded' and old.payment_status::text <> 'refunded' then
      insert into public.notifications (
        outlet_id, type, title, body,
        transaction_id, appointment_id, appointment_group_id
      ) values (
        new.outlet_id,
        'refund_completed',
        format('Refund completed - RM %s', v_amount),
        format('%s (%s)',
               coalesce(nullif(new.customer_name, ''), 'Customer'),
               coalesce(nullif(new.receipt_number, ''), 'transaction')),
        new.id, new.appointment_id, new.appointment_group_id
      );
    end if;

    -- A paid transaction that changed amount, or slipped back to unpaid,
    -- deserves a human look.
    if (old.payment_status::text = 'paid' and new.payment_status::text = 'unpaid')
       or (old.payment_status::text = 'paid' and new.payment_status::text = 'paid'
           and new.total_amount is distinct from old.total_amount) then
      insert into public.notifications (
        outlet_id, type, title, body,
        transaction_id, appointment_id, appointment_group_id
      ) values (
        new.outlet_id,
        'transaction_review',
        'Transaction needs review',
        format('%s changed after payment (RM %s -> RM %s)',
               coalesce(nullif(new.receipt_number, ''), 'Transaction'),
               to_char(coalesce(old.total_amount, 0), 'FM999G999D00'),
               v_amount),
        new.id, new.appointment_id, new.appointment_group_id
      );
    end if;
  end if;

  return new;
end;
$$;


--
-- Name: outlet_payment_breakdown(uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric) RETURNS TABLE(service_price numeric, sst_amount numeric, total_amount numeric)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select *
  from public.outlet_payment_breakdown(
    p_outlet_id,
    p_display_price,
    'counter'
  );
$$;


--
-- Name: outlet_payment_breakdown(uuid, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric, p_payment_origin text) RETURNS TABLE(service_price numeric, sst_amount numeric, total_amount numeric)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: pay_appointment_addons(uuid, jsonb, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pay_appointment_addons(p_appointment_id uuid, p_addon_service_items jsonb, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_items jsonb;
  v_first_item jsonb;
  v_service_id uuid;
  v_service_name text;
  v_therapist_name text := '';
  v_room_name text := '';
  v_transaction_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment from public.appointments
  where id = p_appointment_id for update;

  if not found then
    return query select false, p_appointment_id, null::uuid,
      'NOT_FOUND', 'Appointment was not found.';
    return;
  end if;
  if v_appointment.payment_status <> 'paid' then
    return query select false, p_appointment_id, null::uuid,
      'NOT_PAID', 'The original appointment payment has not been recorded.';
    return;
  end if;
  if v_appointment.actual_started_at is not null
      or v_appointment.status not in ('pending', 'confirmed') then
    return query select false, p_appointment_id, null::uuid,
      'ALREADY_STARTED', 'Add-ons must be paid before the service starts.';
    return;
  end if;
  if jsonb_array_length(coalesce(p_addon_service_items, '[]'::jsonb)) = 0
      or coalesce(p_total_amount, 0) <= 0 then
    return query select false, p_appointment_id, null::uuid,
      'NO_ADDONS', 'No payable add-on services were supplied.';
    return;
  end if;

  if exists (
    select 1
    from public.transactions t
    cross join lateral jsonb_array_elements(coalesce(t.service_items, '[]'::jsonb)) paid
    join lateral jsonb_array_elements(p_addon_service_items) supplied on
      coalesce(paid ->> 'id', paid ->> 'serviceId', paid ->> 'service_id') =
      coalesce(supplied ->> 'id', supplied ->> 'serviceId', supplied ->> 'service_id')
    where t.appointment_id = p_appointment_id
      and t.source = 'appointment_addon'
      and t.payment_status = 'paid'
  ) then
    return query select false, p_appointment_id, null::uuid,
      'ALREADY_PAID', 'One or more add-on services have already been paid.';
    return;
  end if;

  select coalesce(jsonb_agg(
    item || jsonb_build_object('appointment_id', p_appointment_id)
  ), '[]'::jsonb) into v_items
  from jsonb_array_elements(p_addon_service_items) item;

  select * into v_customer from public.customers
  where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_appointment.room_id;

  v_first_item := v_items -> 0;
  v_service_id := nullif(coalesce(
    v_first_item ->> 'id', v_first_item ->> 'serviceId',
    v_first_item ->> 'service_id'
  ), '')::uuid;
  v_service_name := coalesce(v_first_item ->> 'name', 'Service add-on');

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_appointment.outlet_id, p_appointment_id, v_appointment.customer_id,
    coalesce(v_customer.name, ''), coalesce(v_customer.phone, ''),
    v_service_id, v_service_name, v_items, jsonb_array_length(v_items),
    v_appointment.therapist_id, v_therapist_name,
    p_counter_staff_id, p_counter_staff_name,
    v_appointment.room_id, v_room_name,
    p_service_price, p_sst_amount, p_total_amount,
    public.csp_commission_for_items(v_items, v_appointment.therapist_id, 'Therapist'),
    case when p_counter_staff_id is null then 0
      else public.csp_commission_for_items(v_items, p_counter_staff_id, 'Counter') end,
    'appointment_addon',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    'Appointment add-ons paid before check-in'
  ) returning id into v_transaction_id;

  return query select true, p_appointment_id, v_transaction_id,
    null::text, null::text;
end;
$$;


--
-- Name: pay_appointment_group_addons(uuid, uuid[], jsonb, uuid, text, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pay_appointment_group_addons(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_counter_staff_id uuid DEFAULT NULL::uuid, p_counter_staff_name text DEFAULT NULL::text, p_service_price numeric DEFAULT 0, p_sst_amount numeric DEFAULT 0, p_total_amount numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_receipt_number text DEFAULT ''::text) RETURNS TABLE(success boolean, appointment_group_id uuid, transaction_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_id uuid;
  v_appointment public.appointments%rowtype;
  v_first public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_items jsonb;
  v_tagged_items jsonb;
  v_all_items jsonb := '[]'::jsonb;
  v_first_item jsonb;
  v_service_id uuid;
  v_service_name text;
  v_therapist_name text := '';
  v_room_name text := '';
  v_therapist_commission numeric := 0;
  v_transaction_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  if p_appointment_ids is null or cardinality(p_appointment_ids) = 0
      or cardinality(p_appointment_ids) <> (
        select count(*)::integer from public.appointments a
        where a.appointment_group_id = p_appointment_group_id
      ) then
    return query select false, p_appointment_group_id, null::uuid,
      'INVALID_APPOINTMENTS', 'The complete appointment group is required.';
    return;
  end if;
  if coalesce(p_total_amount, 0) <= 0 or not exists (
    select 1 from jsonb_each(coalesce(p_addon_items_by_appointment, '{}'::jsonb)) item
    where jsonb_typeof(item.value) = 'array'
      and jsonb_array_length(item.value) > 0
  ) then
    return query select false, p_appointment_group_id, null::uuid,
      'NO_ADDONS', 'No payable add-on services were supplied.';
    return;
  end if;

  foreach v_id in array p_appointment_ids loop
    select * into v_appointment from public.appointments a
    where a.id = v_id and a.appointment_group_id = p_appointment_group_id
    for update;
    if not found or v_appointment.payment_status <> 'paid' then
      return query select false, p_appointment_group_id, null::uuid,
        'NOT_PAID', 'Every group appointment must retain its original payment.';
      return;
    end if;
    if v_appointment.actual_started_at is not null
        or v_appointment.status not in ('pending', 'confirmed') then
      return query select false, p_appointment_group_id, null::uuid,
        'ALREADY_STARTED', 'Add-ons must be paid before the group service starts.';
      return;
    end if;
    if v_first.id is null then v_first := v_appointment; end if;

    v_items := coalesce(p_addon_items_by_appointment -> v_id::text, '[]'::jsonb);
    if jsonb_array_length(v_items) = 0 then continue; end if;

    if exists (
      select 1
      from public.transactions t
      cross join lateral jsonb_array_elements(coalesce(t.service_items, '[]'::jsonb)) paid
      join lateral jsonb_array_elements(v_items) supplied on
        coalesce(paid ->> 'id', paid ->> 'serviceId', paid ->> 'service_id') =
        coalesce(supplied ->> 'id', supplied ->> 'serviceId', supplied ->> 'service_id')
      where t.appointment_group_id = p_appointment_group_id
        and t.source = 'appointment_addon'
        and t.payment_status = 'paid'
        and coalesce(paid ->> 'appointmentId', paid ->> 'appointment_id') = v_id::text
    ) then
      return query select false, p_appointment_group_id, null::uuid,
        'ALREADY_PAID', 'One or more group add-on services have already been paid.';
      return;
    end if;

    select coalesce(jsonb_agg(
      item || jsonb_build_object('appointment_id', v_id)
    ), '[]'::jsonb) into v_tagged_items
    from jsonb_array_elements(v_items) item;
    v_all_items := v_all_items || v_tagged_items;
    v_therapist_commission := v_therapist_commission
      + public.csp_commission_for_items(
          v_tagged_items, v_appointment.therapist_id, 'Therapist'
        );
  end loop;

  select * into v_customer from public.customers where id = v_first.customer_id;
  select coalesce(name, '') into v_therapist_name
  from public.therapists where id = v_first.therapist_id;
  select coalesce(name, '') into v_room_name
  from public.rooms where id = v_first.room_id;
  v_first_item := v_all_items -> 0;
  v_service_id := nullif(coalesce(
    v_first_item ->> 'id', v_first_item ->> 'serviceId',
    v_first_item ->> 'service_id'
  ), '')::uuid;
  v_service_name := coalesce(v_first_item ->> 'name', 'Service add-on');

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_first.outlet_id, p_appointment_group_id, v_first.customer_id,
    coalesce(v_customer.name, ''), coalesce(v_customer.phone, ''),
    v_service_id, v_service_name, v_all_items, jsonb_array_length(v_all_items),
    v_first.therapist_id, v_therapist_name,
    p_counter_staff_id, p_counter_staff_name,
    v_first.room_id, v_room_name,
    p_service_price, p_sst_amount, p_total_amount,
    v_therapist_commission,
    case when p_counter_staff_id is null then 0
      else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end,
    'appointment_addon',
    coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number,
    'Group appointment add-ons paid before check-in'
  ) returning id into v_transaction_id;

  return query select true, p_appointment_group_id, v_transaction_id,
    null::text, null::text;
end;
$$;


--
-- Name: prevent_appointment_resource_overlap(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_appointment_resource_overlap() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: prevent_staff_hours_on_closed_day(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_staff_hours_on_closed_day() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if exists (
    select 1
    from public.business_hours hours
    where hours.outlet_id = new.outlet_id
      and hours.day_of_week = new.day_of_week
      and hours.is_closed
  ) then
    raise exception 'The outlet is closed on this weekday';
  end if;
  return new;
end;
$$;


--
-- Name: preview_check_in(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.preview_check_in(p_appointment_id uuid DEFAULT NULL::uuid, p_group_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then raise exception 'Not authorised'; end if;
  if p_appointment_id is null and p_group_id is null then
    raise exception 'preview_check_in requires an appointment id or group id'; end if;
  select jsonb_agg(row_to_json(t)::jsonb order by (t.pax)) into v_rows
  from (
    select a.id, a.appointment_group_id, a.service_id, a.service_name, a.service_items,
      a.item_count, a.total_price, a.payment_status, a.status,
      a.appointment_date, a.start_time, a.end_time, a.therapist_id, a.room_id, a.room_unit_id,
      a.therapist_assignment_state, a.room_assignment_state,
      a.assignment_source, a.requested_therapist_id, a.requested_gender,
      row_number() over (order by a.start_time, a.id) as pax,
      coalesce(a.therapist_id, (
        select th.id from public.therapists th
        where th.outlet_id = a.outlet_id and coalesce(th.availability_status,true)
          and lower(coalesce(th.role,'therapist')) = 'therapist'
          and (a.requested_gender is null or lower(th.gender) = lower(a.requested_gender))
          and (th.service_commissions = '{}'::jsonb or th.service_commissions ? a.service_id::text)
          and not exists (select 1 from public.appointments b where b.therapist_id = th.id and b.id <> a.id
              and public.csp_blocks_schedule(b.status::text)
              and public.csp_appointment_start_at(b) < public.csp_appointment_block_end_at(a)
              and public.csp_appointment_block_end_at(b) > public.csp_appointment_start_at(a))
        order by th.name limit 1)) as provisional_therapist_id,
      coalesce(a.room_id, (
        select r.id from public.rooms r join public.services s on s.id = a.service_id
        where r.outlet_id = a.outlet_id and coalesce(r.is_active,true)
          and lower(coalesce(r.room_type::text,'')) = lower(coalesce(s.room_type::text,''))
        order by r.name limit 1)) as provisional_room_id,
      (a.therapist_id is null or a.room_id is null) as is_provisional
    from public.appointments a
    where (p_group_id is not null and a.appointment_group_id = p_group_id)
       or (p_group_id is null and a.id = p_appointment_id)
  ) t;
  if v_rows is null then raise exception 'Appointment or group was not found.'; end if;
  return jsonb_build_object('appointments', v_rows,
    'total_amount', (select sum((r ->> 'total_price')::numeric) from jsonb_array_elements(v_rows) r),
    'payment_status', (select min(r ->> 'payment_status') from jsonb_array_elements(v_rows) r),
    'note', 'Suggestions are PROVISIONAL. Concrete resources are selected and confirmed only by confirm_and_start.');
end;
$$;


--
-- Name: process_paid_public_booking_group(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_paid_public_booking_group(p_token uuid, p_bill_id text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: process_paid_public_booking_hold(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_paid_public_booking_hold(p_token uuid, p_bill_id text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: project_appointment_end_on_actual_start(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.project_appointment_end_on_actual_start() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_booked_date date;
  v_booked_start_time time;
  v_booked_end_time time;
  v_booked_start_local timestamp;
  v_booked_end_local timestamp;
  v_duration interval;
  v_actual_local timestamp;
  v_end_local timestamp;
  v_supplied_end timestamp;
begin
  if new.actual_started_at is null then
    return new;
  end if;

  -- Idempotent: never re-anchor or re-extend an already-started service.
  if tg_op = 'UPDATE' and old.actual_started_at is not null then
    return new;
  end if;

  -- Scheduled truth. Prefer the booked snapshot; on UPDATE fall back to the
  -- PRE-UPDATE row, because the same statement may already have replaced
  -- start_time/end_time with check-in values; only then fall back to NEW.
  v_booked_date := coalesce(
    new.booked_date,
    case when tg_op = 'UPDATE' then old.appointment_date end,
    new.appointment_date
  );
  v_booked_start_time := coalesce(
    new.booked_start_time,
    case when tg_op = 'UPDATE' then old.start_time end,
    new.start_time
  );
  v_booked_end_time := coalesce(
    new.booked_end_time,
    case when tg_op = 'UPDATE' then old.end_time end,
    new.end_time
  );

  v_booked_start_local := public.csp_start_at(v_booked_date, v_booked_start_time);
  v_booked_end_local := public.csp_end_at(
    v_booked_date, v_booked_start_time, v_booked_end_time
  );
  v_duration := v_booked_end_local - v_booked_start_local;

  if v_duration is null or v_duration <= interval '0 seconds' then
    raise exception using
      errcode = '22023',
      message = 'Service duration must be greater than zero.';
  end if;

  if v_duration >= interval '24 hours' then
    raise exception using
      errcode = '22023',
      message = 'Service duration must be under 24 hours; the scheduled start/end pair is inconsistent.';
  end if;

  -- booked_start_at / booked_end_at ARE timestamptz: convert local -> tz.
  new.booked_date := v_booked_date;
  new.booked_start_time := v_booked_start_time;
  new.booked_end_time := v_booked_end_time;
  new.booked_start_at := coalesce(
    new.booked_start_at, v_booked_start_local at time zone 'Asia/Kuala_Lumpur'
  );
  new.booked_end_at := coalesce(
    new.booked_end_at, v_booked_end_local at time zone 'Asia/Kuala_Lumpur'
  );

  -- actual_started_at IS timestamptz: convert tz -> local.
  v_actual_local := new.actual_started_at at time zone 'Asia/Kuala_Lumpur';

  -- end_at is ALREADY a local timestamp: no conversion (this was the bug).
  v_supplied_end := new.end_at;

  if v_supplied_end is not null
     and v_supplied_end > v_actual_local
     and v_supplied_end - v_actual_local < interval '24 hours' then
    v_end_local := v_supplied_end;
  else
    v_end_local := v_actual_local + v_duration;
  end if;

  -- Anchor the OPERATIONAL window to the actual start. start_at / end_at are
  -- local timestamps and are assigned directly.
  new.appointment_date := v_actual_local::date;
  new.start_time := v_actual_local::time;
  new.end_time := v_end_local::time;
  new.start_at := v_actual_local;
  new.end_at := v_end_local;

  return new;
end;
$$;


--
-- Name: protect_therapist_commission_overrides(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_therapist_commission_overrides() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.commission_overrides, '{}'::jsonb) <> '{}'::jsonb
       and not public.is_admin() then
      raise exception using
        errcode = '42501',
        message = 'Only an administrator can set staff commission overrides.';
    end if;
  elsif new.commission_overrides is distinct from old.commission_overrides
        and not public.is_admin() then
    raise exception using
      errcode = '42501',
      message = 'Only an administrator can change staff commission overrides.';
  end if;

  return new;
end;
$$;


--
-- Name: queue_business_hours_assignment_reconcile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_business_hours_assignment_reconcile() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: reactivate_no_show_appointment(uuid, date, time without time zone, time without time zone, uuid, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reactivate_no_show_appointment(p_appointment_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid DEFAULT NULL::uuid, p_updates jsonb DEFAULT '{}'::jsonb) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: FUNCTION reactivate_no_show_appointment(p_appointment_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_updates jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.reactivate_no_show_appointment(p_appointment_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_updates jsonb) IS 'Atomically reschedules and reactivates one no-show while preserving payment, transactions and audited no-show history.';


--
-- Name: rebuild_therapist_queue_from_starter(uuid, date, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rebuild_therapist_queue_from_starter(p_outlet_id uuid, p_date date, p_starter_therapist_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_day_of_week integer := extract(dow from p_date)::integer;
  v_starter_order integer;
begin
  select therapist.display_order
  into v_starter_order
  from public.therapists therapist
  where therapist.id = p_starter_therapist_id
    and therapist.outlet_id = p_outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and exists (
      select 1
      from public.therapist_working_hours working_hours
      join public.business_hours outlet_hours
        on outlet_hours.outlet_id = therapist.outlet_id
       and outlet_hours.day_of_week = working_hours.day_of_week
       and not coalesce(outlet_hours.is_closed, false)
      where working_hours.therapist_id = therapist.id
        and working_hours.day_of_week = v_day_of_week
    );

  if v_starter_order is null then
    raise exception using
      errcode = '22023',
      message = 'The selected starter is not an active scheduled therapist for this outlet today.';
  end if;

  delete from public.therapist_queue
  where outlet_id = p_outlet_id and queue_date = p_date;

  insert into public.therapist_queue (
    outlet_id, queue_date, therapist_id, queue_position
  )
  select
    p_outlet_id,
    p_date,
    therapist.id,
    row_number() over (
      order by
        case when therapist.display_order >= v_starter_order then 0 else 1 end,
        therapist.display_order,
        therapist.name
    )::integer
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and exists (
      select 1
      from public.therapist_working_hours working_hours
      join public.business_hours outlet_hours
        on outlet_hours.outlet_id = therapist.outlet_id
       and outlet_hours.day_of_week = working_hours.day_of_week
       and not coalesce(outlet_hours.is_closed, false)
      where working_hours.therapist_id = therapist.id
        and working_hours.day_of_week = v_day_of_week
    );
end;
$$;


--
-- Name: recalculate_appointment_therapist_commission(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalculate_appointment_therapist_commission(p_appointment_id uuid) RETURNS numeric
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_appointment public.appointments%rowtype;
  v_primary_transaction public.transactions%rowtype;
  v_transaction public.transactions%rowtype;
  v_allocation record;
  v_amount numeric;
  v_total numeric := 0;
  v_group_incomplete boolean;
begin
  select * into v_appointment
  from public.appointments where id = p_appointment_id;
  if not found then return 0; end if;

  select * into v_primary_transaction
  from public.transactions t
  where t.payment_status = 'paid'
    and t.source::text <> 'appointment_addon'
    and (
      t.appointment_id = p_appointment_id
      or (
        v_appointment.appointment_group_id is not null
        and t.appointment_group_id = v_appointment.appointment_group_id
      )
    )
  order by t.created_at
  limit 1;
  if not found then return 0; end if;

  if not exists (
    select 1 from public.appointment_therapist_allocations
    where appointment_id = p_appointment_id
  ) then
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    ) values (
      p_appointment_id, v_appointment.therapist_id, 1, 'full', auth.uid()
    );
  end if;

  for v_allocation in
    select * from public.appointment_therapist_allocations
    where appointment_id = p_appointment_id
  loop
    v_amount := case
      when v_primary_transaction.source::text = 'online_booking'
        and v_appointment.status <> 'completed' then 0
      else round(
        public.csp_commission_for_items(
          coalesce(v_appointment.service_items, '[]'::jsonb),
          v_allocation.therapist_id,
          'Therapist'
        ) * v_allocation.commission_share,
        2
      )
    end;
    update public.appointment_therapist_allocations
    set commission_amount = v_amount
    where id = v_allocation.id;
  end loop;

  select coalesce(sum(ata.commission_amount), 0)
  into v_total
  from public.appointment_therapist_allocations ata
  where ata.appointment_id = p_appointment_id;

  for v_transaction in
    select * from public.transactions t
    where t.payment_status = 'paid'
      and (
        t.appointment_id = p_appointment_id
        or (
          v_appointment.appointment_group_id is not null
          and t.appointment_group_id = v_appointment.appointment_group_id
        )
      )
  loop
    v_group_incomplete := false;
    if v_transaction.source::text = 'online_booking' then
      if v_transaction.appointment_id is not null then
        select a.status <> 'completed' into v_group_incomplete
        from public.appointments a where a.id = v_transaction.appointment_id;
      elsif v_transaction.appointment_group_id is not null then
        select exists (
          select 1 from public.appointments a
          where a.appointment_group_id = v_transaction.appointment_group_id
            and a.status not in ('completed', 'cancelled', 'no_show')
        ) into v_group_incomplete;
      end if;
    end if;

    update public.transactions
    set therapist_commission_amount = case
          when v_group_incomplete then 0
          else public.csp_commission_for_transaction_items(
            v_transaction.service_items, v_transaction.therapist_id
          )
        end,
        updated_at = now()
    where id = v_transaction.id;
  end loop;

  return v_total;
end;
$$;


--
-- Name: reconcile_appointment_resources(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reconcile_appointment_resources(p_appointment_id uuid, p_confirm boolean DEFAULT false) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: FUNCTION reconcile_appointment_resources(p_appointment_id uuid, p_confirm boolean); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.reconcile_appointment_resources(p_appointment_id uuid, p_confirm boolean) IS 'Guarded assignment-unit wrapper around the migration-112 allocator; never consumes queue turns.';


--
-- Name: reconcile_appointment_resources_112_core(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reconcile_appointment_resources_112_core(p_appointment_id uuid, p_confirm boolean DEFAULT false) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: reconcile_upcoming_appointment_assignments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reconcile_upcoming_appointment_assignments() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: FUNCTION reconcile_upcoming_appointment_assignments(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.reconcile_upcoming_appointment_assignments() IS 'Non-overlapping capped 60-minute recovery worker with invalidation batching and retry backoff.';


--
-- Name: record_billplz_bill(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_billplz_bill(p_token uuid, p_bill_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_hold public.booking_holds%rowtype;
begin
  select * into v_hold from public.booking_holds where public_token = p_token for update;
  if not found then
    raise exception 'Booking reference not found';
  end if;
  if v_hold.status <> 'pending_payment' or v_hold.expires_at <= now() then
    raise exception 'This booking hold can no longer accept payment';
  end if;

  update public.booking_holds
  set billplz_bill_id = p_bill_id,
      updated_at = now()
  where id = v_hold.id;
end;
$$;


--
-- Name: record_billplz_group_bill(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_billplz_group_bill(p_token uuid, p_bill_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not exists (
    select 1 from public.booking_holds h
    where h.booking_group_token = p_token
      and h.status = 'pending_payment' and h.expires_at > now()
  ) then raise exception 'This booking hold can no longer accept payment'; end if;

  update public.booking_holds
  set billplz_bill_id = case when guest_index = 1 then p_bill_id else null end,
      updated_at = now()
  where booking_group_token = p_token;
end;
$$;


--
-- Name: record_online_booking_group_payment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_online_booking_group_payment(p_token uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_group_id uuid;
  v_first public.booking_holds%rowtype;
  v_customer public.customers%rowtype;
  v_service_price numeric := 0;
  v_sst numeric := 0;
  v_display_total numeric := 0;
  v_total numeric := 0;
  v_items jsonb;
  v_count integer;
  v_transaction_id uuid;
begin
  select * into v_first from public.booking_holds h
  where h.booking_group_token = p_token order by h.guest_index limit 1 for update;
  if not found or v_first.appointment_group_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  v_group_id := v_first.appointment_group_id;

  select sum(h.total_amount), count(*),
         jsonb_agg(
           coalesce(h.service_items -> 0, '{}'::jsonb)
           || jsonb_strip_nulls(jsonb_build_object(
             'id', a.service_id,
             'name', coalesce(nullif(a.service_name, ''),
               nullif(h.service_items -> 0 ->> 'public_name', ''), s.name, 'Service'),
             'appointmentId', h.appointment_id,
             'guestName', h.guest_name,
             'price', h.total_amount,
             'lineType', 'booked',
             'assignedTherapistId', a.therapist_id,
             'assignedTherapistName', therapist.name,
             'assignedRoomId', a.room_id,
             'assignedRoomName', room.name
           )) order by h.guest_index
         )
  into v_display_total, v_count, v_items
  from public.booking_holds h
  join public.appointments a on a.id = h.appointment_id
  left join public.services s on s.id = a.service_id
  left join public.therapists therapist on therapist.id = a.therapist_id
  left join public.rooms room on room.id = a.room_id
  where h.booking_group_token = p_token;

  select b.service_price, b.sst_amount, b.total_amount
  into v_service_price, v_sst, v_total
  from public.outlet_payment_breakdown(
    v_first.outlet_id, v_display_total, 'billplz'
  ) b;
  select * into v_customer from public.customers c where c.id = v_first.customer_id;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_name, service_items, item_count, service_price, sst_amount,
    total_amount, payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_first.outlet_id, v_group_id, v_first.customer_id,
    coalesce(v_customer.name, v_first.customer_name),
    coalesce(v_customer.phone, v_first.customer_phone),
    'Online group booking', v_items, v_count, v_service_price, v_sst, v_total,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_first.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_group_id)
    where appointment_group_id is not null
      and coalesce(source, '') <> 'appointment_addon'
  do update set payment_status = 'paid', service_name = excluded.service_name,
                service_items = excluded.service_items, item_count = excluded.item_count,
                service_price = excluded.service_price, sst_amount = excluded.sst_amount,
                total_amount = excluded.total_amount,
                receipt_number = excluded.receipt_number
  returning id into v_transaction_id;
  return v_transaction_id;
end;
$$;


--
-- Name: record_online_booking_payment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_online_booking_payment(p_token uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_hold public.booking_holds%rowtype;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_therapist_name text := '';
  v_room_name text := '';
  v_service_price numeric := 0;
  v_sst_amount numeric := 0;
  v_total_amount numeric := 0;
  v_transaction_id uuid;
begin
  select * into v_hold from public.booking_holds
  where public_token = p_token for update;
  if not found or v_hold.status <> 'confirmed' or v_hold.appointment_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  select * into v_appointment from public.appointments
  where id = v_hold.appointment_id;
  select * into v_customer from public.customers where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name from public.therapists
  where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name from public.rooms
  where id = v_appointment.room_id;
  select b.service_price, b.sst_amount, b.total_amount
  into v_service_price, v_sst_amount, v_total_amount
  from public.outlet_payment_breakdown(
    v_hold.outlet_id, v_hold.total_amount, 'billplz'
  ) b;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, room_id, room_name,
    service_price, sst_amount, total_amount,
    payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_hold.outlet_id, v_appointment.id, v_appointment.customer_id,
    coalesce(v_customer.name, v_hold.customer_name),
    coalesce(v_customer.phone, v_hold.customer_phone),
    v_appointment.service_id, v_appointment.service_name,
    v_appointment.service_items, v_appointment.item_count,
    v_appointment.therapist_id, v_therapist_name,
    v_appointment.room_id, v_room_name,
    v_service_price, v_sst_amount, v_total_amount,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_hold.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_id)
    where source = 'online_booking' and appointment_id is not null
  do update set payment_status = 'paid',
                service_price = excluded.service_price,
                sst_amount = excluded.sst_amount,
                total_amount = excluded.total_amount,
                receipt_number = excluded.receipt_number
  returning id into v_transaction_id;
  return v_transaction_id;
end;
$$;


--
-- Name: record_therapist_queue_turn_consumption(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_therapist_queue_turn_consumption() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_last_position integer;
begin
  if new.turn_consumed_at is null
     or old.turn_consumed_at is not distinct from new.turn_consumed_at then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(new.outlet_id::text || ':' || new.queue_date::text, 0)
  );

  select coalesce(max(queue_position), new.queue_position)
  into v_last_position
  from public.therapist_queue
  where outlet_id = new.outlet_id
    and queue_date = new.queue_date;

  update public.therapist_queue queue_row
  set queue_position = queue_row.queue_position - 1
  where queue_row.outlet_id = new.outlet_id
    and queue_row.queue_date = new.queue_date
    and queue_row.therapist_id <> new.therapist_id
    and queue_row.queue_position > old.queue_position;

  new.queue_position := v_last_position;

  update public.therapist_queue_day
  set first_turn_consumed_at = coalesce(
    first_turn_consumed_at,
    new.turn_consumed_at
  )
  where outlet_id = new.outlet_id
    and queue_date = new.queue_date;

  return new;
end;
$$;


--
-- Name: release_staff_walkin_draft(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.release_staff_walkin_draft(p_draft_session_id text, p_pax_index integer DEFAULT NULL::integer) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_updated integer;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  update public.booking_holds
  set status = 'cancelled', updated_at = now()
  where hold_kind = 'staff_walkin_draft'
    and draft_session_id = p_draft_session_id
    and status = 'pending_payment'
    and (p_pax_index is null or pax_index = p_pax_index);
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;


--
-- Name: reorder_current_therapist_queue(uuid, date, uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reorder_current_therapist_queue(p_outlet_id uuid, p_date date, p_therapist_ids uuid[]) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_now_time time := (now() at time zone 'Asia/Kuala_Lumpur')::time;
  v_expected_count integer;
  v_supplied_count integer := coalesce(cardinality(p_therapist_ids), 0);
  v_position_slots integer[];
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = '22023',
      message = 'Only today''s live queue can be reordered.';
  end if;
  if v_supplied_count = 0 then
    raise exception using errcode = '22023',
      message = 'Provide the current live therapist order.';
  end if;
  if (
    select count(distinct supplied.id)
    from unnest(p_therapist_ids) supplied(id)
  ) <> v_supplied_count then
    raise exception using errcode = '22023',
      message = 'Each live therapist must appear exactly once.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  select count(*)
  into v_expected_count
  from public.get_therapist_queue(
    p_outlet_id, p_date, v_now_time, 1
  );

  if v_expected_count <> v_supplied_count
     or exists (
       select 1
       from unnest(p_therapist_ids) supplied(id)
       where not exists (
         select 1
         from public.get_therapist_queue(
           p_outlet_id, p_date, v_now_time, 1
         ) live_queue
         where live_queue.therapist_id = supplied.id
       )
     ) then
    raise exception using errcode = '22023',
      message = 'The live queue changed. Refresh it before saving the new order.';
  end if;

  perform 1
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
  order by queue_row.queue_position, queue_row.therapist_id
  for update;

  select array_agg(queue_row.queue_position order by queue_row.queue_position)
  into v_position_slots
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
    and queue_row.therapist_id = any(p_therapist_ids);

  update public.therapist_queue queue_row
  set queue_position = -100000 - supplied.ordinality::integer,
      protected_turn_owed = false,
      protected_turn_reason = null
  from unnest(p_therapist_ids) with ordinality supplied(id, ordinality)
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
    and queue_row.therapist_id = supplied.id;

  update public.therapist_queue queue_row
  set queue_position = requested.queue_position
  from unnest(p_therapist_ids, v_position_slots)
    requested(id, queue_position)
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
    and queue_row.therapist_id = requested.id;
end;
$$;


--
-- Name: reorder_staff_display_order(uuid, uuid[], integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reorder_staff_display_order(p_outlet_id uuid, p_staff_ids uuid[], p_display_orders integer[]) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_role text;
  v_expected_count integer;
  v_supplied_count integer := coalesce(cardinality(p_staff_ids), 0);
  v_temp_base integer;
begin
  if v_supplied_count = 0
     or cardinality(p_display_orders) is distinct from v_supplied_count then
    raise exception using
      errcode = '22023',
      message = 'Staff IDs and display orders must be non-empty arrays of equal length.';
  end if;

  if exists (
    select 1
    from unnest(p_display_orders) requested(display_order)
    where requested.display_order < 0
  ) or (
    select count(distinct requested.display_order)
    from unnest(p_display_orders) requested(display_order)
  ) <> v_supplied_count then
    raise exception using
      errcode = '22023',
      message = 'Display orders must be unique non-negative integers.';
  end if;

  select lower(therapist.role)
  into v_role
  from public.therapists therapist
  where therapist.id = p_staff_ids[1]
    and therapist.outlet_id = p_outlet_id;

  if v_role is null then
    raise exception using
      errcode = '22023',
      message = 'The selected staff do not belong to this outlet.';
  end if;

  select count(*)
  into v_expected_count
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and lower(therapist.role) = v_role;

  if v_expected_count <> v_supplied_count
     or exists (
       select 1
       from unnest(p_staff_ids) requested(id)
       left join public.therapists therapist
         on therapist.id = requested.id
        and therapist.outlet_id = p_outlet_id
        and lower(therapist.role) = v_role
       where therapist.id is null
     )
     or (
       select count(distinct requested.id)
       from unnest(p_staff_ids) requested(id)
     ) <> v_supplied_count then
    raise exception using
      errcode = '22023',
      message = 'Reordering requires every staff member of one outlet role exactly once.';
  end if;

  select coalesce(min(therapist.display_order), 0) - v_supplied_count - 1000
  into v_temp_base
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and lower(therapist.role) = v_role;

  update public.therapists therapist
  set display_order = v_temp_base - requested.ordinality::integer
  from unnest(p_staff_ids) with ordinality requested(id, ordinality)
  where therapist.id = requested.id
    and therapist.outlet_id = p_outlet_id;

  update public.therapists therapist
  set display_order = requested.display_order
  from unnest(p_staff_ids, p_display_orders)
    requested(id, display_order)
  where therapist.id = requested.id
    and therapist.outlet_id = p_outlet_id;
end;
$$;


--
-- Name: request_appointment_assignment_reconcile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.request_appointment_assignment_reconcile() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: reserve_staff_walkin_allocation(text, integer, uuid, uuid, text, text, uuid, uuid, jsonb, date, time without time zone, time without time zone, numeric, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserve_staff_walkin_allocation(p_draft_session_id text, p_pax_index integer, p_outlet_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_therapist_id uuid, p_room_id uuid, p_service_items jsonb, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_amount numeric, p_room_unit_id uuid) RETURNS TABLE(success boolean, hold_id uuid, error_code text, error_message text, expires_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_check record;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_buffer_after_minutes integer;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if coalesce(trim(p_draft_session_id), '') = '' or p_pax_index < 0 then
    success := false; hold_id := null; error_code := 'INVALID_DRAFT';
    error_message := 'Draft session and pax index are required.'; expires_at := null;
    return next; return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_therapist_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('room:' || p_room_id::text, 0));
  perform set_config('app.ignore_cleanup_buffer', 'on', true);

  update public.booking_holds set status = 'expired', updated_at = now()
  where hold_kind = 'staff_walkin_draft' and status = 'pending_payment'
    and booking_holds.expires_at <= now();
  update public.booking_holds set status = 'cancelled', updated_at = now()
  where hold_kind = 'staff_walkin_draft'
    and draft_session_id = p_draft_session_id and pax_index = p_pax_index
    and status = 'pending_payment';

  select * into v_check from public.check_booking_availability(
    p_date, p_start_time, p_end_time, p_therapist_id, p_room_id
  );
  if not coalesce(v_check.therapist_available, false) then
    success := false; hold_id := null; error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Therapist is already reserved at that time.'; expires_at := null;
    return next; return;
  end if;
  if coalesce(v_check.room_full, false) then
    success := false; hold_id := null; error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full at that time.'; expires_at := null;
    return next; return;
  end if;

  v_start_at := (p_date + p_start_time) at time zone 'Asia/Kuala_Lumpur';
  v_end_at := (p_date + p_end_time) at time zone 'Asia/Kuala_Lumpur';
  select coalesce(max(
    case
      when item->>'bufferAfterMinutes' ~ '^[0-9]+$'
        then (item->>'bufferAfterMinutes')::integer
      else 0
    end
  ), 0)
  into v_buffer_after_minutes
  from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb)) item;

  begin
    insert into public.booking_holds (
      outlet_id, customer_id, customer_name, customer_phone, customer_email,
      assigned_therapist_id, assigned_room_id, assigned_room_unit_id,
      service_items, start_at, end_at, buffer_after_minutes,
      total_amount, status, expires_at, notes,
      hold_kind, draft_session_id, pax_index
    ) values (
      p_outlet_id, p_customer_id, coalesce(p_customer_name, 'Guest'),
      coalesce(p_customer_phone, ''), '', p_therapist_id, p_room_id,
      p_room_unit_id, coalesce(p_service_items, '[]'::jsonb), v_start_at,
      v_end_at, v_buffer_after_minutes,
      greatest(coalesce(p_total_amount, 0), 0), 'pending_payment',
      now() + interval '10 minutes', 'Staff walk-in draft',
      'staff_walkin_draft', p_draft_session_id, p_pax_index
    ) returning id, booking_holds.expires_at into hold_id, expires_at;
  exception when raise_exception then
    success := false; hold_id := null; error_code := 'ROOM_UNIT_UNAVAILABLE';
    error_message := sqlerrm; expires_at := null;
    return next; return;
  end;

  success := true; error_code := null; error_message := null;
  return next;
end;
$_$;


--
-- Name: reset_today_queue_to_automatic(uuid, date, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reset_today_queue_to_automatic(p_outlet_id uuid, p_date date, p_reason text DEFAULT NULL::text, p_confirm_reset boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_starter_id uuid;
  v_first_turn timestamptz;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = '22023',
      message = 'Only today''s live queue can be reset.';
  end if;
  if char_length(coalesce(p_reason, '')) > 500 then
    raise exception using errcode = '22023',
      message = 'Reason must be 500 characters or fewer.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  v_first_turn := public.today_queue_has_started(p_outlet_id, p_date);
  if v_first_turn is not null and not p_confirm_reset then
    raise exception using errcode = 'P0001',
      message = 'RESET_CONFIRMATION_REQUIRED';
  end if;

  v_starter_id := public.automatic_therapist_queue_starter(
    p_outlet_id, p_date
  );
  if v_starter_id is null then
    raise exception using errcode = '22023',
      message = 'No active therapist is scheduled for this outlet today.';
  end if;

  update public.therapist_queue_day
  set starter_therapist_id = v_starter_id,
      is_manual_override = false,
      changed_by = auth.uid(),
      changed_at = now(),
      override_reason = nullif(btrim(p_reason), '')
  where outlet_id = p_outlet_id and queue_date = p_date;

  perform public.rebuild_therapist_queue_from_starter(
    p_outlet_id, p_date, v_starter_id
  );
end;
$$;


--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


--
-- Name: seed_default_therapist_working_hours(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seed_default_therapist_working_hours() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into public.therapist_working_hours (
    outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
  )
  select new.outlet_id,
         new.id,
         hours.day_of_week,
         hours.open_time,
         hours.close_time,
         false
  from public.business_hours hours
  where hours.outlet_id = new.outlet_id
    and not hours.is_closed
  on conflict (therapist_id, day_of_week, start_time) do nothing;

  return new;
end;
$$;


--
-- Name: seed_therapist_queue(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seed_therapist_queue(p_outlet_id uuid, p_date date) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_starter_id uuid;
  v_max_position integer;
begin
  if p_outlet_id is null or p_date is null then
    return;
  end if;

  -- All seed, consume and manual-reorder paths use this same outlet/day lock.
  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );

  select day_state.starter_therapist_id
  into v_starter_id
  from public.therapist_queue_day day_state
  where day_state.outlet_id = p_outlet_id
    and day_state.queue_date = p_date;

  -- Preserve historical queue rows if day metadata is ever missing. Position
  -- one is the least surprising recovered starter and no live state is reset.
  if v_starter_id is null and exists (
    select 1
    from public.therapist_queue queue_row
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
  ) then
    select queue_row.therapist_id
    into v_starter_id
    from public.therapist_queue queue_row
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
    order by queue_row.queue_position, queue_row.therapist_id
    limit 1;

    insert into public.therapist_queue_day (
      outlet_id,
      queue_date,
      starter_therapist_id
    ) values (
      p_outlet_id,
      p_date,
      v_starter_id
    )
    on conflict (outlet_id, queue_date) do nothing;
  end if;

  -- A genuinely new day still uses the established starter/rebuild behavior.
  if not exists (
    select 1
    from public.therapist_queue queue_row
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
  ) then
    if v_starter_id is null then
      v_starter_id := public.automatic_therapist_queue_starter(
        p_outlet_id,
        p_date
      );
      if v_starter_id is null then
        return;
      end if;

      insert into public.therapist_queue_day (
        outlet_id,
        queue_date,
        starter_therapist_id
      ) values (
        p_outlet_id,
        p_date,
        v_starter_id
      )
      on conflict (outlet_id, queue_date) do update
      set starter_therapist_id = excluded.starter_therapist_id;
    end if;

    begin
      perform public.rebuild_therapist_queue_from_starter(
        p_outlet_id,
        p_date,
        v_starter_id
      );
    exception
      when sqlstate '22023' then
        v_starter_id := public.automatic_therapist_queue_starter(
          p_outlet_id,
          p_date
        );
        if v_starter_id is null then
          return;
        end if;
        update public.therapist_queue_day
        set starter_therapist_id = v_starter_id
        where outlet_id = p_outlet_id
          and queue_date = p_date;
        perform public.rebuild_therapist_queue_from_starter(
          p_outlet_id,
          p_date,
          v_starter_id
        );
    end;
    return;
  end if;

  select coalesce(max(queue_row.queue_position), 0)
  into v_max_position
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date;

  -- Mid-day joiners append after the current effective order. Existing queue
  -- rows are never updated, so consumed timestamps and staff reorders survive.
  with missing as (
    select
      therapist.id,
      row_number() over (
        order by
          therapist.display_order nulls last,
          therapist.name,
          therapist.id
      )::integer as append_offset
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and exists (
        select 1
        from public.therapist_working_hours working_hours
        join public.business_hours outlet_hours
          on outlet_hours.outlet_id = therapist.outlet_id
         and outlet_hours.day_of_week = working_hours.day_of_week
         and not coalesce(outlet_hours.is_closed, false)
        where working_hours.therapist_id = therapist.id
          and working_hours.day_of_week =
              extract(dow from p_date)::integer
      )
      and not exists (
        select 1
        from public.therapist_queue existing
        where existing.outlet_id = p_outlet_id
          and existing.queue_date = p_date
          and existing.therapist_id = therapist.id
      )
  )
  insert into public.therapist_queue (
    outlet_id,
    queue_date,
    therapist_id,
    queue_position
  )
  select
    p_outlet_id,
    p_date,
    missing.id,
    v_max_position + missing.append_offset
  from missing
  order by missing.append_offset
  on conflict (outlet_id, queue_date, therapist_id) do nothing;
end;
$$;


--
-- Name: FUNCTION seed_therapist_queue(p_outlet_id uuid, p_date date); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.seed_therapist_queue(p_outlet_id uuid, p_date date) IS 'Seeds a new daily queue or appends newly active scheduled therapists to the tail without resetting live rotation.';


--
-- Name: set_appointment_assignment_metadata(uuid, text, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_appointment_assignment_metadata(p_appointment_id uuid, p_assignment_source text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text, p_is_provisional boolean DEFAULT NULL::boolean) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_updated public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_assignment_source not in (
    'queue', 'gender_preference', 'specific_customer_request', 'manual_override'
  ) then
    raise exception 'Invalid assignment_source: %', p_assignment_source;
  end if;

  update public.appointments
  set assignment_source = p_assignment_source,
      requested_therapist_id = p_requested_therapist_id,
      requested_gender = p_requested_gender,
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  return v_updated;
end;
$$;


--
-- Name: set_appointment_booked_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_appointment_booked_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.appointment_date is null
     or new.start_time is null
     or new.end_time is null then
    return new;
  end if;

  new.booked_date := coalesce(new.booked_date, new.appointment_date);
  new.booked_start_time := coalesce(new.booked_start_time, new.start_time);
  new.booked_end_time := coalesce(new.booked_end_time, new.end_time);
  new.booked_start_at := coalesce(
    new.booked_start_at,
    public.csp_start_at(new.booked_date, new.booked_start_time)
      at time zone 'Asia/Kuala_Lumpur'
  );
  new.booked_end_at := coalesce(
    new.booked_end_at,
    public.csp_end_at(new.booked_date, new.booked_start_time, new.booked_end_time)
      at time zone 'Asia/Kuala_Lumpur'
  );

  return new;
end;
$$;


--
-- Name: set_appointment_schedule_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_appointment_schedule_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  new.start_at := public.csp_start_at(new.appointment_date::date, new.start_time::time);
  new.end_at := public.csp_end_at(new.appointment_date::date, new.start_time::time, new.end_time::time);
  return new;
end;
$$;


--
-- Name: set_audit_fields(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_audit_fields() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' then
    new.created_at = coalesce(new.created_at, now());
    new.created_by = coalesce(new.created_by, auth.uid());
  end if;

  new.updated_at = now();
  new.updated_by = auth.uid();

  return new;
end;
$$;


--
-- Name: set_completed_therapist_allocations(uuid, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_completed_therapist_allocations(p_appointment_id uuid, p_allocations jsonb, p_reason text) RETURNS TABLE(success boolean, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_total numeric;
  v_item jsonb;
  v_therapist_id uuid;
  v_share numeric;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin permission required';
  end if;
  if not exists (
    select 1 from public.appointments
    where id = p_appointment_id and status = 'completed'
  ) then
    success := false; error_code := 'NOT_COMPLETED';
    error_message := 'Only completed services can be corrected in history.';
    return next; return;
  end if;
  if jsonb_typeof(p_allocations) is distinct from 'array'
    or jsonb_array_length(p_allocations) = 0 then
    success := false; error_code := 'INVALID_ALLOCATIONS';
    error_message := 'At least one therapist allocation is required.';
    return next; return;
  end if;

  select coalesce(sum((value ->> 'commission_share')::numeric), 0)
  into v_total from jsonb_array_elements(p_allocations);
  if abs(v_total - 1) > 0.0001 then
    success := false; error_code := 'INVALID_TOTAL';
    error_message := 'Commission shares must total 100%.';
    return next; return;
  end if;
  if (
    select count(*) <> count(distinct value ->> 'therapist_id')
    from jsonb_array_elements(p_allocations)
  ) then
    success := false; error_code := 'DUPLICATE_THERAPIST';
    error_message := 'Each therapist can appear only once.';
    return next; return;
  end if;

  delete from public.appointment_therapist_allocations
  where appointment_id = p_appointment_id;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_item ->> 'therapist_id')::uuid;
    v_share := (v_item ->> 'commission_share')::numeric;
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method,
      reason, created_by
    ) values (
      p_appointment_id, v_therapist_id, v_share, 'manual',
      coalesce(trim(p_reason), ''), auth.uid()
    );
  end loop;

  perform public.recalculate_appointment_therapist_commission(p_appointment_id);
  success := true; error_code := null; error_message := null;
  return next;
end;
$$;


--
-- Name: start_appointment_group_service(uuid, timestamp with time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_appointment_group_service(p_group_id uuid, p_started_at timestamp with time zone DEFAULT now(), p_allow_late_extension_overlap boolean DEFAULT false) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], started_count integer, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_g public.appointment_groups%rowtype; v_a public.appointments%rowtype;
  v_ids uuid[] := array[]::uuid[]; v_id uuid; v_n int := 0;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_g from public.appointment_groups where id = p_group_id for update;
  if not found then
    return query select false, p_group_id, v_ids, 0, 'NOT_FOUND','Group was not found.'; return;
  end if;

  -- Lock and validate EVERY pax before starting any of them, so a rejection
  -- leaves the whole group unstarted.
  for v_id in select a.id from public.appointments a
              where a.appointment_group_id = p_group_id order by a.id
  loop
    select * into v_a from public.appointments where id = v_id for update;
    v_ids := array_append(v_ids, v_id);
    if v_a.actual_started_at is not null then continue; end if;
    if v_a.status::text not in ('pending','confirmed') then
      return query select false, p_group_id, v_ids, 0, 'NOT_STARTABLE',
        format('Pax %s is not startable.', v_id); return;
    end if;
    if v_a.payment_status::text <> 'paid' then
      return query select false, p_group_id, v_ids, 0, 'NOT_PAID',
        format('Pax %s is not paid.', v_id); return;
    end if;
    if v_a.appointment_date <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
      return query select false, p_group_id, v_ids, 0, 'WRONG_DATE',
        format('Pax %s is not scheduled for today.', v_id); return;
    end if;
  end loop;

  if array_length(v_ids,1) is null then
    return query select false, p_group_id, v_ids, 0, 'EMPTY_GROUP','The group has no pax.'; return;
  end if;

  -- All validated: start each. Already-started pax are skipped, so a retry
  -- neither restamps nor re-consumes a queue turn.
  foreach v_id in array v_ids loop
    select * into v_a from public.appointments where id = v_id;
    if v_a.actual_started_at is null then
      perform public.start_appointment_service(
        v_id, p_started_at, null, p_allow_late_extension_overlap);
      v_n := v_n + 1;
    end if;
  end loop;

  update public.appointment_groups set status = 'in_progress'
  where id = p_group_id and coalesce(status,'') is distinct from 'in_progress';

  return query select true, p_group_id, v_ids, v_n, null::text, null::text;
end;
$$;


--
-- Name: start_appointment_group_service(uuid, uuid[], timestamp with time zone, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_appointment_group_service(p_appointment_group_id uuid, p_appointment_ids uuid[], p_started_at timestamp with time zone DEFAULT now(), p_expected_end_by_appointment jsonb DEFAULT '{}'::jsonb, p_allow_overlap_by_appointment jsonb DEFAULT '{}'::jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_id uuid;
  v_count integer;
  v_expected_end timestamptz;
  v_allow_overlap boolean;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_appointment_ids is null or cardinality(p_appointment_ids) = 0 then
    raise exception 'No appointments were supplied.';
  end if;

  select count(*)::integer into v_count
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;
  if cardinality(p_appointment_ids) <> v_count
      or cardinality(p_appointment_ids) <> (
        select count(distinct supplied.id)::integer
        from unnest(p_appointment_ids) supplied(id)
      ) then
    raise exception 'The complete appointment group is required.';
  end if;

  foreach v_id in array p_appointment_ids loop
    if not exists (
      select 1 from public.appointments a
      where a.id = v_id and a.appointment_group_id = p_appointment_group_id
    ) then
      raise exception 'Appointment does not belong to this group: %', v_id;
    end if;
    v_expected_end := nullif(
      p_expected_end_by_appointment ->> v_id::text,
      ''
    )::timestamptz;
    v_allow_overlap := coalesce(
      (p_allow_overlap_by_appointment ->> v_id::text)::boolean,
      false
    );
    perform public.start_appointment_service(
      v_id,
      p_started_at,
      v_expected_end,
      v_allow_overlap
    );
  end loop;
  return cardinality(p_appointment_ids);
end;
$$;


--
-- Name: start_appointment_service(uuid, timestamp with time zone, timestamp with time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_appointment_service(p_appointment_id uuid, p_started_at timestamp with time zone DEFAULT now(), p_expected_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_allow_late_extension_overlap boolean DEFAULT false) RETURNS public.appointments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_a public.appointments%rowtype; v_dur interval; v_addon int;
  v_expected timestamptz; v_upd public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'Appointment was not found.'; end if;

  -- Idempotent: a retry returns the started row unchanged. Because
  -- actual_started_at is not rewritten, consume_queue_on_appointment_start
  -- (which fires only on the NULL -> NOT NULL transition) cannot run twice.
  if v_a.actual_started_at is not null then return v_a; end if;

  if v_a.appointment_date <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service can only be started on its appointment date.';
  end if;
  if v_a.status::text not in ('pending','confirmed') then
    raise exception 'Only a pending or confirmed service can be started.';
  end if;
  if v_a.payment_status::text <> 'paid' then
    raise exception 'Payment must be confirmed before starting this service.';
  end if;

  -- Assigns therapist / room / room_unit and confirms them.
  v_a := public.reconcile_appointment_resources(p_appointment_id, true);

  v_dur := coalesce(
    v_a.booked_end_at - v_a.booked_start_at,
    public.csp_end_at(coalesce(v_a.booked_date, v_a.appointment_date),
                      coalesce(v_a.booked_start_time, v_a.start_time),
                      coalesce(v_a.booked_end_time, v_a.end_time))
    - public.csp_start_at(coalesce(v_a.booked_date, v_a.appointment_date),
                          coalesce(v_a.booked_start_time, v_a.start_time)),
    v_a.end_at - v_a.start_at);
  if v_dur is null or v_dur <= interval '0 seconds' then
    raise exception 'Service duration must be greater than zero.';
  end if;

  -- Add-ons paid at check-in lengthen the service; check-in deliberately did
  -- not move the window, so their duration is applied here.
  v_addon := public.appointment_addon_minutes(p_appointment_id);
  v_expected := coalesce(
    p_expected_end_at,
    p_started_at + v_dur + make_interval(mins => coalesce(v_addon, 0)));
  if v_expected <= p_started_at then
    raise exception 'Expected end time must be after the actual start time.';
  end if;

  perform set_config('app.allow_late_extension_overlap',
    case when p_allow_late_extension_overlap then 'on' else 'off' end, true);

  update public.appointments
  set booked_date = coalesce(booked_date, appointment_date),
      booked_start_time = coalesce(booked_start_time, start_time),
      booked_end_time = coalesce(booked_end_time, end_time),
      booked_start_at = coalesce(booked_start_at,
        public.csp_start_at(appointment_date, start_time) at time zone 'Asia/Kuala_Lumpur'),
      booked_end_at = coalesce(booked_end_at,
        public.csp_end_at(appointment_date, start_time, end_time) at time zone 'Asia/Kuala_Lumpur'),
      therapist_assignment_state = 'confirmed',
      room_assignment_state = 'confirmed',
      resources_confirmed_at = now(),
      resources_confirmed_by = auth.uid(),
      -- A walk-in that starts immediately gets both stamps at the same instant.
      checked_in_at = coalesce(checked_in_at, p_started_at),
      checked_in_by = coalesce(checked_in_by, auth.uid()),
      status = 'in_progress',
      actual_started_at = p_started_at,
      end_at = (v_expected at time zone 'Asia/Kuala_Lumpur'),
      updated_at = now()
  where id = p_appointment_id
  returning * into v_upd;

  return v_upd;
end;
$$;


--
-- Name: switch_appointment_therapist(uuid, uuid, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.switch_appointment_therapist(p_appointment_id uuid, p_new_therapist_id uuid, p_split_method text DEFAULT 'service_time'::text, p_reason text DEFAULT ''::text, p_assignment_source text DEFAULT NULL::text, p_requested_gender text DEFAULT NULL::text, p_keep_provisional boolean DEFAULT false) RETURNS TABLE(success boolean, commission_method text, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_a public.appointments%rowtype; v_outlet uuid;
  v_win_start timestamp; v_win_end timestamp;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_a from public.appointments where id = p_appointment_id for update;
  if not found then
    return query select false, null::text, 'NOT_FOUND','Appointment was not found.'; return;
  end if;
  if p_new_therapist_id is null then
    return query select false, null::text, 'THERAPIST_REQUIRED',
      'Choose the replacement therapist.'; return;
  end if;

  v_outlet := v_a.outlet_id;

  if not exists (select 1 from public.therapists t
                 where t.id = p_new_therapist_id and t.outlet_id = v_outlet
                   and coalesce(t.availability_status,true)
                   and lower(coalesce(t.role,'therapist'))='therapist') then
    return query select false, null::text, 'INVALID_THERAPIST',
      'The replacement therapist is not active in this outlet.'; return;
  end if;

  -- Window the replacement must cover. For an in-progress service that is from
  -- NOW to the operational end; otherwise the whole scheduled window.
  v_win_start := greatest(public.csp_appointment_start_at(v_a),
                          case when v_a.actual_started_at is not null
                               then now() at time zone 'Asia/Kuala_Lumpur' end);
  v_win_start := coalesce(v_win_start, public.csp_appointment_start_at(v_a));
  v_win_end := public.csp_appointment_block_end_at(v_a);

  if exists (
    select 1 from public.appointments o
    where o.therapist_id = p_new_therapist_id
      and o.id is distinct from p_appointment_id
      and o.actual_started_at is not null
      and o.actual_completed_at is null
      and o.status::text = 'in_progress') then
    return query select false, null::text, 'THERAPIST_BUSY',
      'That therapist is currently mid-service on another appointment.'; return;
  end if;

  if exists (
    select 1 from public.appointments o
    where o.therapist_id = p_new_therapist_id
      and o.id is distinct from p_appointment_id
      and public.csp_blocks_schedule(o.status::text)
      and public.csp_appointment_start_at(o) < v_win_end
      and public.csp_appointment_block_end_at(o) > v_win_start) then
    return query select false, null::text, 'THERAPIST_UNAVAILABLE',
      'That therapist has an overlapping appointment.'; return;
  end if;

  if not exists (
    select 1 from public.therapist_working_hours wh
    where wh.therapist_id = p_new_therapist_id
      and ((wh.day_of_week = extract(dow from v_win_start::date)::int
            and v_win_start::date + wh.start_time <= v_win_start
            and v_win_start::date + wh.end_time
                + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
                > v_win_start)
        or (wh.end_time <= wh.start_time
            and wh.day_of_week = extract(dow from v_win_start::date - 1)::int
            and (v_win_start::date - 1) + wh.start_time <= v_win_start
            and (v_win_start::date - 1) + wh.end_time + interval '1 day' > v_win_start))) then
    return query select false, null::text, 'OUTSIDE_WORKING_HOURS',
      'That therapist is not rostered for this time.'; return;
  end if;

  return query select * from public.switch_appointment_therapist_core(
    p_appointment_id, p_new_therapist_id, p_split_method, p_reason,
    p_assignment_source, p_requested_gender, p_keep_provisional);
end;
$$;


--
-- Name: switch_appointment_therapist_core(uuid, uuid, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.switch_appointment_therapist_core(p_appointment_id uuid, p_new_therapist_id uuid, p_split_method text DEFAULT 'service_time'::text, p_reason text DEFAULT ''::text, p_assignment_source text DEFAULT NULL::text, p_requested_gender text DEFAULT NULL::text, p_keep_provisional boolean DEFAULT false) RETURNS TABLE(success boolean, commission_method text, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_appointment public.appointments%rowtype;
  v_old_therapist_id uuid;
  v_switch_at timestamptz := now();
  v_expected_end timestamptz;
  v_check record;
  v_early boolean;
  v_total_seconds numeric;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_split_method not in ('service_time', 'half') then
    success := false; commission_method := null; error_code := 'INVALID_SPLIT_METHOD';
    error_message := 'Choose service_time or half.'; return next; return;
  end if;
  if p_assignment_source is not null and p_assignment_source not in (
    'queue', 'gender_preference', 'specific_customer_request', 'manual_override'
  ) then
    success := false; commission_method := null; error_code := 'INVALID_ASSIGNMENT_SOURCE';
    error_message := 'Invalid assignment_source.'; return next; return;
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;
  if not found then
    success := false; commission_method := null; error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.'; return next; return;
  end if;
  if v_appointment.status in ('cancelled', 'no_show') then
    success := false; commission_method := null; error_code := 'INVALID_STATUS';
    error_message := 'Cancelled and no-show appointments cannot change therapist.'; return next; return;
  end if;
  if v_appointment.status = 'completed' then
    success := false; commission_method := null; error_code := 'USE_HISTORY_CORRECTION';
    error_message := 'Use the completed-service commission editor.'; return next; return;
  end if;

  v_old_therapist_id := v_appointment.therapist_id;
  if v_old_therapist_id = p_new_therapist_id then
    success := false; commission_method := null; error_code := 'SAME_THERAPIST';
    error_message := 'This therapist is already assigned.'; return next; return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(least(v_old_therapist_id::text, p_new_therapist_id::text), 0));
  perform pg_advisory_xact_lock(hashtextextended(greatest(v_old_therapist_id::text, p_new_therapist_id::text), 0));

  v_expected_end := coalesce(
    v_appointment.end_at at time zone 'Asia/Kuala_Lumpur',
    (v_appointment.appointment_date + v_appointment.end_time) at time zone 'Asia/Kuala_Lumpur'
  );

  if v_expected_end > v_switch_at then
    select * into v_check
    from public.check_booking_availability(
      v_appointment.appointment_date,
      (greatest(v_switch_at, (v_appointment.appointment_date + v_appointment.start_time) at time zone 'Asia/Kuala_Lumpur')
        at time zone 'Asia/Kuala_Lumpur')::time,
      (v_expected_end at time zone 'Asia/Kuala_Lumpur')::time,
      p_new_therapist_id,
      v_appointment.room_id,
      v_appointment.id
    );
    if not coalesce(v_check.therapist_available, false) then
      success := false; commission_method := null; error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'Replacement therapist has another overlapping appointment.'; return next; return;
    end if;
  end if;

  v_early := v_appointment.actual_started_at is null
    or v_switch_at <= v_appointment.actual_started_at + interval '15 minutes';

  perform set_config('app.therapist_switch_rpc', '1', true);
  update public.appointments
  set therapist_id = p_new_therapist_id,
      assignment_source = coalesce(p_assignment_source, assignment_source),
      requested_therapist_id = case
        when p_assignment_source = 'specific_customer_request' then p_new_therapist_id
        when p_assignment_source is not null then null
        else requested_therapist_id
      end,
      requested_gender = case
        when p_assignment_source is not null then p_requested_gender
        else requested_gender
      end,
      service_items = coalesce((
        select jsonb_agg(
          item || jsonb_build_object(
            'assignedTherapistId', p_new_therapist_id,
            'assignedTherapistName', coalesce(t.name, '')
          )
        )
        from jsonb_array_elements(coalesce(v_appointment.service_items, '[]'::jsonb)) item
        cross join public.therapists t
        where t.id = p_new_therapist_id
      ), v_appointment.service_items),
      updated_at = now()
  where id = p_appointment_id;

  if v_appointment.actual_started_at is null then
    delete from public.appointment_therapist_allocations where appointment_id = p_appointment_id;
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
    ) values (p_appointment_id, p_new_therapist_id, 1, 'early_replacement', p_reason, auth.uid());
    commission_method := 'early_replacement';
  else
    update public.appointment_therapist_segments
    set ended_at = v_switch_at
    where appointment_id = p_appointment_id and ended_at is null;
    insert into public.appointment_therapist_segments (
      appointment_id, therapist_id, started_at, change_type, reason, created_by
    ) values (
      p_appointment_id, p_new_therapist_id, v_switch_at,
      case when v_early then 'early_replacement' else 'mid_service_switch' end,
      p_reason, auth.uid()
    );

    delete from public.appointment_therapist_allocations where appointment_id = p_appointment_id;
    if v_early then
      insert into public.appointment_therapist_allocations (
        appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
      ) values (p_appointment_id, p_new_therapist_id, 1, 'early_replacement', p_reason, auth.uid());
      commission_method := 'early_replacement';
    elsif p_split_method = 'half' then
      if (
        select count(distinct therapist_id)
        from public.appointment_therapist_segments
        where appointment_id = p_appointment_id
      ) > 2 then
        raise exception '50/50 is only available when two therapists participated; use service-time split.';
      end if;
      insert into public.appointment_therapist_allocations (
        appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
      ) values
        (p_appointment_id, v_old_therapist_id, 0.5, 'half', p_reason, auth.uid()),
        (p_appointment_id, p_new_therapist_id, 0.5, 'half', p_reason, auth.uid());
      commission_method := 'half';
    else
      select greatest(extract(epoch from (v_expected_end - v_appointment.actual_started_at)), 1)
      into v_total_seconds;
      insert into public.appointment_therapist_allocations (
        appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
      )
      select
        p_appointment_id,
        s.therapist_id,
        least(1, greatest(0, sum(extract(epoch from (coalesce(s.ended_at, v_expected_end) - s.started_at))) / v_total_seconds)),
        'service_time',
        p_reason,
        auth.uid()
      from public.appointment_therapist_segments s
      where s.appointment_id = p_appointment_id
      group by s.therapist_id;
      commission_method := 'service_time';
    end if;
  end if;

  update public.transactions t
  set therapist_id = p_new_therapist_id,
      therapist_name = (select name from public.therapists where id = p_new_therapist_id),
      updated_at = now()
  where t.appointment_id = p_appointment_id;

  perform public.recalculate_appointment_therapist_commission(p_appointment_id);
  success := true; error_code := null; error_message := null;
  return next;
end;
$$;


--
-- Name: sync_appointment_group_outlet(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_appointment_group_outlet() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_group_outlet_id uuid;
begin
  if new.appointment_group_id is null then return new; end if;

  select g.outlet_id into v_group_outlet_id
  from public.appointment_groups g
  where g.id = new.appointment_group_id
  for update;

  if v_group_outlet_id is null then
    update public.appointment_groups
    set outlet_id = new.outlet_id
    where id = new.appointment_group_id;
  elsif v_group_outlet_id <> new.outlet_id then
    raise exception 'Appointment group belongs to a different outlet';
  end if;
  return new;
end;
$$;


--
-- Name: sync_appointment_payment_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_appointment_payment_status() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  -- An add-on receipt is supplementary. Voiding it must not void the original
  -- booking or alter the appointment's primary paid/unpaid state.
  if new.source = 'appointment_addon' then
    return new;
  end if;

  if new.appointment_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where id = new.appointment_id
      and payment_status is distinct from new.payment_status;
  end if;

  if new.appointment_group_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where appointment_group_id = new.appointment_group_id
      and payment_status is distinct from new.payment_status;
  end if;

  return new;
end;
$$;


--
-- Name: sync_business_settings_envelope(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_business_settings_envelope(p_outlet uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_open time;
  v_close_minutes integer;
begin
  select min(open_time),
         max(
           (extract(epoch from close_time) / 60)::integer
           + case when close_time <= open_time then 1440 else 0 end
         )
  into v_open, v_close_minutes
  from public.business_hours
  where outlet_id = p_outlet
    and not is_closed;

  if v_open is null then
    return;
  end if;

  update public.business_settings
  set open_time = v_open,
      close_time = (
        time '00:00' + make_interval(mins => v_close_minutes % 1440)
      )::time
  where outlet_id = p_outlet;
end;
$$;


--
-- Name: sync_completed_appointment_commission(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_completed_appointment_commission() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status = 'completed'
      and old.status is distinct from new.status then
    perform public.recalculate_appointment_therapist_commission(new.id);
  end if;
  return new;
end;
$$;


--
-- Name: sync_inherited_staff_business_hours(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_inherited_staff_business_hours() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update public.therapist_working_hours
  set start_time = new.open_time,
      end_time = new.close_time
  where outlet_id = new.outlet_id
    and not is_custom;

  insert into public.therapist_working_hours (
    outlet_id,
    therapist_id,
    day_of_week,
    start_time,
    end_time,
    is_custom
  )
  select staff.outlet_id,
         staff.id,
         day_number,
         new.open_time,
         new.close_time,
         false
  from public.therapists staff
  cross join generate_series(0, 6) day_number
  where staff.outlet_id = new.outlet_id
    and not exists (
      select 1
      from public.therapist_working_hours hours
      where hours.therapist_id = staff.id
        and hours.day_of_week = day_number
    );

  return new;
end;
$$;


--
-- Name: sync_room_units_for_zone(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_room_units_for_zone() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform pg_advisory_xact_lock(
    hashtextextended('room-unit-sync:' || new.id::text, 0)
  );

  if new.allocation_mode = 'specific_room'
     and coalesce(new.is_active, true) then
    if exists (
      select 1
      from public.room_units unit
      where unit.zone_id = new.id
        and unit.unit_number > greatest(coalesce(new.total_slots, 1), 1)
        and (
          exists (
            select 1
            from public.appointments appointment
            where appointment.room_unit_id = unit.id
              and appointment.appointment_date >= v_today
              and public.csp_blocks_schedule(appointment.status::text)
          )
          or exists (
            select 1
            from public.booking_holds hold
            where hold.assigned_room_unit_id = unit.id
              and hold.status = 'pending_payment'
              and hold.expires_at > now()
          )
        )
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'Cannot reduce specific rooms while a removed room has an active or future booking.';
    end if;

    insert into public.room_units (
      zone_id,
      outlet_id,
      name,
      unit_number,
      is_active
    )
    select
      new.id,
      new.outlet_id,
      'Room ' || unit_number,
      unit_number,
      true
    from generate_series(
      1,
      greatest(coalesce(new.total_slots, 1), 1)
    ) unit_number
    on conflict (zone_id, unit_number) do update
    set outlet_id = excluded.outlet_id,
        is_active = true,
        updated_at = now();

    update public.room_units
    set is_active = false,
        updated_at = now()
    where zone_id = new.id
      and unit_number > greatest(coalesce(new.total_slots, 1), 1)
      and is_active;
  else
    update public.room_units
    set is_active = false,
        updated_at = now()
    where zone_id = new.id
      and is_active;
  end if;

  return new;
end;
$$;


--
-- Name: sync_service_buffer_after(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_service_buffer_after() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update public.online_booking_services
  set buffer_after_minutes = new.buffer_after_minutes
  where service_id = new.id;

  update public.appointments
  set buffer_after_minutes = new.buffer_after_minutes
  where service_id = new.id
    and public.csp_blocks_schedule(status::text)
    and appointment_date >= ((now() at time zone 'Asia/Kuala_Lumpur')::date);

  return new;
end;
$$;


--
-- Name: sync_staff_hours_from_business_hours(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_staff_hours_from_business_hours() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.is_closed then
    -- Preserve private staff overrides while making every existing scheduling
    -- query see no working shift for the closed weekday.
    insert into public.business_hours_staff_override_archive (
      id, outlet_id, therapist_id, day_of_week, start_time, end_time
    )
    select id, outlet_id, therapist_id, day_of_week, start_time, end_time
    from public.therapist_working_hours
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week
      and is_custom
    on conflict (id) do update
    set start_time = excluded.start_time,
        end_time = excluded.end_time;

    delete from public.therapist_working_hours
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week;
  else
    insert into public.therapist_working_hours (
      id, outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
    )
    select id, outlet_id, therapist_id, day_of_week, start_time, end_time, true
    from public.business_hours_staff_override_archive
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week
    on conflict (therapist_id, day_of_week, start_time) do nothing;

    delete from public.business_hours_staff_override_archive
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week;

    update public.therapist_working_hours
    set start_time = new.open_time,
        end_time = new.close_time
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week
      and not is_custom;

    insert into public.therapist_working_hours (
      outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
    )
    select new.outlet_id,
           staff.id,
           new.day_of_week,
           new.open_time,
           new.close_time,
           false
    from public.therapists staff
    where staff.outlet_id = new.outlet_id
      and not exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = staff.id
          and hours.day_of_week = new.day_of_week
      );
  end if;

  perform public.sync_business_settings_envelope(new.outlet_id);
  return new;
end;
$$;


--
-- Name: sync_transaction_room_unit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_transaction_room_unit() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.appointment_id is not null then
    select a.room_unit_id, a.room_unit_name
    into new.room_unit_id, new.room_unit_name
    from public.appointments a
    where a.id = new.appointment_id;
  end if;
  return new;
end;
$$;


--
-- Name: therapists_reject_service_commission_writes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.therapists_reject_service_commission_writes() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if coalesce(new.service_commissions, '{}'::jsonb) <> '{}'::jsonb then
    raise exception using
      errcode = 'P0001',
      message = 'service_commissions is deprecated and must stay empty. Write per-service commission rates to commission_overrides.';
  end if;
  return new;
end;
$$;


--
-- Name: today_queue_has_started(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.today_queue_has_started(p_outlet_id uuid, p_date date) RETURNS timestamp with time zone
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(
    (
      select day_state.first_turn_consumed_at
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    (
      select min(appointment.actual_started_at)
      from public.appointments appointment
      where appointment.outlet_id = p_outlet_id
        and appointment.appointment_date = p_date
        and appointment.actual_started_at is not null
        and lower(appointment.status::text) not in (
          'cancelled', 'canceled', 'no_show', 'no-show', 'noshow'
        )
        and lower(coalesce(appointment.payment_status::text, '')) <> 'voided'
    )
  );
$$;


--
-- Name: touch_business_hours_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_business_hours_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


--
-- Name: update_appointment_group_with_csp(uuid, uuid, text, integer, date, jsonb, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_appointment_group_with_csp(p_appointment_group_id uuid, p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text DEFAULT 'appointment'::text, p_status text DEFAULT 'confirmed'::text, p_notes text DEFAULT ''::text, p_updated_by uuid DEFAULT auth.uid()) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
declare
  v_group public.appointment_groups%rowtype;
  v_existing public.appointments%rowtype;
  v_allocation jsonb;
  v_normalized jsonb := '[]'::jsonb;
  v_demands jsonb := '[]'::jsonb;
  v_feasible jsonb;
  v_old_outlet_id uuid;
  v_new_outlet_id uuid;
  v_service_outlet_id uuid;
  v_service_id uuid;
  v_existing_id uuid;
  v_saved_id uuid;
  v_input_therapist_id uuid;
  v_input_room_id uuid;
  v_input_room_unit_id uuid;
  v_target_therapist_id uuid;
  v_target_room_id uuid;
  v_target_room_unit_id uuid;
  v_target_room_unit_name text;
  v_requested_therapist_id uuid;
  v_source text;
  v_requested_gender text;
  v_target_therapist_state text;
  v_target_room_state text;
  v_preserve_therapist boolean;
  v_preserve_room boolean;
  v_has_existing boolean;
  v_start time without time zone;
  v_end time without time zone;
  v_start_at timestamp;
  v_end_at timestamp;
  v_block_end_at timestamp;
  v_buffer integer;
  v_room_type text;
  v_index integer := 0;
  v_existing_count integer;
  v_group_paid boolean;
  v_ids uuid[] := array[]::uuid[];
  v_previous_lock_timeout text;
  v_lock_date date;
  v_external_room_usage integer;
  v_internal_room_usage integer;
  v_room_total_slots integer;
  v_internal_therapist_usage integer;
  v_omitted record;
begin
  select g.* into v_group from public.appointment_groups g where g.id = p_appointment_group_id;

  if not found then
    return query select * from public.update_appointment_group_with_csp_concrete_legacy(
      p_appointment_group_id, p_customer_id, p_group_name, p_pax_count,
      p_appointment_date, p_allocations, p_type, p_status, p_notes, p_updated_by);
    return;
  end if;

  v_old_outlet_id := coalesce(v_group.outlet_id,
    (select min(a.outlet_id::text)::uuid from public.appointments a
      where a.appointment_group_id = p_appointment_group_id));

  if v_old_outlet_id is null or not public.capacity_first_enabled(v_old_outlet_id) then
    return query select * from public.update_appointment_group_with_csp_concrete_legacy(
      p_appointment_group_id, p_customer_id, p_group_name, p_pax_count,
      p_appointment_date, p_allocations, p_type, p_status, p_notes, p_updated_by);
    return;
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) = 0 then
    return query select false, p_appointment_group_id, v_ids,
      'INVALID_ALLOCATIONS', 'Group booking requires at least one pax allocation.';
    return;
  end if;

  select count(*) filter (where s.id is not null), count(distinct s.outlet_id),
         min(s.outlet_id::text)::uuid
  into v_existing_count, v_index, v_new_outlet_id
  from jsonb_array_elements(p_allocations) item
  left join public.services s on s.id = nullif(item.value ->> 'service_id', '')::uuid;

  if v_existing_count <> jsonb_array_length(p_allocations) or v_index <> 1 or v_new_outlet_id is null then
    return query select false, p_appointment_group_id, v_ids,
      'INVALID_SERVICE', 'Every pax needs a valid service from one outlet.';
    return;
  end if;

  if v_new_outlet_id is distinct from v_old_outlet_id then
    return query select false, p_appointment_group_id, v_ids,
      'CROSS_OUTLET_MOVE_NOT_SUPPORTED', 'A capacity-first group cannot be moved to another outlet.';
    return;
  end if;

  select g.* into v_group from public.appointment_groups g
  where g.id = p_appointment_group_id for update;

  if not found then
    return query select false, p_appointment_group_id, v_ids,
      'NOT_FOUND', 'Appointment group was not found.';
    return;
  end if;

  if lower(coalesce(v_group.status, '')) in ('in_progress', 'completed', 'cancelled', 'no_show') then
    return query select false, p_appointment_group_id, v_ids,
      'GROUP_NOT_EDITABLE', 'Started or terminal appointment groups cannot be edited.';
    return;
  end if;

  v_previous_lock_timeout := current_setting('lock_timeout', true);
  perform set_config('lock_timeout', '2s', true);

  begin
    for v_lock_date in
      select distinct d from (values (v_group.appointment_date), (p_appointment_date)) dates(d)
      where d is not null order by d
    loop
      perform pg_advisory_xact_lock(hashtextextended(v_old_outlet_id::text || ':' || v_lock_date::text, 0));
    end loop;
  exception
    when lock_not_available then
      perform set_config('lock_timeout', coalesce(v_previous_lock_timeout, '0'), true);
      return query select false, p_appointment_group_id, v_ids,
        'RESOURCE_LOCK_TIMEOUT', 'The appointment group is being changed elsewhere. Please retry.';
      return;
  end;

  perform set_config('lock_timeout', coalesce(v_previous_lock_timeout, '0'), true);

  perform 1 from public.appointments a
  where a.appointment_group_id = p_appointment_group_id order by a.id for update;

  if exists (
    select 1 from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and (a.resources_confirmed_at is not null or a.actual_started_at is not null
           or a.status::text in ('in_progress', 'completed', 'cancelled', 'no_show'))
  ) then
    return query select false, p_appointment_group_id, v_ids,
      'GROUP_NOT_EDITABLE', 'A started, terminal, or fully resource-confirmed pax cannot be edited.';
    return;
  end if;

  select count(*) into v_existing_count from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;

  select exists (select 1 from public.transactions t
                 where t.appointment_group_id = p_appointment_group_id
                   and t.payment_status = 'paid'
                   and coalesce(t.source, '') <> 'appointment_addon')
      or exists (select 1 from public.appointments a
                 where a.appointment_group_id = p_appointment_group_id
                   and a.payment_status = 'paid')
  into v_group_paid;

  if (select count(*) <> count(distinct nullif(item.value ->> 'appointment_id', ''))
      from jsonb_array_elements(p_allocations) item
      where nullif(item.value ->> 'appointment_id', '') is not null) then
    return query select false, p_appointment_group_id, v_ids,
      'DUPLICATE_APPOINTMENT', 'Each pax allocation must reference a different appointment.';
    return;
  end if;

  if v_group_paid and (jsonb_array_length(p_allocations) <> v_existing_count
    or exists (select 1 from jsonb_array_elements(p_allocations) item
               where nullif(item.value ->> 'appointment_id', '') is null)) then
    return query select false, p_appointment_group_id, v_ids,
      'PAID_GROUP_LOCKED', 'Paid group pax cannot be added or removed.';
    return;
  end if;

  for v_omitted in
    select a.* from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and not exists (select 1 from jsonb_array_elements(p_allocations) item
                      where nullif(item.value ->> 'appointment_id', '')::uuid = a.id)
  loop
    if v_omitted.payment_status <> 'unpaid'
       or v_omitted.actual_started_at is not null
       or v_omitted.resources_confirmed_at is not null
       or v_omitted.status::text not in ('pending', 'confirmed')
       or v_omitted.therapist_assignment_state = 'confirmed'
       or v_omitted.room_assignment_state = 'confirmed'
       or public.csp_appointment_start_at(v_omitted) <= (now() at time zone 'Asia/Kuala_Lumpur') then
      return query select false, p_appointment_group_id, v_ids,
        'PAX_NOT_REMOVABLE', 'One omitted pax is paid, started, protected, terminal, or no longer future.';
      return;
    end if;
  end loop;

  v_index := 0;

  for v_allocation in select item.value from jsonb_array_elements(p_allocations) item loop
    v_existing := null;
    v_has_existing := false;
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_service_id := nullif(v_allocation ->> 'service_id', '')::uuid;
    v_start := nullif(v_allocation ->> 'start_time', '')::time;
    v_end := nullif(v_allocation ->> 'end_time', '')::time;

    if v_existing_id is not null then
      select a.* into v_existing from public.appointments a
      where a.id = v_existing_id and a.appointment_group_id = p_appointment_group_id;
      if not found then
        return query select false, p_appointment_group_id, v_ids,
          'INVALID_APPOINTMENT', 'A pax allocation does not belong to this group.';
        return;
      end if;
      v_has_existing := true;
    end if;

    if v_service_id is null or v_start is null or v_end is null or v_end = v_start then
      return query select false, p_appointment_group_id, v_ids,
        'INVALID_ALLOCATION', 'One pax allocation has a missing service or invalid time range.';
      return;
    end if;

    select s.outlet_id, coalesce(s.buffer_after_minutes, 0), lower(trim(s.room_type::text))
    into v_service_outlet_id, v_buffer, v_room_type
    from public.services s where s.id = v_service_id;

    if v_service_outlet_id is distinct from v_old_outlet_id then
      return query select false, p_appointment_group_id, v_ids,
        'INVALID_SERVICE', 'Every pax service must belong to the existing group outlet.';
      return;
    end if;

    v_start_at := public.csp_start_at(p_appointment_date, v_start);
    v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);
    v_block_end_at := v_end_at + make_interval(mins => greatest(v_buffer, 0));

    v_source := coalesce(nullif(v_allocation ->> 'assignment_source', ''),
                         case when v_has_existing then v_existing.assignment_source end, 'queue');

    if v_source not in ('queue', 'gender_preference', 'specific_customer_request', 'manual_override') then
      return query select false, p_appointment_group_id, v_ids,
        'INVALID_ASSIGNMENT_SOURCE', 'One pax allocation has an invalid assignment source.';
      return;
    end if;

    if v_has_existing and (v_existing.therapist_assignment_state = 'confirmed'
                           or v_existing.room_assignment_state = 'confirmed') then
      v_source := v_existing.assignment_source;
    end if;

    v_requested_gender := coalesce(nullif(v_allocation ->> 'requested_gender', ''),
                                   case when v_has_existing then v_existing.requested_gender end);

    v_input_therapist_id := nullif(v_allocation ->> 'therapist_id', '')::uuid;
    v_input_room_id := nullif(v_allocation ->> 'room_id', '')::uuid;
    v_input_room_unit_id := nullif(v_allocation ->> 'room_unit_id', '')::uuid;

    v_target_therapist_id := null;
    v_target_room_id := null;
    v_target_room_unit_id := null;
    v_target_room_unit_name := '';
    v_target_therapist_state := 'pending';
    v_target_room_state := 'pending';

    v_preserve_therapist := v_has_existing and v_existing.therapist_id is not null
      and v_existing.therapist_assignment_state = 'confirmed';
    v_preserve_room := v_has_existing and v_existing.room_id is not null
      and v_existing.room_assignment_state = 'confirmed';

    if v_source = 'specific_customer_request' then
      v_requested_therapist_id := coalesce(
        case when v_has_existing then v_existing.requested_therapist_id end,
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        v_input_therapist_id,
        case when v_has_existing then v_existing.therapist_id end);

      if v_requested_therapist_id is null then
        return query select false, p_appointment_group_id, v_ids,
          'REQUESTED_THERAPIST_REQUIRED', 'A specific customer request needs an exact therapist.';
        return;
      end if;

      if v_preserve_therapist and v_existing.therapist_id is distinct from v_requested_therapist_id then
        return query select false, p_appointment_group_id, v_ids,
          'PROTECTED_THERAPIST_CONFLICT', 'A protected therapist cannot be silently replaced.';
        return;
      end if;

      v_target_therapist_id := coalesce(
        case when v_preserve_therapist then v_existing.therapist_id end, v_requested_therapist_id);
      v_target_therapist_state := 'confirmed';

      if v_preserve_room then
        v_target_room_id := v_existing.room_id;
        v_target_room_unit_id := v_existing.room_unit_id;
        v_target_room_unit_name := coalesce(v_existing.room_unit_name, '');
        v_target_room_state := 'confirmed';
      end if;

    elsif v_source = 'manual_override' then
      if v_preserve_therapist and v_input_therapist_id is not null
         and v_existing.therapist_id is distinct from v_input_therapist_id then
        return query select false, p_appointment_group_id, v_ids,
          'PROTECTED_THERAPIST_CONFLICT', 'A protected therapist cannot be silently replaced.';
        return;
      end if;

      if v_preserve_room and v_input_room_id is not null
         and v_existing.room_id is distinct from v_input_room_id then
        return query select false, p_appointment_group_id, v_ids,
          'PROTECTED_ROOM_CONFLICT', 'A protected room cannot be silently replaced.';
        return;
      end if;

      v_target_therapist_id := coalesce(
        case when v_preserve_therapist then v_existing.therapist_id end, v_input_therapist_id);
      v_target_room_id := coalesce(
        case when v_preserve_room then v_existing.room_id end, v_input_room_id);

      if v_target_therapist_id is null and v_target_room_id is null then
        return query select false, p_appointment_group_id, v_ids,
          'MANUAL_RESOURCE_REQUIRED', 'A manual override must lock a therapist, a room, or both.';
        return;
      end if;

      if v_target_therapist_id is not null then
        v_target_therapist_state := 'confirmed';
      end if;

      if v_target_room_id is not null then
        v_target_room_state := 'confirmed';
        if v_preserve_room and v_existing.room_id = v_target_room_id then
          v_target_room_unit_id := v_existing.room_unit_id;
          v_target_room_unit_name := coalesce(v_existing.room_unit_name, '');
        else
          v_target_room_unit_id := v_input_room_unit_id;
        end if;
      end if;

      v_requested_therapist_id := coalesce(
        case when v_has_existing then v_existing.requested_therapist_id end,
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid);

    else
      if v_preserve_therapist then
        v_target_therapist_id := v_existing.therapist_id;
        v_target_therapist_state := 'confirmed';
      end if;

      if v_preserve_room then
        v_target_room_id := v_existing.room_id;
        v_target_room_unit_id := v_existing.room_unit_id;
        v_target_room_unit_name := coalesce(v_existing.room_unit_name, '');
        v_target_room_state := 'confirmed';
      end if;

      v_requested_therapist_id := case
        when v_preserve_therapist then v_existing.requested_therapist_id else null end;
    end if;

    if v_target_therapist_id is not null and not exists (
      select 1 from public.therapists t
      where t.id = v_target_therapist_id and t.outlet_id = v_old_outlet_id
        and coalesce(t.availability_status, true)
        and lower(coalesce(t.role, 'therapist')) = 'therapist') then
      return query select false, p_appointment_group_id, v_ids,
        'INVALID_THERAPIST', 'A preserved or requested therapist is not active in this outlet.';
      return;
    end if;

    if v_target_room_id is not null then
      if not exists (
        select 1 from public.rooms r
        where r.id = v_target_room_id and r.outlet_id = v_old_outlet_id
          and coalesce(r.is_active, true)
          and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type) then
        return query select false, p_appointment_group_id, v_ids,
          'INVALID_ROOM', 'A preserved or manually selected room is invalid for the service.';
        return;
      end if;

      if v_target_room_unit_id is not null then
        select coalesce(u.name, '') into v_target_room_unit_name
        from public.room_units u
        where u.id = v_target_room_unit_id and u.zone_id = v_target_room_id
          and u.outlet_id = v_old_outlet_id and u.is_active;
        if not found then
          return query select false, p_appointment_group_id, v_ids,
            'INVALID_ROOM_UNIT', 'The selected room unit is not active in the selected room zone.';
          return;
        end if;
      end if;
    else
      v_target_room_unit_id := null;
      v_target_room_unit_name := '';
      v_target_room_state := 'pending';
    end if;

    v_normalized := v_normalized || jsonb_build_array(
      v_allocation || jsonb_build_object(
        'appointment_id', v_existing_id, 'service_id', v_service_id,
        'therapist_id', v_target_therapist_id, 'room_id', v_target_room_id,
        'room_unit_id', v_target_room_unit_id, 'room_unit_name', v_target_room_unit_name,
        'assignment_source', v_source, 'requested_gender', v_requested_gender,
        'requested_therapist_id', v_requested_therapist_id,
        'therapist_assignment_state', v_target_therapist_state,
        'room_assignment_state', v_target_room_state,
        'buffer_after_minutes', v_buffer, 'room_type', v_room_type,
        'start_at', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'end_at', to_char(v_end_at, 'YYYY-MM-DD HH24:MI:SS'),
        'block_end_at', to_char(v_block_end_at, 'YYYY-MM-DD HH24:MI:SS')));

    v_demands := v_demands || jsonb_build_array(jsonb_build_object(
      'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
      'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::integer,
      'buffer_after_minutes', v_buffer, 'service_id', v_service_id::text,
      'room_type', v_room_type, 'requested_gender', v_requested_gender,
      'requested_therapist_id',
        case when v_source = 'specific_customer_request' then v_target_therapist_id::text else null end,
      'manual_lock_id',
        case when v_target_therapist_id is not null and v_source <> 'specific_customer_request'
             then v_target_therapist_id::text else null end,
      'pax_index', v_index));

    v_index := v_index + 1;
  end loop;

  v_feasible := public.capacity_feasible(v_old_outlet_id, v_demands, 'hard', null, p_appointment_group_id);

  if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
    return query select false, p_appointment_group_id, v_ids,
      case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end,
      'The revised group exceeds available ' || coalesce(v_feasible ->> 'dimension', 'therapist') || ' capacity.';
    return;
  end if;

  for v_allocation in select item.value from jsonb_array_elements(v_normalized) item loop
    if nullif(v_allocation ->> 'therapist_id', '') is not null then
      select count(*) into v_internal_therapist_usage
      from jsonb_array_elements(v_normalized) other
      where nullif(other.value ->> 'therapist_id', '')::uuid = (v_allocation ->> 'therapist_id')::uuid
        and (other.value ->> 'start_at')::timestamp < (v_allocation ->> 'block_end_at')::timestamp
        and (other.value ->> 'block_end_at')::timestamp > (v_allocation ->> 'start_at')::timestamp;
      if v_internal_therapist_usage > 1 then
        return query select false, p_appointment_group_id, v_ids, 'THERAPIST_UNAVAILABLE',
          'The same concrete therapist cannot cover overlapping service and cleanup windows.';
        return;
      end if;
    end if;

    if nullif(v_allocation ->> 'room_id', '') is not null then
      select greatest(coalesce(r.total_slots, 1), 1) into v_room_total_slots
      from public.rooms r where r.id = (v_allocation ->> 'room_id')::uuid;

      select
        (select count(*) from public.appointments a
          where a.room_id = (v_allocation ->> 'room_id')::uuid
            and a.appointment_group_id is distinct from p_appointment_group_id
            and public.csp_blocks_schedule(a.status::text)
            and public.csp_appointment_start_at(a) < (v_allocation ->> 'block_end_at')::timestamp
            and public.csp_appointment_block_end_at(a) > (v_allocation ->> 'start_at')::timestamp)
        + (select count(*) from public.booking_holds h
          where h.assigned_room_id = (v_allocation ->> 'room_id')::uuid
            and h.status = 'pending_payment' and h.expires_at > now()
            and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
            and (h.start_at at time zone 'Asia/Kuala_Lumpur') < (v_allocation ->> 'block_end_at')::timestamp
            and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
                  at time zone 'Asia/Kuala_Lumpur') > (v_allocation ->> 'start_at')::timestamp)
      into v_external_room_usage;

      select count(*) into v_internal_room_usage
      from jsonb_array_elements(v_normalized) other
      where nullif(other.value ->> 'room_id', '')::uuid = (v_allocation ->> 'room_id')::uuid
        and (other.value ->> 'start_at')::timestamp < (v_allocation ->> 'block_end_at')::timestamp
        and (other.value ->> 'block_end_at')::timestamp > (v_allocation ->> 'start_at')::timestamp;

      if coalesce(v_external_room_usage, 0) + coalesce(v_internal_room_usage, 0)
         > coalesce(v_room_total_slots, 1) then
        return query select false, p_appointment_group_id, v_ids, 'ROOM_FULL',
          'A preserved or manually selected room lacks enough slots for the full service and cleanup window.';
        return;
      end if;
    end if;
  end loop;

  update public.appointment_groups g
  set customer_id = p_customer_id, group_name = coalesce(p_group_name, ''),
      pax_count = jsonb_array_length(v_normalized), appointment_date = p_appointment_date,
      status = coalesce(nullif(p_status, ''), 'confirmed'), notes = coalesce(p_notes, '')
  where g.id = p_appointment_group_id
    and (g.customer_id, g.group_name, g.pax_count, g.appointment_date, g.status, g.notes)
        is distinct from (p_customer_id, coalesce(p_group_name, ''), jsonb_array_length(v_normalized),
          p_appointment_date, coalesce(nullif(p_status, ''), 'confirmed'), coalesce(p_notes, ''));

  for v_allocation in select item.value from jsonb_array_elements(v_normalized) item loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;

    if v_existing_id is not null then
      update public.appointments a
      set customer_id = p_customer_id,
          therapist_id = nullif(v_allocation ->> 'therapist_id', '')::uuid,
          room_id = nullif(v_allocation ->> 'room_id', '')::uuid,
          room_unit_id = nullif(v_allocation ->> 'room_unit_id', '')::uuid,
          room_unit_name = coalesce(v_allocation ->> 'room_unit_name', ''),
          service_id = (v_allocation ->> 'service_id')::uuid,
          appointment_date = p_appointment_date,
          start_time = (v_allocation ->> 'start_time')::time,
          end_time = (v_allocation ->> 'end_time')::time,
          start_at = (v_allocation ->> 'start_at')::timestamp,
          end_at = (v_allocation ->> 'end_at')::timestamp,
          buffer_after_minutes = (v_allocation ->> 'buffer_after_minutes')::integer,
          booked_date = p_appointment_date,
          booked_start_time = (v_allocation ->> 'start_time')::time,
          booked_end_time = (v_allocation ->> 'end_time')::time,
          booked_start_at = (v_allocation ->> 'start_at')::timestamp at time zone 'Asia/Kuala_Lumpur',
          booked_end_at = (v_allocation ->> 'end_at')::timestamp at time zone 'Asia/Kuala_Lumpur',
          total_price = coalesce((v_allocation ->> 'total_price')::numeric, 0),
          type = coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
          service_name = coalesce(v_allocation ->> 'service_name', ''),
          service_items = coalesce(v_allocation -> 'service_items', '[]'::jsonb),
          item_count = greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
          notes = coalesce(v_allocation ->> 'notes', ''),
          assignment_source = v_allocation ->> 'assignment_source',
          requested_therapist_id = nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
          requested_gender = nullif(v_allocation ->> 'requested_gender', ''),
          therapist_assignment_state = v_allocation ->> 'therapist_assignment_state',
          room_assignment_state = v_allocation ->> 'room_assignment_state',
          therapist_auto_assigned_at = case
            when v_allocation ->> 'therapist_assignment_state' = 'auto_assigned'
              then a.therapist_auto_assigned_at else null end,
          updated_at = now(), updated_by = p_updated_by
      where a.id = v_existing_id and a.appointment_group_id = p_appointment_group_id
        and (
          a.customer_id is distinct from p_customer_id
          or a.therapist_id is distinct from nullif(v_allocation ->> 'therapist_id', '')::uuid
          or a.room_id is distinct from nullif(v_allocation ->> 'room_id', '')::uuid
          or a.room_unit_id is distinct from nullif(v_allocation ->> 'room_unit_id', '')::uuid
          or a.room_unit_name is distinct from coalesce(v_allocation ->> 'room_unit_name', '')
          or a.service_id is distinct from (v_allocation ->> 'service_id')::uuid
          or a.appointment_date is distinct from p_appointment_date
          or a.start_time is distinct from (v_allocation ->> 'start_time')::time
          or a.end_time is distinct from (v_allocation ->> 'end_time')::time
          or a.buffer_after_minutes is distinct from (v_allocation ->> 'buffer_after_minutes')::integer
          or a.total_price is distinct from coalesce((v_allocation ->> 'total_price')::numeric, 0)
          or a.type is distinct from coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type
          or a.service_name is distinct from coalesce(v_allocation ->> 'service_name', '')
          or a.service_items is distinct from coalesce(v_allocation -> 'service_items', '[]'::jsonb)
          or a.item_count is distinct from greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1)
          or a.notes is distinct from coalesce(v_allocation ->> 'notes', '')
          or a.assignment_source is distinct from (v_allocation ->> 'assignment_source')
          or a.requested_therapist_id is distinct from nullif(v_allocation ->> 'requested_therapist_id', '')::uuid
          or a.requested_gender is distinct from nullif(v_allocation ->> 'requested_gender', '')
          or a.therapist_assignment_state is distinct from (v_allocation ->> 'therapist_assignment_state')
          or a.room_assignment_state is distinct from (v_allocation ->> 'room_assignment_state')
        )
      returning a.id into v_saved_id;

      if not found then
        v_saved_id := v_existing_id;
      end if;
    else
      insert into public.appointments (
        appointment_group_id, customer_id, therapist_id, room_id, room_unit_id,
        room_unit_name, service_id, appointment_date, start_time, end_time,
        start_at, end_at, buffer_after_minutes, status, total_price,
        booked_date, booked_start_time, booked_end_time, booked_start_at, booked_end_at,
        type, service_name, service_items, item_count, notes, created_at, created_by,
        assignment_source, requested_therapist_id, requested_gender,
        therapist_assignment_state, room_assignment_state, outlet_id
      ) values (
        p_appointment_group_id, p_customer_id,
        nullif(v_allocation ->> 'therapist_id', '')::uuid,
        nullif(v_allocation ->> 'room_id', '')::uuid,
        nullif(v_allocation ->> 'room_unit_id', '')::uuid,
        coalesce(v_allocation ->> 'room_unit_name', ''),
        (v_allocation ->> 'service_id')::uuid, p_appointment_date,
        (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time,
        (v_allocation ->> 'start_at')::timestamp, (v_allocation ->> 'end_at')::timestamp,
        (v_allocation ->> 'buffer_after_minutes')::integer, 'confirmed',
        coalesce((v_allocation ->> 'total_price')::numeric, 0),
        p_appointment_date, (v_allocation ->> 'start_time')::time, (v_allocation ->> 'end_time')::time,
        (v_allocation ->> 'start_at')::timestamp at time zone 'Asia/Kuala_Lumpur',
        (v_allocation ->> 'end_at')::timestamp at time zone 'Asia/Kuala_Lumpur',
        coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
        coalesce(v_allocation ->> 'service_name', ''),
        coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
        coalesce(v_allocation ->> 'notes', ''), now(), p_updated_by,
        v_allocation ->> 'assignment_source',
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        nullif(v_allocation ->> 'requested_gender', ''),
        v_allocation ->> 'therapist_assignment_state',
        v_allocation ->> 'room_assignment_state',
        v_old_outlet_id
      ) returning id into v_saved_id;
    end if;

    v_ids := array_append(v_ids, v_saved_id);
  end loop;

  delete from public.appointments a
  where a.appointment_group_id = p_appointment_group_id and not (a.id = any(v_ids));

  return query select true, p_appointment_group_id, v_ids, null::text, null::text;
end;
$$;


--
-- Name: update_appointment_group_with_csp_concrete_legacy(uuid, uuid, text, integer, date, jsonb, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_appointment_group_with_csp_concrete_legacy(p_appointment_group_id uuid, p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text DEFAULT 'appointment'::text, p_status text DEFAULT 'confirmed'::text, p_notes text DEFAULT ''::text, p_updated_by uuid DEFAULT auth.uid()) RETURNS TABLE(success boolean, appointment_group_id uuid, appointment_ids uuid[], error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_allocation jsonb;
  v_existing_id uuid;
  v_saved_id uuid;
  v_check record;
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_start time;
  v_end time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_group_conflicts integer;
  v_group_room_slots integer;
  v_existing_count integer;
  v_group_paid boolean;
begin
  appointment_ids := array[]::uuid[];
  appointment_group_id := p_appointment_group_id;

  if not exists (
    select 1 from public.appointment_groups g
    where g.id = p_appointment_group_id
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'NOT_FOUND', 'Appointment group was not found.';
    return;
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
      or jsonb_array_length(p_allocations) = 0 then
    return query select false, p_appointment_group_id, appointment_ids,
      'INVALID_ALLOCATIONS', 'Group booking requires at least one pax allocation.';
    return;
  end if;

  select count(*) into v_existing_count
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;

  select exists (
    select 1 from public.transactions t
    where t.appointment_group_id = p_appointment_group_id
      and t.payment_status = 'paid'
      and coalesce(t.source, '') <> 'appointment_addon'
  ) or exists (
    select 1 from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and a.payment_status = 'paid'
  ) into v_group_paid;

  if (
    select count(*) <> count(distinct nullif(value ->> 'appointment_id', ''))
    from jsonb_array_elements(p_allocations)
    where nullif(value ->> 'appointment_id', '') is not null
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'DUPLICATE_APPOINTMENT', 'Each pax allocation must reference a different appointment.';
    return;
  end if;

  if v_group_paid and (
    jsonb_array_length(p_allocations) <> v_existing_count
    or exists (
      select 1 from jsonb_array_elements(p_allocations) item
      where nullif(item.value ->> 'appointment_id', '') is null
    )
  ) then
    return query select false, p_appointment_group_id, appointment_ids,
      'PAID_GROUP_LOCKED', 'Paid group pax cannot be added or removed.';
    return;
  end if;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_existing_id is not null and not exists (
      select 1 from public.appointments a
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id
    ) then
      return query select false, p_appointment_group_id, appointment_ids,
        'INVALID_APPOINTMENT', 'A pax allocation does not belong to this group.';
      return;
    end if;

    if v_start is null or v_end is null or v_end = v_start then
      return query select false, p_appointment_group_id, appointment_ids,
        'INVALID_DURATION', 'One pax allocation has an invalid time range.';
      return;
    end if;

    v_start_at := public.csp_start_at(p_appointment_date, v_start);
    v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);

    select * into v_check
    from public.check_booking_availability(
      p_appointment_date, v_start, v_end, v_therapist_id, v_room_id,
      v_existing_id, p_appointment_group_id
    );

    if not coalesce(v_check.therapist_available, false) then
      return query select false, p_appointment_group_id, appointment_ids,
        'THERAPIST_UNAVAILABLE', 'One pax allocation has a staff conflict.';
      return;
    end if;

    select count(*) into v_group_conflicts
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'therapist_id')::uuid = v_therapist_id
      and public.csp_start_at(
        p_appointment_date, (other.value ->> 'start_time')::time
      ) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if v_group_conflicts > 1 then
      return query select false, p_appointment_group_id, appointment_ids,
        'THERAPIST_UNAVAILABLE',
        'The same staff cannot serve overlapping pax in one group.';
      return;
    end if;

    select count(*) into v_group_room_slots
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'room_id')::uuid = v_room_id
      and public.csp_start_at(
        p_appointment_date, (other.value ->> 'start_time')::time
      ) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots
        > coalesce(v_check.room_total_slots, 1) then
      return query select false, p_appointment_group_id, appointment_ids,
        'ROOM_FULL', 'A room or zone does not have enough slots for this group.';
      return;
    end if;
  end loop;

  update public.appointment_groups
  set customer_id = p_customer_id,
      group_name = coalesce(p_group_name, ''),
      pax_count = jsonb_array_length(p_allocations),
      appointment_date = p_appointment_date,
      status = coalesce(nullif(p_status, ''), 'confirmed'),
      notes = coalesce(p_notes, '')
  where id = p_appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_existing_id := nullif(v_allocation ->> 'appointment_id', '')::uuid;
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_existing_id is not null then
      update public.appointments a
      set customer_id = p_customer_id,
          therapist_id = v_therapist_id,
          room_id = v_room_id,
          service_id = v_service_id,
          appointment_date = p_appointment_date,
          start_time = v_start,
          end_time = v_end,
          start_at = public.csp_start_at(p_appointment_date, v_start),
          end_at = public.csp_end_at(p_appointment_date, v_start, v_end),
          booked_date = case when a.actual_started_at is null
            then p_appointment_date else a.booked_date end,
          booked_start_time = case when a.actual_started_at is null
            then v_start else a.booked_start_time end,
          booked_end_time = case when a.actual_started_at is null
            then v_end else a.booked_end_time end,
          booked_start_at = case when a.actual_started_at is null
            then public.csp_start_at(p_appointment_date, v_start)
              at time zone 'Asia/Kuala_Lumpur'
            else a.booked_start_at end,
          booked_end_at = case when a.actual_started_at is null
            then public.csp_end_at(p_appointment_date, v_start, v_end)
              at time zone 'Asia/Kuala_Lumpur'
            else a.booked_end_at end,
          total_price = coalesce((v_allocation ->> 'total_price')::numeric, 0),
          type = coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
          service_name = coalesce(v_allocation ->> 'service_name', ''),
          service_items = coalesce(v_allocation -> 'service_items', '[]'::jsonb),
          item_count = greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
          notes = coalesce(v_allocation ->> 'notes', ''),
          assignment_source = coalesce(
            nullif(v_allocation ->> 'assignment_source', ''), a.assignment_source
          ),
          requested_therapist_id = nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
          requested_gender = nullif(v_allocation ->> 'requested_gender', ''),
          updated_at = now(),
          updated_by = p_updated_by
      where a.id = v_existing_id
        and a.appointment_group_id = p_appointment_group_id
      returning a.id into v_saved_id;
    else
      insert into public.appointments (
        appointment_group_id, customer_id, therapist_id, room_id, service_id,
        appointment_date, start_time, end_time, start_at, end_at,
        booked_date, booked_start_time, booked_end_time,
        booked_start_at, booked_end_at,
        status, total_price, type, service_name, service_items, item_count,
        notes, created_at, created_by,
        assignment_source, requested_therapist_id, requested_gender) values (
        p_appointment_group_id, p_customer_id, v_therapist_id, v_room_id,
        v_service_id, p_appointment_date, v_start, v_end,
        public.csp_start_at(p_appointment_date, v_start),
        public.csp_end_at(p_appointment_date, v_start, v_end),
        p_appointment_date, v_start, v_end,
        public.csp_start_at(p_appointment_date, v_start)
          at time zone 'Asia/Kuala_Lumpur',
        public.csp_end_at(p_appointment_date, v_start, v_end)
          at time zone 'Asia/Kuala_Lumpur',
        'confirmed', coalesce((v_allocation ->> 'total_price')::numeric, 0),
        coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
        coalesce(v_allocation ->> 'service_name', ''),
        coalesce(v_allocation -> 'service_items', '[]'::jsonb),
        greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
        coalesce(v_allocation ->> 'notes', ''), now(), p_updated_by,
        coalesce(nullif(v_allocation ->> 'assignment_source', ''), 'queue'),
        nullif(v_allocation ->> 'requested_therapist_id', '')::uuid,
        nullif(v_allocation ->> 'requested_gender', '')) returning id into v_saved_id;
    end if;

    appointment_ids := array_append(appointment_ids, v_saved_id);
  end loop;

  if not v_group_paid then
    delete from public.appointments a
    where a.appointment_group_id = p_appointment_group_id
      and not (a.id = any(appointment_ids));
  end if;

  return query select true, p_appointment_group_id, appointment_ids,
    null::text, null::text;
end;
$$;


--
-- Name: update_appointment_with_csp(uuid, uuid, uuid, date, time without time zone, time without time zone, text, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_appointment_with_csp(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_assignment_source text DEFAULT NULL::text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text, p_is_provisional boolean DEFAULT NULL::boolean) RETURNS TABLE(success boolean, appointment_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
declare
  v_appt public.appointments%rowtype;
  v_outlet uuid;
  v_buffer integer;
  v_room_type text;
  v_source text;
  v_feasible jsonb;
  v_start_at timestamp;
  v_end_at timestamp;
  v_therapist_id uuid := p_therapist_id;
  v_room_id uuid := p_room_id;
  v_requested_therapist uuid := p_requested_therapist_id;
  v_room_total_slots integer;
  v_room_overlap_count integer;
  v_hold_overlap_count integer;
  v_lock_row record;
  v_protect_therapist boolean;
  v_protect_room boolean;
  v_therapist_state text;
  v_room_state text;
begin
  select * into v_appt from public.appointments a where a.id = p_appointment_id;
  if not found then
    success := false; appointment_id := null; error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.'; return next; return;
  end if;

  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false; appointment_id := null; error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.'; return next; return;
  end if;

  v_source := coalesce(nullif(p_assignment_source, ''), v_appt.assignment_source, 'queue');
  select s.outlet_id, coalesce(s.buffer_after_minutes, 0), lower(trim(coalesce(s.room_type::text, '')))
    into v_outlet, v_buffer, v_room_type from public.services s where s.id = v_appt.service_id;

  if v_outlet is not null
     and v_appt.type::text <> 'walkin'
     and public.capacity_first_enabled(v_outlet) then

    if v_appt.actual_started_at is not null
       or v_appt.resources_confirmed_at is not null
       or v_appt.status::text in ('in_progress', 'completed', 'cancelled', 'no_show') then
      success := false; appointment_id := null; error_code := 'APPOINTMENT_NOT_EDITABLE';
      error_message := 'Started, terminal, or fully resource-confirmed appointments cannot be edited.';
      return next; return;
    end if;

    if v_appt.outlet_id is distinct from v_outlet then
      success := false; appointment_id := null; error_code := 'CROSS_OUTLET_MOVE_NOT_SUPPORTED';
      error_message := 'A capacity-first appointment cannot be moved to another outlet.';
      return next; return;
    end if;

    v_protect_therapist := v_appt.therapist_id is not null
                           and v_appt.therapist_assignment_state = 'confirmed';
    v_protect_room := v_appt.room_id is not null
                      and v_appt.room_assignment_state = 'confirmed';

    if v_source = 'specific_customer_request' then
      v_requested_therapist := coalesce(v_requested_therapist, v_therapist_id, v_appt.requested_therapist_id);
      v_therapist_id := coalesce(v_therapist_id, v_appt.therapist_id, v_requested_therapist);

      if v_therapist_id is null or v_requested_therapist is null
         or v_requested_therapist is distinct from v_therapist_id then
        success := false; appointment_id := null; error_code := 'REQUESTED_THERAPIST_REQUIRED';
        error_message := 'A specific customer request needs an exact matching therapist.'; return next; return;
      end if;

      if v_protect_therapist and v_appt.therapist_id is distinct from v_therapist_id then
        success := false; appointment_id := null; error_code := 'PROTECTED_THERAPIST_CONFLICT';
        error_message := 'A protected therapist cannot be silently replaced.'; return next; return;
      end if;

      v_room_id := case when v_protect_room then v_appt.room_id else null end;

    elsif v_source = 'manual_override' then
      if v_protect_therapist then
        if p_therapist_id is not null and p_therapist_id is distinct from v_appt.therapist_id then
          success := false; appointment_id := null; error_code := 'PROTECTED_THERAPIST_CONFLICT';
          error_message := 'A protected therapist cannot be silently replaced.'; return next; return;
        end if;
        v_therapist_id := v_appt.therapist_id;
      end if;

      if v_protect_room then
        if p_room_id is not null and p_room_id is distinct from v_appt.room_id then
          success := false; appointment_id := null; error_code := 'PROTECTED_ROOM_CONFLICT';
          error_message := 'A protected room cannot be silently replaced.'; return next; return;
        end if;
        v_room_id := v_appt.room_id;
      end if;

      if v_therapist_id is null and v_room_id is null then
        success := false; appointment_id := null; error_code := 'MANUAL_RESOURCE_REQUIRED';
        error_message := 'A manual override must lock a therapist, a room, or both.'; return next; return;
      end if;

      v_requested_therapist := coalesce(v_requested_therapist, v_appt.requested_therapist_id);
    else
      v_therapist_id := null; v_room_id := null; v_requested_therapist := null;
    end if;

    perform set_config('lock_timeout', '2s', true);
    begin
      for v_lock_row in
        select distinct o_id, d_val
        from (values (v_appt.outlet_id, v_appt.appointment_date), (v_outlet, p_date)) v(o_id, d_val)
        where o_id is not null and d_val is not null
        order by o_id, d_val
      loop
        perform pg_advisory_xact_lock(hashtextextended(v_lock_row.o_id::text || ':' || v_lock_row.d_val::text, 0));
      end loop;
    exception
      when lock_not_available then
        perform set_config('lock_timeout', '0', true);
        success := false; appointment_id := null; error_code := 'RESOURCE_LOCK_TIMEOUT';
        error_message := 'The appointment is busy. Please retry.'; return next; return;
    end;
    perform set_config('lock_timeout', '0', true);

    v_start_at := public.csp_start_at(p_date, p_start_time);
    v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);

    if v_room_id is not null then
      select coalesce(sum(greatest(coalesce(r.total_slots, 1), 1)), 0) into v_room_total_slots
      from public.rooms r
      where r.id = v_room_id and r.outlet_id = v_outlet and coalesce(r.is_active, true)
        and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type;

      if coalesce(v_room_total_slots, 0) = 0 then
        success := false; appointment_id := null; error_code := 'INVALID_ROOM';
        error_message := 'The selected room is inactive, in another outlet, or the wrong room type for this service.';
        return next; return;
      end if;

      select count(*) into v_room_overlap_count
      from public.appointments a
      where a.room_id = v_room_id and a.id is distinct from p_appointment_id
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < v_end_at + make_interval(mins => greatest(v_buffer, 0))
        and public.csp_appointment_block_end_at(a) > v_start_at;

      select count(*) into v_hold_overlap_count
      from public.booking_holds h
      where h.assigned_room_id = v_room_id and h.status = 'pending_payment'
        and h.expires_at > now() and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at + make_interval(mins => greatest(v_buffer, 0))
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_start_at;

      if v_room_overlap_count + v_hold_overlap_count >= v_room_total_slots then
        success := false; appointment_id := null; error_code := 'ROOM_FULL';
        error_message := 'The selected room is full for the requested time.'; return next; return;
      end if;
    end if;

    v_feasible := public.capacity_feasible(v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', v_appt.service_id::text,
        'room_type', v_room_type, 'requested_gender', p_requested_gender,
        'requested_therapist_id', case when v_source = 'specific_customer_request' then v_requested_therapist::text else null end,
        'manual_lock_id', case when v_source = 'manual_override' and v_therapist_id is not null then v_therapist_id::text else null end,
        'pax_index', 0)), 'hard', p_appointment_id);

    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough capacity for the new time.'; return next; return;
    end if;

    v_therapist_state := case when v_therapist_id is not null then 'confirmed' else 'pending' end;
    v_room_state := case when v_room_id is not null then 'confirmed' else 'pending' end;

    update public.appointments
    set therapist_id = v_therapist_id,
        room_id = v_room_id,
        room_unit_id = case when v_room_id is null then null else room_unit_id end,
        room_unit_name = case when v_room_id is null then '' else room_unit_name end,
        therapist_assignment_state = v_therapist_state,
        room_assignment_state = v_room_state,
        therapist_auto_assigned_at = case when v_therapist_id is null then null else therapist_auto_assigned_at end,
        appointment_date = p_date, start_time = p_start_time, end_time = p_end_time,
        start_at = v_start_at, end_at = v_end_at,
        booked_date = p_date, booked_start_time = p_start_time, booked_end_time = p_end_time,
        booked_start_at = v_start_at at time zone 'Asia/Kuala_Lumpur',
        booked_end_at = v_end_at at time zone 'Asia/Kuala_Lumpur',
        assignment_source = v_source,
        requested_therapist_id = v_requested_therapist,
        requested_gender = p_requested_gender,
        updated_at = now()
    where id = p_appointment_id
      and (
        therapist_id is distinct from v_therapist_id
        or room_id is distinct from v_room_id
        or (v_room_id is null and (room_unit_id is not null or coalesce(room_unit_name, '') <> ''))
        or therapist_assignment_state is distinct from v_therapist_state
        or room_assignment_state is distinct from v_room_state
        or (v_therapist_id is null and therapist_auto_assigned_at is not null)
        or appointment_date is distinct from p_date
        or start_time is distinct from p_start_time
        or end_time is distinct from p_end_time
        or start_at is distinct from v_start_at
        or end_at is distinct from v_end_at
        or booked_date is distinct from p_date
        or booked_start_time is distinct from p_start_time
        or booked_end_time is distinct from p_end_time
        or assignment_source is distinct from v_source
        or requested_therapist_id is distinct from v_requested_therapist
        or requested_gender is distinct from p_requested_gender
      )
    returning id into appointment_id;

    if not found then
      appointment_id := p_appointment_id;
    end if;

    success := true; error_code := null; error_message := null; return next; return;
  end if;

  return query select * from public.update_appointment_with_csp_121_legacy(
    p_appointment_id, p_therapist_id, p_room_id, p_date, p_start_time, p_end_time,
    p_assignment_source, p_requested_therapist_id, p_requested_gender, p_is_provisional);
end;
$$;


--
-- Name: update_appointment_with_csp_121_legacy(uuid, uuid, uuid, date, time without time zone, time without time zone, text, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_appointment_with_csp_121_legacy(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_assignment_source text DEFAULT NULL::text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text, p_is_provisional boolean DEFAULT NULL::boolean) RETURNS TABLE(success boolean, appointment_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_check record; v_appt public.appointments%rowtype;
  v_outlet uuid; v_buffer integer; v_room_type text;
  v_source text; v_feasible jsonb; v_start_at timestamp; v_end_at timestamp;
begin
  select * into v_appt from public.appointments a where a.id = p_appointment_id;
  if not found then
    success := false; appointment_id := null; error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.'; return next; return;
  end if;
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false; appointment_id := null; error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.'; return next; return;
  end if;
  v_source := coalesce(nullif(p_assignment_source,''), v_appt.assignment_source, 'queue');
  select s.outlet_id, coalesce(s.buffer_after_minutes,0), lower(coalesce(s.room_type::text,''))
    into v_outlet, v_buffer, v_room_type from public.services s where s.id = v_appt.service_id;

  -- RC-1: nulling a walk-in's therapist would make
  -- normalize_appointment_assignment_states force both states to 'confirmed'
  -- (its type='walkin' branch) and then violate CHECK
  -- appointments_started_requires_concrete.
  if v_outlet is not null and public.capacity_first_enabled(v_outlet)
     and v_appt.type::text <> 'walkin'
     and v_source in ('queue','gender_preference') and v_appt.actual_started_at is null then
    v_start_at := public.csp_start_at(p_date, p_start_time);
    v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);
    perform set_config('lock_timeout','2s', true);
    perform pg_advisory_xact_lock(hashtextextended(v_outlet::text || ':' || p_date::text, 0));
    v_feasible := public.capacity_feasible(v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at,'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at))/60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', v_appt.service_id::text, 'room_type', v_room_type,
        'requested_gender', p_requested_gender, 'pax_index', 0)), 'hard', p_appointment_id);
    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough anonymous capacity for the new time.'; return next; return;
    end if;
    update public.appointments
    set therapist_id = null, room_id = null, room_unit_id = null,
        therapist_assignment_state = 'pending', room_assignment_state = 'pending',
        appointment_date = p_date, start_time = p_start_time, end_time = p_end_time,
        start_at = v_start_at, end_at = v_end_at, assignment_source = v_source,
        requested_therapist_id = p_requested_therapist_id, requested_gender = p_requested_gender, updated_at = now()
    where id = p_appointment_id returning id into appointment_id;
    success := true; error_code := null; error_message := null; return next; return;
  end if;

  select * into v_check from public.check_booking_availability(p_date, p_start_time, p_end_time, p_therapist_id, p_room_id, p_appointment_id);
  if not coalesce(v_check.therapist_available, false) then
    success := false; appointment_id := null; error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.'; return next; return;
  end if;
  if coalesce(v_check.room_full, false) then
    success := false; appointment_id := null; error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.'; return next; return;
  end if;
  update public.appointments
  set therapist_id = p_therapist_id, room_id = p_room_id, appointment_date = p_date,
      start_time = p_start_time, end_time = p_end_time,
      start_at = public.csp_start_at(p_date, p_start_time), end_at = public.csp_end_at(p_date, p_start_time, p_end_time),
      assignment_source = coalesce(p_assignment_source, assignment_source),
      requested_therapist_id = case when p_assignment_source is not null then p_requested_therapist_id else requested_therapist_id end,
      requested_gender = case when p_assignment_source is not null then p_requested_gender else requested_gender end,
      updated_at = now()
  where id = p_appointment_id returning id into appointment_id;
  success := true; error_code := null; error_message := null; return next;
end;
$$;


--
-- Name: update_appointment_with_csp_v2(uuid, uuid, uuid, date, time without time zone, time without time zone, uuid, text, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_appointment_with_csp_v2(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_room_unit_id uuid DEFAULT NULL::uuid, p_assignment_source text DEFAULT NULL::text, p_requested_therapist_id uuid DEFAULT NULL::uuid, p_requested_gender text DEFAULT NULL::text, p_is_provisional boolean DEFAULT NULL::boolean) RETURNS TABLE(success boolean, appointment_id uuid, error_code text, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
declare
  v_result record;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception using errcode = '42501', message = 'Staff access required.';
  end if;

  select *
  into v_result
  from public.update_appointment_with_csp(
    p_appointment_id,
    p_therapist_id,
    p_room_id,
    p_date,
    p_start_time,
    p_end_time,
    p_assignment_source,
    p_requested_therapist_id,
    p_requested_gender,
    p_is_provisional
  );

  if not coalesce(v_result.success, false) then
    return query select
      v_result.success,
      v_result.appointment_id,
      v_result.error_code,
      v_result.error_message;
    return;
  end if;

  if p_room_unit_id is not null then
    update public.appointments
    set room_unit_id = p_room_unit_id,
        updated_at = now()
    where id = p_appointment_id
      and room_id = p_room_id;
    if not found then
      raise exception using
        errcode = '22023',
        message = 'The selected exact room does not belong to this appointment room.';
    end if;
  end if;

  return query select true, p_appointment_id, null::text, null::text;
end;
$$;


--
-- Name: validate_one_based_capacity_requirements_122s(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_one_based_capacity_requirements_122s(p_requirements jsonb) RETURNS void
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare
  v_requirement jsonb;
  v_pax_index integer;
begin
  if jsonb_typeof(p_requirements) is distinct from 'array' then
    raise exception using
      errcode = '22023',
      message =
        'Every pax requirement must use a one-based pax_index starting from 1.';
  end if;

  for v_requirement in
    select value
    from jsonb_array_elements(p_requirements)
  loop
    begin
      v_pax_index := (v_requirement ->> 'pax_index')::integer;
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        raise exception using
          errcode = '22023',
          message =
            'Every pax requirement must use a one-based pax_index starting from 1.';
    end;

    if v_pax_index is null or v_pax_index < 1 then
      raise exception using
        errcode = '22023',
        message =
          'Every pax requirement must use a one-based pax_index starting from 1.';
    end if;
  end loop;
end;
$$;


--
-- Name: write_audit_log(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.write_audit_log() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  old_row jsonb;
  new_row jsonb;
  record_key text;
begin
  old_row := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  new_row := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end;
  record_key := coalesce(new_row ->> 'id', old_row ->> 'id');

  insert into public.audit_log (
    table_name,
    record_id,
    action,
    changed_at,
    changed_by,
    old_data,
    new_data
  )
  values (
    tg_table_name,
    coalesce(record_key, ''),
    tg_op,
    now(),
    auth.uid(),
    old_row,
    new_row
  );

  return coalesce(new, old);
end;
$$;


--
-- Name: appointment_assignment_invalidations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_assignment_invalidations (
    id bigint NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid,
    outlet_id uuid NOT NULL,
    day_of_week integer,
    include_following_day boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT appointment_assignment_invalidations_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6))),
    CONSTRAINT appointment_assignment_invalidations_resource_type_check CHECK ((resource_type = ANY (ARRAY['therapist'::text, 'room'::text, 'service'::text, 'business_hours'::text])))
);


--
-- Name: TABLE appointment_assignment_invalidations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.appointment_assignment_invalidations IS 'Small asynchronous invalidation queue populated by resource and business-hours triggers.';


--
-- Name: appointment_assignment_invalidations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.appointment_assignment_invalidations ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.appointment_assignment_invalidations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: appointment_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid,
    group_name text DEFAULT ''::text NOT NULL,
    pax_count integer DEFAULT 1 NOT NULL,
    appointment_date date NOT NULL,
    status text DEFAULT 'confirmed'::text NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    outlet_id uuid,
    CONSTRAINT appointment_groups_pax_count_check CHECK ((pax_count > 0))
);


--
-- Name: appointment_therapist_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_therapist_allocations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    appointment_id uuid NOT NULL,
    therapist_id uuid NOT NULL,
    commission_share numeric(7,6) NOT NULL,
    commission_amount numeric(12,2) DEFAULT 0 NOT NULL,
    allocation_method text DEFAULT 'full'::text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT appointment_therapist_allocations_allocation_method_check CHECK ((allocation_method = ANY (ARRAY['full'::text, 'early_replacement'::text, 'service_time'::text, 'half'::text, 'manual'::text]))),
    CONSTRAINT appointment_therapist_allocations_commission_amount_check CHECK ((commission_amount >= (0)::numeric)),
    CONSTRAINT appointment_therapist_allocations_commission_share_check CHECK (((commission_share >= (0)::numeric) AND (commission_share <= (1)::numeric)))
);


--
-- Name: appointment_therapist_segments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_therapist_segments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    appointment_id uuid NOT NULL,
    therapist_id uuid NOT NULL,
    started_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone,
    change_type text DEFAULT 'initial'::text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT appointment_therapist_segments_change_type_check CHECK ((change_type = ANY (ARRAY['initial'::text, 'pre_start_replacement'::text, 'early_replacement'::text, 'mid_service_switch'::text]))),
    CONSTRAINT appointment_therapist_segments_check CHECK (((ended_at IS NULL) OR (ended_at >= started_at)))
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    table_name text NOT NULL,
    record_id text NOT NULL,
    action text NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    changed_by uuid,
    old_data jsonb,
    new_data jsonb,
    CONSTRAINT audit_log_action_check CHECK ((action = ANY (ARRAY['INSERT'::text, 'UPDATE'::text, 'DELETE'::text])))
);


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: booking_holds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_holds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    customer_id uuid,
    customer_name text NOT NULL,
    customer_phone text NOT NULL,
    customer_email text NOT NULL,
    therapist_preference text DEFAULT 'none'::text NOT NULL,
    therapist_request text DEFAULT ''::text NOT NULL,
    assigned_therapist_id uuid,
    assigned_room_id uuid,
    service_items jsonb DEFAULT '[]'::jsonb NOT NULL,
    start_at timestamp with time zone NOT NULL,
    end_at timestamp with time zone NOT NULL,
    total_amount numeric(12,2) NOT NULL,
    currency text DEFAULT 'MYR'::text NOT NULL,
    status text DEFAULT 'pending_payment'::text NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL,
    billplz_bill_id text,
    billplz_collection_id text,
    appointment_id uuid,
    notes text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    confirmed_at timestamp with time zone,
    public_token uuid DEFAULT gen_random_uuid() NOT NULL,
    request_fingerprint text DEFAULT ''::text NOT NULL,
    online_booking_service_id uuid,
    deposit_amount numeric(12,2) DEFAULT 0 NOT NULL,
    buffer_before_minutes integer DEFAULT 0 NOT NULL,
    buffer_after_minutes integer DEFAULT 0 NOT NULL,
    hold_kind text DEFAULT 'online_payment'::text NOT NULL,
    draft_session_id text,
    pax_index integer,
    assigned_room_unit_id uuid,
    booking_group_token uuid,
    guest_index integer,
    guest_name text DEFAULT ''::text NOT NULL,
    appointment_group_id uuid,
    billplz_cancelled_at timestamp with time zone,
    billplz_cancellation_attempts integer DEFAULT 0 NOT NULL,
    billplz_cancellation_last_attempt_at timestamp with time zone,
    billplz_cancellation_last_error text,
    billplz_cancellation_claim_token uuid,
    billplz_cancellation_claimed_at timestamp with time zone,
    CONSTRAINT booking_holds_billplz_cancellation_attempts_check CHECK ((billplz_cancellation_attempts >= 0)),
    CONSTRAINT booking_holds_check CHECK ((end_at > start_at)),
    CONSTRAINT booking_holds_hold_kind_check CHECK ((hold_kind = ANY (ARRAY['online_payment'::text, 'staff_walkin_draft'::text]))),
    CONSTRAINT booking_holds_status_check CHECK ((status = ANY (ARRAY['pending_payment'::text, 'paid'::text, 'confirmed'::text, 'expired'::text, 'cancelled'::text, 'payment_failed'::text]))),
    CONSTRAINT booking_holds_therapist_preference_check CHECK ((therapist_preference = ANY (ARRAY['none'::text, 'female'::text, 'male'::text, 'specific'::text]))),
    CONSTRAINT booking_holds_total_amount_check CHECK ((total_amount >= (0)::numeric))
);


--
-- Name: COLUMN booking_holds.billplz_cancelled_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.booking_holds.billplz_cancelled_at IS 'When the unpaid external Billplz bill was successfully deleted.';


--
-- Name: COLUMN booking_holds.billplz_cancellation_last_error; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.booking_holds.billplz_cancellation_last_error IS 'Last Billplz deletion failure; retained until a later retry succeeds.';


--
-- Name: business_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_hours (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    day_of_week integer NOT NULL,
    open_time time without time zone NOT NULL,
    close_time time without time zone NOT NULL,
    is_closed boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT business_hours_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6)))
);


--
-- Name: business_hours_staff_override_archive; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_hours_staff_override_archive (
    id uuid NOT NULL,
    outlet_id uuid NOT NULL,
    therapist_id uuid NOT NULL,
    day_of_week integer NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT business_hours_staff_override_archive_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6)))
);


--
-- Name: business_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_settings (
    id integer DEFAULT 1 NOT NULL,
    open_time time without time zone DEFAULT '09:00:00'::time without time zone NOT NULL,
    close_time time without time zone DEFAULT '21:00:00'::time without time zone NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    outlet_id uuid NOT NULL,
    sst_enabled boolean DEFAULT true NOT NULL,
    sst_pricing_mode text DEFAULT 'exclusive'::text NOT NULL,
    sst_rate_percent numeric(5,2) DEFAULT 6.00 NOT NULL,
    sst_rounding_mode text DEFAULT 'nearest_cent'::text NOT NULL,
    late_grace_minutes integer DEFAULT 15 NOT NULL,
    no_show_threshold_minutes integer DEFAULT 30 NOT NULL,
    auto_extend_late_arrivals boolean DEFAULT true NOT NULL,
    delay_warning_minutes integer DEFAULT 10 NOT NULL,
    billplz_sst_pricing_mode text DEFAULT 'inclusive'::text NOT NULL,
    counter_sst_pricing_mode text DEFAULT 'exclusive'::text NOT NULL,
    capacity_first_enabled boolean DEFAULT false NOT NULL,
    appointment_addon_sst_pricing_mode text DEFAULT 'exclusive'::text NOT NULL,
    CONSTRAINT business_settings_appointment_addon_sst_pricing_mode_check CHECK ((appointment_addon_sst_pricing_mode = ANY (ARRAY['disabled'::text, 'inclusive'::text, 'exclusive'::text]))),
    CONSTRAINT business_settings_billplz_sst_pricing_mode_check CHECK ((billplz_sst_pricing_mode = ANY (ARRAY['inclusive'::text, 'exclusive'::text]))),
    CONSTRAINT business_settings_counter_sst_pricing_mode_check CHECK ((counter_sst_pricing_mode = ANY (ARRAY['inclusive'::text, 'exclusive'::text]))),
    CONSTRAINT business_settings_late_minutes_check CHECK ((((late_grace_minutes >= 0) AND (late_grace_minutes <= 240)) AND ((no_show_threshold_minutes >= 0) AND (no_show_threshold_minutes <= 240)) AND ((delay_warning_minutes >= 0) AND (delay_warning_minutes <= 240)))),
    CONSTRAINT business_settings_sst_pricing_mode_check CHECK ((sst_pricing_mode = ANY (ARRAY['inclusive'::text, 'exclusive'::text]))),
    CONSTRAINT business_settings_sst_rate_check CHECK (((sst_rate_percent >= (0)::numeric) AND (sst_rate_percent <= (100)::numeric))),
    CONSTRAINT business_settings_sst_rounding_mode_check CHECK ((sst_rounding_mode = ANY (ARRAY['nearest_cent'::text, 'nearest_5_sen'::text, 'nearest_10_sen'::text, 'floor_cent'::text, 'ceil_cent'::text])))
);


--
-- Name: COLUMN business_settings.capacity_first_enabled; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.business_settings.capacity_first_enabled IS 'Dormant capacity-first rollback flag. MVP concrete locking keeps this false for both outlets.';


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    phone text,
    email text,
    gender text,
    date_of_birth date,
    join_date date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    outlet_id uuid NOT NULL
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    type text NOT NULL,
    title text NOT NULL,
    body text DEFAULT ''::text NOT NULL,
    appointment_id uuid,
    appointment_group_id uuid,
    transaction_id uuid,
    booking_hold_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    read_at timestamp with time zone,
    CONSTRAINT notifications_type_check CHECK ((type = ANY (ARRAY['new_online_appointment'::text, 'appointment_checked_in'::text, 'online_payment_received'::text, 'payment_received'::text, 'payment_failed'::text, 'payment_expired'::text, 'appointment_cancelled'::text, 'appointment_voided'::text, 'refund_completed'::text, 'transaction_review'::text])))
);


--
-- Name: online_booking_closures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.online_booking_closures (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    closure_date date NOT NULL,
    is_full_day boolean DEFAULT true NOT NULL,
    start_time time without time zone,
    end_time time without time zone,
    internal_reason text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT online_booking_closures_check CHECK (((is_full_day AND (start_time IS NULL) AND (end_time IS NULL)) OR ((NOT is_full_day) AND (start_time IS NOT NULL) AND (end_time IS NOT NULL) AND (start_time <> end_time))))
);


--
-- Name: online_booking_outlet_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.online_booking_outlet_settings (
    outlet_id uuid NOT NULL,
    online_booking_enabled boolean DEFAULT false NOT NULL,
    public_open_time time without time zone DEFAULT '09:00:00'::time without time zone NOT NULL,
    public_close_time time without time zone DEFAULT '21:00:00'::time without time zone NOT NULL,
    slot_interval_minutes integer DEFAULT 30 NOT NULL,
    minimum_advance_minutes integer DEFAULT 60 NOT NULL,
    maximum_booking_days integer DEFAULT 7 NOT NULL,
    same_day_booking_allowed boolean DEFAULT false NOT NULL,
    customer_therapist_selection_allowed boolean DEFAULT true NOT NULL,
    public_therapist_names_allowed boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT online_booking_outlet_settings_maximum_booking_days_check CHECK (((maximum_booking_days >= 1) AND (maximum_booking_days <= 90))),
    CONSTRAINT online_booking_outlet_settings_minimum_advance_minutes_check CHECK ((minimum_advance_minutes >= 0)),
    CONSTRAINT online_booking_outlet_settings_slot_interval_minutes_check CHECK (((slot_interval_minutes >= 5) AND (slot_interval_minutes <= 120)))
);


--
-- Name: online_booking_service_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.online_booking_service_hours (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    online_booking_service_id uuid NOT NULL,
    outlet_id uuid NOT NULL,
    day_of_week integer NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT online_booking_service_hours_check CHECK ((end_time <> start_time)),
    CONSTRAINT online_booking_service_hours_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6)))
);


--
-- Name: online_booking_service_rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.online_booking_service_rooms (
    online_booking_service_id uuid NOT NULL,
    room_id uuid NOT NULL,
    outlet_id uuid NOT NULL
);


--
-- Name: online_booking_services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.online_booking_services (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    service_id uuid NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    public_name text DEFAULT ''::text NOT NULL,
    short_description text DEFAULT ''::text NOT NULL,
    public_image_url text DEFAULT ''::text NOT NULL,
    display_price numeric(12,2) DEFAULT 0 NOT NULL,
    deposit_amount numeric(12,2) DEFAULT 0 NOT NULL,
    show_price boolean DEFAULT true NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    buffer_before_minutes integer DEFAULT 0 NOT NULL,
    buffer_after_minutes integer DEFAULT 0 NOT NULL,
    maximum_concurrent_bookings integer DEFAULT 3 NOT NULL,
    use_custom_hours boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT online_booking_services_buffer_after_minutes_check CHECK (((buffer_after_minutes >= 0) AND (buffer_after_minutes <= 240))),
    CONSTRAINT online_booking_services_buffer_before_minutes_check CHECK (((buffer_before_minutes >= 0) AND (buffer_before_minutes <= 240))),
    CONSTRAINT online_booking_services_check CHECK ((deposit_amount <= display_price)),
    CONSTRAINT online_booking_services_deposit_amount_check CHECK ((deposit_amount >= (0)::numeric)),
    CONSTRAINT online_booking_services_display_price_check CHECK ((display_price >= (0)::numeric)),
    CONSTRAINT online_booking_services_maximum_concurrent_bookings_check CHECK (((maximum_concurrent_bookings >= 1) AND (maximum_concurrent_bookings <= 100)))
);


--
-- Name: outlets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outlets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    address text DEFAULT ''::text NOT NULL,
    phone text DEFAULT ''::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    role public.user_role DEFAULT 'staff'::public.user_role NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid
);


--
-- Name: room_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.room_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    zone_id uuid NOT NULL,
    outlet_id uuid NOT NULL,
    name text NOT NULL,
    unit_number integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT room_units_unit_number_check CHECK ((unit_number > 0))
);


--
-- Name: rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rooms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    type public.room_type NOT NULL,
    floor public.room_floor NOT NULL,
    total_slots integer DEFAULT 1 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    room_type text DEFAULT 'body_room'::text NOT NULL,
    equipment text DEFAULT ''::text NOT NULL,
    outlet_id uuid NOT NULL,
    allocation_mode text DEFAULT 'capacity'::text NOT NULL,
    CONSTRAINT rooms_allocation_mode_check CHECK ((allocation_mode = ANY (ARRAY['capacity'::text, 'specific_room'::text]))),
    CONSTRAINT rooms_specific_allocation_body_only_check CHECK (((allocation_mode = 'capacity'::text) OR (lower(COALESCE(room_type, ''::text)) = 'body_room'::text)))
);


--
-- Name: service_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.services (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    duration integer NOT NULL,
    price numeric(10,2) DEFAULT 0 NOT NULL,
    room_type public.room_type NOT NULL,
    category text DEFAULT 'Services'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    icon_emoji text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    therapist_commission numeric DEFAULT 0 NOT NULL,
    counter_commission numeric DEFAULT 0 NOT NULL,
    image_url text DEFAULT ''::text NOT NULL,
    outlet_id uuid NOT NULL,
    service_description text DEFAULT ''::text NOT NULL,
    buffer_after_minutes integer DEFAULT 0 NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    CONSTRAINT services_buffer_after_minutes_check CHECK (((buffer_after_minutes >= 0) AND (buffer_after_minutes <= 240))),
    CONSTRAINT services_duration_check CHECK ((duration > 0))
);


--
-- Name: COLUMN services.display_order; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.services.display_order IS 'Admin-defined ordering used by service management, appointments, and walk-in ordering.';


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    id text DEFAULT 'business'::text NOT NULL,
    business_name text NOT NULL,
    location text,
    logo_url text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid
);


--
-- Name: therapist_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.therapist_queue (
    outlet_id uuid NOT NULL,
    queue_date date NOT NULL,
    therapist_id uuid NOT NULL,
    queue_position integer NOT NULL,
    turn_consumed_at timestamp with time zone,
    protected_turn_owed boolean DEFAULT false NOT NULL,
    protected_turn_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: COLUMN therapist_queue.queue_position; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.therapist_queue.queue_position IS 'Current base order for this outlet business date; consumed turns rotate to the bottom.';


--
-- Name: therapist_queue_day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.therapist_queue_day (
    outlet_id uuid NOT NULL,
    queue_date date NOT NULL,
    starter_therapist_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    first_turn_consumed_at timestamp with time zone,
    is_manual_override boolean DEFAULT false NOT NULL,
    changed_by uuid,
    changed_at timestamp with time zone,
    override_reason text,
    CONSTRAINT therapist_queue_day_override_reason_length_check CHECK (((override_reason IS NULL) OR (char_length(override_reason) <= 500)))
);


--
-- Name: COLUMN therapist_queue_day.first_turn_consumed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.therapist_queue_day.first_turn_consumed_at IS 'First queue turn consumed on this business date; remains set after manual resets.';


--
-- Name: COLUMN therapist_queue_day.is_manual_override; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.therapist_queue_day.is_manual_override IS 'Whether today''s stored starter was manually selected instead of automatic.';


--
-- Name: therapist_unavailability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.therapist_unavailability (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    therapist_id uuid NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    internal_reason text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT therapist_unavailability_check CHECK ((ends_at > starts_at))
);


--
-- Name: therapist_working_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.therapist_working_hours (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    outlet_id uuid NOT NULL,
    therapist_id uuid NOT NULL,
    day_of_week integer NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    is_custom boolean DEFAULT false NOT NULL,
    CONSTRAINT therapist_working_hours_check CHECK ((end_time <> start_time)),
    CONSTRAINT therapist_working_hours_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6)))
);


--
-- Name: therapists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.therapists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    phone text,
    gender text,
    specialization text[] DEFAULT '{}'::text[],
    employment_type text,
    join_date date,
    availability_status boolean DEFAULT true NOT NULL,
    busy_until time without time zone,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    role text DEFAULT 'Therapist'::text NOT NULL,
    service_commissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    profile_image_url text DEFAULT ''::text NOT NULL,
    outlet_id uuid NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    commission_overrides jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: COLUMN therapists.service_commissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.therapists.service_commissions IS 'Deprecated as of 2026-07-28 and kept empty. Scheduling functions still read a non-empty value as an exclusive service whitelist, so do not write rate overrides here -- use commission_overrides.';


--
-- Name: COLUMN therapists.display_order; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.therapists.display_order IS 'Admin-defined ordering used by staff management, booking, and timetable staff lists.';


--
-- Name: COLUMN therapists.commission_overrides; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.therapists.commission_overrides IS 'Per-service commission rate overrides {service_id: percent}. Rates only -- this NEVER restricts which services a therapist can perform.';


--
-- Name: transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    appointment_id uuid,
    customer_id uuid,
    service_price numeric(10,2) DEFAULT 0 NOT NULL,
    sst_amount numeric(10,2) DEFAULT 0 NOT NULL,
    total_amount numeric(10,2) DEFAULT 0 NOT NULL,
    payment_method public.payment_method NOT NULL,
    payment_status public.payment_status DEFAULT 'paid'::public.payment_status NOT NULL,
    receipt_number text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    notes text DEFAULT ''::text NOT NULL,
    item_count integer DEFAULT 1 NOT NULL,
    customer_name text DEFAULT ''::text NOT NULL,
    customer_phone text DEFAULT ''::text NOT NULL,
    service_id uuid,
    service_name text DEFAULT ''::text NOT NULL,
    therapist_id uuid,
    therapist_name text DEFAULT ''::text NOT NULL,
    room_id uuid,
    room_name text DEFAULT ''::text NOT NULL,
    service_items jsonb DEFAULT '[]'::jsonb NOT NULL,
    counter_staff_id uuid,
    counter_staff_name text,
    therapist_commission_amount numeric DEFAULT 0 NOT NULL,
    counter_commission_amount numeric DEFAULT 0 NOT NULL,
    appointment_group_id uuid,
    source text DEFAULT ''::text NOT NULL,
    outlet_id uuid NOT NULL,
    room_unit_id uuid,
    room_unit_name text DEFAULT ''::text NOT NULL
);


--
-- Name: appointment_assignment_invalidations appointment_assignment_invalidations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_assignment_invalidations
    ADD CONSTRAINT appointment_assignment_invalidations_pkey PRIMARY KEY (id);


--
-- Name: appointment_groups appointment_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_groups
    ADD CONSTRAINT appointment_groups_pkey PRIMARY KEY (id);


--
-- Name: appointment_therapist_allocations appointment_therapist_allocatio_appointment_id_therapist_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_therapist_allocations
    ADD CONSTRAINT appointment_therapist_allocatio_appointment_id_therapist_id_key UNIQUE (appointment_id, therapist_id);


--
-- Name: appointment_therapist_allocations appointment_therapist_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_therapist_allocations
    ADD CONSTRAINT appointment_therapist_allocations_pkey PRIMARY KEY (id);


--
-- Name: appointment_therapist_segments appointment_therapist_segments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_therapist_segments
    ADD CONSTRAINT appointment_therapist_segments_pkey PRIMARY KEY (id);


--
-- Name: appointments appointments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: booking_holds booking_holds_billplz_bill_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_billplz_bill_id_key UNIQUE (billplz_bill_id);


--
-- Name: booking_holds booking_holds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_pkey PRIMARY KEY (id);


--
-- Name: business_hours business_hours_outlet_id_day_of_week_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours
    ADD CONSTRAINT business_hours_outlet_id_day_of_week_key UNIQUE (outlet_id, day_of_week);


--
-- Name: business_hours business_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours
    ADD CONSTRAINT business_hours_pkey PRIMARY KEY (id);


--
-- Name: business_hours_staff_override_archive business_hours_staff_override_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours_staff_override_archive
    ADD CONSTRAINT business_hours_staff_override_archive_pkey PRIMARY KEY (id);


--
-- Name: business_hours_staff_override_archive business_hours_staff_override_therapist_id_day_of_week_star_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours_staff_override_archive
    ADD CONSTRAINT business_hours_staff_override_therapist_id_day_of_week_star_key UNIQUE (therapist_id, day_of_week, start_time);


--
-- Name: business_settings business_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_settings
    ADD CONSTRAINT business_settings_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: online_booking_closures online_booking_closures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_closures
    ADD CONSTRAINT online_booking_closures_pkey PRIMARY KEY (id);


--
-- Name: online_booking_outlet_settings online_booking_outlet_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_outlet_settings
    ADD CONSTRAINT online_booking_outlet_settings_pkey PRIMARY KEY (outlet_id);


--
-- Name: online_booking_service_hours online_booking_service_hours_online_booking_service_id_day__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_hours
    ADD CONSTRAINT online_booking_service_hours_online_booking_service_id_day__key UNIQUE (online_booking_service_id, day_of_week, start_time);


--
-- Name: online_booking_service_hours online_booking_service_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_hours
    ADD CONSTRAINT online_booking_service_hours_pkey PRIMARY KEY (id);


--
-- Name: online_booking_service_rooms online_booking_service_rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_rooms
    ADD CONSTRAINT online_booking_service_rooms_pkey PRIMARY KEY (online_booking_service_id, room_id);


--
-- Name: online_booking_services online_booking_services_outlet_id_service_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_services
    ADD CONSTRAINT online_booking_services_outlet_id_service_id_key UNIQUE (outlet_id, service_id);


--
-- Name: online_booking_services online_booking_services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_services
    ADD CONSTRAINT online_booking_services_pkey PRIMARY KEY (id);


--
-- Name: outlets outlets_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outlets
    ADD CONSTRAINT outlets_code_key UNIQUE (code);


--
-- Name: outlets outlets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outlets
    ADD CONSTRAINT outlets_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_email_key UNIQUE (email);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: room_units room_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_units
    ADD CONSTRAINT room_units_pkey PRIMARY KEY (id);


--
-- Name: room_units room_units_zone_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_units
    ADD CONSTRAINT room_units_zone_id_name_key UNIQUE (zone_id, name);


--
-- Name: room_units room_units_zone_id_unit_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_units
    ADD CONSTRAINT room_units_zone_id_unit_number_key UNIQUE (zone_id, unit_number);


--
-- Name: rooms rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_pkey PRIMARY KEY (id);


--
-- Name: service_categories service_categories_outlet_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_categories
    ADD CONSTRAINT service_categories_outlet_id_code_key UNIQUE (outlet_id, code);


--
-- Name: service_categories service_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_categories
    ADD CONSTRAINT service_categories_pkey PRIMARY KEY (id);


--
-- Name: services services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_pkey PRIMARY KEY (id);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);


--
-- Name: therapist_queue_day therapist_queue_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_queue_day
    ADD CONSTRAINT therapist_queue_day_pkey PRIMARY KEY (outlet_id, queue_date);


--
-- Name: therapist_queue therapist_queue_day_position_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_queue
    ADD CONSTRAINT therapist_queue_day_position_unique UNIQUE (outlet_id, queue_date, queue_position) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: therapist_queue therapist_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_queue
    ADD CONSTRAINT therapist_queue_pkey PRIMARY KEY (outlet_id, queue_date, therapist_id);


--
-- Name: therapist_unavailability therapist_unavailability_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_unavailability
    ADD CONSTRAINT therapist_unavailability_pkey PRIMARY KEY (id);


--
-- Name: therapist_working_hours therapist_working_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_working_hours
    ADD CONSTRAINT therapist_working_hours_pkey PRIMARY KEY (id);


--
-- Name: therapist_working_hours therapist_working_hours_therapist_id_day_of_week_start_time_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_working_hours
    ADD CONSTRAINT therapist_working_hours_therapist_id_day_of_week_start_time_key UNIQUE (therapist_id, day_of_week, start_time);


--
-- Name: therapists therapists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapists
    ADD CONSTRAINT therapists_pkey PRIMARY KEY (id);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);


--
-- Name: transactions transactions_receipt_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_receipt_number_key UNIQUE (receipt_number);


--
-- Name: appointments valid_appointment_time; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.appointments
    ADD CONSTRAINT valid_appointment_time CHECK (((appointment_date IS NULL) OR (start_time IS NULL) OR (end_time IS NULL) OR (public.csp_end_at(appointment_date, start_time, end_time) > public.csp_start_at(appointment_date, start_time)))) NOT VALID;


--
-- Name: appointment_groups_outlet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointment_groups_outlet_id_idx ON public.appointment_groups USING btree (outlet_id);


--
-- Name: appointment_therapist_allocations_appointment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointment_therapist_allocations_appointment_idx ON public.appointment_therapist_allocations USING btree (appointment_id);


--
-- Name: appointment_therapist_allocations_therapist_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointment_therapist_allocations_therapist_idx ON public.appointment_therapist_allocations USING btree (therapist_id, appointment_id);


--
-- Name: appointment_therapist_segments_appointment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointment_therapist_segments_appointment_idx ON public.appointment_therapist_segments USING btree (appointment_id, started_at);


--
-- Name: appointment_therapist_segments_one_open_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX appointment_therapist_segments_one_open_idx ON public.appointment_therapist_segments USING btree (appointment_id) WHERE (ended_at IS NULL);


--
-- Name: appointment_therapist_segments_therapist_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointment_therapist_segments_therapist_idx ON public.appointment_therapist_segments USING btree (therapist_id, started_at, ended_at);


--
-- Name: appointments_assignment_reconcile_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointments_assignment_reconcile_idx ON public.appointments USING btree (outlet_id, appointment_date, therapist_assignment_state, room_assignment_state) WHERE ((status = ANY (ARRAY['pending'::public.appointment_status, 'confirmed'::public.appointment_status])) AND (actual_started_at IS NULL));


--
-- Name: appointments_assignment_recovery_v116_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointments_assignment_recovery_v116_idx ON public.appointments USING btree (appointment_date, start_time, assignment_next_retry_at) WHERE ((actual_started_at IS NULL) AND (status = ANY (ARRAY['pending'::public.appointment_status, 'confirmed'::public.appointment_status])) AND (type = 'appointment'::public.appointment_type));


--
-- Name: appointments_outlet_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointments_outlet_date_idx ON public.appointments USING btree (outlet_id, appointment_date);


--
-- Name: appointments_room_unit_schedule_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointments_room_unit_schedule_idx ON public.appointments USING btree (room_unit_id, appointment_date, start_time, end_time) WHERE (room_unit_id IS NOT NULL);


--
-- Name: assignment_invalidations_pending_v116_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX assignment_invalidations_pending_v116_uidx ON public.appointment_assignment_invalidations USING btree (resource_type, COALESCE(resource_id, '00000000-0000-0000-0000-000000000000'::uuid), outlet_id, COALESCE(day_of_week, '-1'::integer), include_following_day);


--
-- Name: booking_holds_active_resources_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_active_resources_idx ON public.booking_holds USING btree (outlet_id, assigned_therapist_id, assigned_room_id, start_at, end_at) WHERE (status = 'pending_payment'::text);


--
-- Name: booking_holds_billplz_cleanup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_billplz_cleanup_idx ON public.booking_holds USING btree (status, expires_at, billplz_cancellation_claimed_at) WHERE ((billplz_bill_id IS NOT NULL) AND (billplz_cancelled_at IS NULL));


--
-- Name: booking_holds_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_expiry_idx ON public.booking_holds USING btree (expires_at) WHERE (status = 'pending_payment'::text);


--
-- Name: booking_holds_group_token_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_group_token_idx ON public.booking_holds USING btree (booking_group_token, guest_index);


--
-- Name: booking_holds_online_service_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_online_service_idx ON public.booking_holds USING btree (online_booking_service_id, start_at, end_at);


--
-- Name: booking_holds_outlet_schedule_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_outlet_schedule_idx ON public.booking_holds USING btree (outlet_id, start_at, end_at, status);


--
-- Name: booking_holds_public_token_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX booking_holds_public_token_uidx ON public.booking_holds USING btree (public_token);


--
-- Name: booking_holds_request_fingerprint_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_request_fingerprint_idx ON public.booking_holds USING btree (request_fingerprint, created_at) WHERE (request_fingerprint <> ''::text);


--
-- Name: booking_holds_room_unit_schedule_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_room_unit_schedule_idx ON public.booking_holds USING btree (assigned_room_unit_id, start_at, end_at, expires_at) WHERE ((assigned_room_unit_id IS NOT NULL) AND (status = 'pending_payment'::text));


--
-- Name: booking_holds_staff_draft_pax_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX booking_holds_staff_draft_pax_idx ON public.booking_holds USING btree (draft_session_id, pax_index) WHERE ((hold_kind = 'staff_walkin_draft'::text) AND (status = 'pending_payment'::text));


--
-- Name: booking_holds_staff_resource_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_holds_staff_resource_idx ON public.booking_holds USING btree (outlet_id, assigned_therapist_id, start_at, end_at) WHERE (status = 'pending_payment'::text);


--
-- Name: business_hours_outlet_day_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX business_hours_outlet_day_idx ON public.business_hours USING btree (outlet_id, day_of_week);


--
-- Name: business_settings_outlet_id_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX business_settings_outlet_id_uidx ON public.business_settings USING btree (outlet_id);


--
-- Name: customers_outlet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customers_outlet_id_idx ON public.customers USING btree (outlet_id);


--
-- Name: idx_appointment_groups_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointment_groups_date ON public.appointment_groups USING btree (appointment_date, status);


--
-- Name: idx_appointments_csp_room; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_csp_room ON public.appointments USING btree (appointment_date, room_id, status, start_time, end_time);


--
-- Name: idx_appointments_csp_room_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_csp_room_at ON public.appointments USING btree (room_id, start_at, end_at) WHERE (room_id IS NOT NULL);


--
-- Name: idx_appointments_csp_therapist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_csp_therapist ON public.appointments USING btree (appointment_date, therapist_id, status, start_time, end_time);


--
-- Name: idx_appointments_csp_therapist_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_csp_therapist_at ON public.appointments USING btree (therapist_id, start_at, end_at) WHERE (therapist_id IS NOT NULL);


--
-- Name: idx_appointments_customer_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_customer_date ON public.appointments USING btree (customer_id, appointment_date DESC);


--
-- Name: idx_appointments_date_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_date_start ON public.appointments USING btree (appointment_date, start_time);


--
-- Name: idx_appointments_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_group_id ON public.appointments USING btree (appointment_group_id);


--
-- Name: idx_appointments_room_date_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_room_date_start ON public.appointments USING btree (room_id, appointment_date, start_time);


--
-- Name: idx_appointments_status_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_status_date ON public.appointments USING btree (status, appointment_date);


--
-- Name: idx_appointments_therapist_date_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_therapist_date_start ON public.appointments USING btree (therapist_id, appointment_date, start_time);


--
-- Name: idx_transactions_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_created_at ON public.transactions USING btree (created_at DESC);


--
-- Name: notifications_feed_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_feed_idx ON public.notifications USING btree (outlet_id, created_at DESC);


--
-- Name: notifications_hold_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_hold_idx ON public.notifications USING btree (booking_hold_id) WHERE (booking_hold_id IS NOT NULL);


--
-- Name: notifications_unread_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_unread_idx ON public.notifications USING btree (outlet_id) WHERE (read_at IS NULL);


--
-- Name: online_booking_closures_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX online_booking_closures_date_idx ON public.online_booking_closures USING btree (outlet_id, closure_date);


--
-- Name: online_booking_services_public_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX online_booking_services_public_idx ON public.online_booking_services USING btree (outlet_id, enabled, display_order);


--
-- Name: room_units_outlet_zone_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX room_units_outlet_zone_idx ON public.room_units USING btree (outlet_id, zone_id, is_active, unit_number);


--
-- Name: rooms_outlet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rooms_outlet_id_idx ON public.rooms USING btree (outlet_id);


--
-- Name: services_outlet_category_display_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX services_outlet_category_display_order_idx ON public.services USING btree (outlet_id, category, display_order, name);


--
-- Name: services_outlet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX services_outlet_id_idx ON public.services USING btree (outlet_id);


--
-- Name: therapist_queue_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX therapist_queue_order_idx ON public.therapist_queue USING btree (outlet_id, queue_date, protected_turn_owed, turn_consumed_at, queue_position);


--
-- Name: therapist_unavailability_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX therapist_unavailability_lookup_idx ON public.therapist_unavailability USING btree (outlet_id, therapist_id, starts_at, ends_at);


--
-- Name: therapist_working_hours_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX therapist_working_hours_lookup_idx ON public.therapist_working_hours USING btree (outlet_id, therapist_id, day_of_week);


--
-- Name: therapists_outlet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX therapists_outlet_id_idx ON public.therapists USING btree (outlet_id);


--
-- Name: therapists_outlet_role_display_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX therapists_outlet_role_display_order_idx ON public.therapists USING btree (outlet_id, role, display_order, name);


--
-- Name: therapists_outlet_rotation_number_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX therapists_outlet_rotation_number_uidx ON public.therapists USING btree (outlet_id, display_order) WHERE (lower(role) = 'therapist'::text);


--
-- Name: INDEX therapists_outlet_rotation_number_uidx; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON INDEX public.therapists_outlet_rotation_number_uidx IS 'Ensures each therapist has one unique rotation number within an outlet.';


--
-- Name: transactions_appointment_group_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX transactions_appointment_group_id_idx ON public.transactions USING btree (appointment_group_id);


--
-- Name: transactions_counter_staff_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX transactions_counter_staff_id_idx ON public.transactions USING btree (counter_staff_id);


--
-- Name: transactions_one_primary_bill_per_appointment_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX transactions_one_primary_bill_per_appointment_uidx ON public.transactions USING btree (appointment_id) WHERE ((appointment_id IS NOT NULL) AND (COALESCE(source, ''::text) <> 'appointment_addon'::text));


--
-- Name: transactions_one_primary_bill_per_group_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX transactions_one_primary_bill_per_group_uidx ON public.transactions USING btree (appointment_group_id) WHERE ((appointment_group_id IS NOT NULL) AND (COALESCE(source, ''::text) <> 'appointment_addon'::text));


--
-- Name: transactions_online_booking_appointment_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX transactions_online_booking_appointment_uidx ON public.transactions USING btree (appointment_id) WHERE ((source = 'online_booking'::text) AND (appointment_id IS NOT NULL));


--
-- Name: transactions_outlet_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX transactions_outlet_created_idx ON public.transactions USING btree (outlet_id, created_at);


--
-- Name: transactions_room_unit_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX transactions_room_unit_id_idx ON public.transactions USING btree (room_unit_id) WHERE (room_unit_id IS NOT NULL);


--
-- Name: transactions_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX transactions_source_idx ON public.transactions USING btree (source);


--
-- Name: appointments appointment_actual_start_consumes_queue; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointment_actual_start_consumes_queue AFTER INSERT OR UPDATE OF actual_started_at ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.consume_queue_on_appointment_start();


--
-- Name: appointment_therapist_allocations appointment_therapist_allocations_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointment_therapist_allocations_set_audit_fields BEFORE INSERT OR UPDATE ON public.appointment_therapist_allocations FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: appointment_therapist_allocations appointment_therapist_allocations_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointment_therapist_allocations_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.appointment_therapist_allocations FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: appointment_therapist_segments appointment_therapist_segments_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointment_therapist_segments_set_audit_fields BEFORE INSERT OR UPDATE ON public.appointment_therapist_segments FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: appointment_therapist_segments appointment_therapist_segments_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointment_therapist_segments_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.appointment_therapist_segments FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: appointments appointments_apply_service_buffer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_apply_service_buffer BEFORE INSERT OR UPDATE OF service_id ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.apply_appointment_service_buffer();


--
-- Name: appointments appointments_assign_room_unit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_assign_room_unit BEFORE INSERT OR UPDATE OF room_id, room_unit_id, appointment_date, start_time, end_time, buffer_after_minutes, status ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.assign_appointment_room_unit();


--
-- Name: appointments appointments_enforce_outlet; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_enforce_outlet BEFORE INSERT OR UPDATE OF outlet_id, customer_id, therapist_id, room_id, service_id ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.enforce_appointment_outlet_consistency();


--
-- Name: appointments appointments_initialize_therapist_allocation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_initialize_therapist_allocation AFTER UPDATE OF therapist_id, actual_started_at, status ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.initialize_appointment_therapist_allocation();


--
-- Name: appointments appointments_no_future_progress; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_no_future_progress BEFORE INSERT OR UPDATE OF status ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.enforce_no_future_service_progress();


--
-- Name: appointments appointments_normalize_assignment_states; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_normalize_assignment_states BEFORE INSERT OR UPDATE OF therapist_id, room_id, assignment_source, therapist_assignment_state, room_assignment_state, actual_started_at, status, type ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.normalize_appointment_assignment_states();


--
-- Name: appointments appointments_notify_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_notify_event AFTER UPDATE OF status, payment_status, actual_started_at ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.notify_appointment_event();


--
-- Name: appointments appointments_prevent_resource_overlap; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_prevent_resource_overlap BEFORE INSERT OR UPDATE OF appointment_date, start_time, end_time, start_at, end_at, therapist_id, room_id, status, buffer_after_minutes ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.prevent_appointment_resource_overlap();


--
-- Name: appointments appointments_project_end_on_actual_start; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_project_end_on_actual_start BEFORE INSERT OR UPDATE OF actual_started_at ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.project_appointment_end_on_actual_start();


--
-- Name: appointments appointments_request_assignment_reconcile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_request_assignment_reconcile AFTER INSERT OR UPDATE OF appointment_date, start_time, end_time, therapist_id, room_id, status ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.request_appointment_assignment_reconcile();


--
-- Name: appointments appointments_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_set_audit_fields BEFORE INSERT OR UPDATE ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: appointments appointments_set_booked_snapshot; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_set_booked_snapshot BEFORE INSERT ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.set_appointment_booked_snapshot();


--
-- Name: appointments appointments_set_schedule_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_set_schedule_at BEFORE INSERT OR UPDATE OF appointment_date, start_time, end_time ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.set_appointment_schedule_at();


--
-- Name: appointments appointments_sync_completed_commission; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_sync_completed_commission AFTER UPDATE OF status ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.sync_completed_appointment_commission();


--
-- Name: appointments appointments_sync_group_outlet; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_sync_group_outlet AFTER INSERT OR UPDATE OF appointment_group_id, outlet_id ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.sync_appointment_group_outlet();


--
-- Name: appointments appointments_walkin_future_capacity_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_walkin_future_capacity_guard BEFORE INSERT ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.enforce_walkin_future_capacity();


--
-- Name: appointments appointments_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointments_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: booking_holds booking_holds_assign_room_unit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER booking_holds_assign_room_unit BEFORE INSERT OR UPDATE OF assigned_room_id, assigned_room_unit_id, start_at, end_at, buffer_after_minutes, status ON public.booking_holds FOR EACH ROW EXECUTE FUNCTION public.assign_booking_hold_room_unit();


--
-- Name: booking_holds booking_holds_enforce_outlet; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER booking_holds_enforce_outlet BEFORE INSERT OR UPDATE OF outlet_id, customer_id, assigned_therapist_id, assigned_room_id, appointment_id ON public.booking_holds FOR EACH ROW EXECUTE FUNCTION public.enforce_booking_hold_outlet_consistency();


--
-- Name: booking_holds booking_holds_notify_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER booking_holds_notify_event AFTER UPDATE OF status, appointment_id, appointment_group_id ON public.booking_holds FOR EACH ROW EXECUTE FUNCTION public.notify_booking_hold_event();


--
-- Name: booking_holds booking_holds_require_concrete_resources; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER booking_holds_require_concrete_resources BEFORE INSERT OR UPDATE OF status, expires_at, assigned_therapist_id, assigned_room_id, assigned_room_unit_id, start_at, end_at, buffer_after_minutes ON public.booking_holds FOR EACH ROW EXECUTE FUNCTION public.enforce_online_hold_concrete_resources();


--
-- Name: business_hours business_hours_begin_staff_sync_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER business_hours_begin_staff_sync_insert BEFORE INSERT ON public.business_hours FOR EACH ROW EXECUTE FUNCTION public.begin_business_hours_staff_sync();


--
-- Name: business_hours business_hours_begin_staff_sync_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER business_hours_begin_staff_sync_update BEFORE UPDATE OF open_time, close_time, is_closed ON public.business_hours FOR EACH ROW WHEN (((old.open_time IS DISTINCT FROM new.open_time) OR (old.close_time IS DISTINCT FROM new.close_time) OR (old.is_closed IS DISTINCT FROM new.is_closed))) EXECUTE FUNCTION public.begin_business_hours_staff_sync();


--
-- Name: business_hours business_hours_queue_reconcile_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER business_hours_queue_reconcile_insert AFTER INSERT ON public.business_hours FOR EACH ROW EXECUTE FUNCTION public.queue_business_hours_assignment_reconcile();


--
-- Name: business_hours business_hours_queue_reconcile_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER business_hours_queue_reconcile_update AFTER UPDATE OF open_time, close_time, is_closed ON public.business_hours FOR EACH ROW WHEN (((old.open_time IS DISTINCT FROM new.open_time) OR (old.close_time IS DISTINCT FROM new.close_time) OR (old.is_closed IS DISTINCT FROM new.is_closed))) EXECUTE FUNCTION public.queue_business_hours_assignment_reconcile();


--
-- Name: business_hours business_hours_sync_staff_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER business_hours_sync_staff_insert AFTER INSERT ON public.business_hours FOR EACH ROW EXECUTE FUNCTION public.sync_staff_hours_from_business_hours();


--
-- Name: business_hours business_hours_sync_staff_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER business_hours_sync_staff_update AFTER UPDATE OF open_time, close_time, is_closed ON public.business_hours FOR EACH ROW WHEN (((old.open_time IS DISTINCT FROM new.open_time) OR (old.close_time IS DISTINCT FROM new.close_time) OR (old.is_closed IS DISTINCT FROM new.is_closed))) EXECUTE FUNCTION public.sync_staff_hours_from_business_hours();


--
-- Name: business_hours business_hours_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER business_hours_touch_updated_at BEFORE UPDATE ON public.business_hours FOR EACH ROW EXECUTE FUNCTION public.touch_business_hours_updated_at();


--
-- Name: booking_holds clamp_booking_hold_expiry_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER clamp_booking_hold_expiry_trigger BEFORE INSERT ON public.booking_holds FOR EACH ROW EXECUTE FUNCTION public.clamp_booking_hold_expiry();


--
-- Name: customers customers_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customers_set_audit_fields BEFORE INSERT OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: customers customers_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customers_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: appointments online_appointment_conversion_requires_locked_resources; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER online_appointment_conversion_requires_locked_resources BEFORE INSERT ON public.appointments FOR EACH ROW WHEN ((new.online_booking_service_id IS NOT NULL)) EXECUTE FUNCTION public.enforce_online_appointment_conversion();


--
-- Name: online_booking_service_hours online_booking_service_hours_outlet_match; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER online_booking_service_hours_outlet_match BEFORE INSERT OR UPDATE ON public.online_booking_service_hours FOR EACH ROW EXECUTE FUNCTION public.enforce_online_booking_outlet_match();


--
-- Name: online_booking_service_rooms online_booking_service_rooms_outlet_match; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER online_booking_service_rooms_outlet_match BEFORE INSERT OR UPDATE ON public.online_booking_service_rooms FOR EACH ROW EXECUTE FUNCTION public.enforce_online_booking_outlet_match();


--
-- Name: online_booking_services online_booking_services_outlet_match; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER online_booking_services_outlet_match BEFORE INSERT OR UPDATE ON public.online_booking_services FOR EACH ROW EXECUTE FUNCTION public.enforce_online_booking_outlet_match();


--
-- Name: online_booking_services online_services_enforce_buffer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER online_services_enforce_buffer BEFORE INSERT OR UPDATE OF service_id, buffer_before_minutes, buffer_after_minutes ON public.online_booking_services FOR EACH ROW EXECUTE FUNCTION public.enforce_online_service_buffer();


--
-- Name: profiles profiles_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER profiles_set_audit_fields BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: profiles profiles_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER profiles_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: rooms rooms_reconcile_appointment_holds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rooms_reconcile_appointment_holds AFTER UPDATE OF is_active, room_type, total_slots, outlet_id ON public.rooms FOR EACH ROW WHEN (((old.is_active IS DISTINCT FROM new.is_active) OR (old.room_type IS DISTINCT FROM new.room_type) OR (old.total_slots IS DISTINCT FROM new.total_slots) OR (old.outlet_id IS DISTINCT FROM new.outlet_id))) EXECUTE FUNCTION public.enqueue_appointment_assignment_invalidation();


--
-- Name: rooms rooms_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rooms_set_audit_fields BEFORE INSERT OR UPDATE ON public.rooms FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: rooms rooms_sync_room_units; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rooms_sync_room_units AFTER INSERT OR UPDATE OF allocation_mode, total_slots, outlet_id, room_type, is_active ON public.rooms FOR EACH ROW EXECUTE FUNCTION public.sync_room_units_for_zone();


--
-- Name: rooms rooms_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rooms_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.rooms FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: services services_reconcile_appointment_holds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER services_reconcile_appointment_holds AFTER UPDATE OF room_type, duration, buffer_after_minutes ON public.services FOR EACH ROW WHEN (((old.room_type IS DISTINCT FROM new.room_type) OR (old.duration IS DISTINCT FROM new.duration) OR (old.buffer_after_minutes IS DISTINCT FROM new.buffer_after_minutes))) EXECUTE FUNCTION public.enqueue_appointment_assignment_invalidation();


--
-- Name: services services_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER services_set_audit_fields BEFORE INSERT OR UPDATE ON public.services FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: services services_sync_buffer_after; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER services_sync_buffer_after AFTER INSERT OR UPDATE OF buffer_after_minutes ON public.services FOR EACH ROW EXECUTE FUNCTION public.sync_service_buffer_after();


--
-- Name: services services_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER services_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.services FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: settings settings_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER settings_set_audit_fields BEFORE INSERT OR UPDATE ON public.settings FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: settings settings_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER settings_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.settings FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: therapist_working_hours therapist_hours_reconcile_appointment_holds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapist_hours_reconcile_appointment_holds AFTER INSERT OR DELETE OR UPDATE ON public.therapist_working_hours FOR EACH ROW EXECUTE FUNCTION public.enqueue_appointment_assignment_invalidation();


--
-- Name: therapist_working_hours therapist_hours_reject_closed_day; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapist_hours_reject_closed_day BEFORE INSERT OR UPDATE OF outlet_id, day_of_week ON public.therapist_working_hours FOR EACH ROW EXECUTE FUNCTION public.prevent_staff_hours_on_closed_day();


--
-- Name: therapist_queue therapist_queue_rotate_consumed_turn; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapist_queue_rotate_consumed_turn BEFORE UPDATE OF turn_consumed_at ON public.therapist_queue FOR EACH ROW EXECUTE FUNCTION public.record_therapist_queue_turn_consumption();


--
-- Name: therapist_unavailability therapist_unavailability_outlet_match; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapist_unavailability_outlet_match BEFORE INSERT OR UPDATE ON public.therapist_unavailability FOR EACH ROW EXECUTE FUNCTION public.enforce_online_booking_outlet_match();


--
-- Name: therapist_unavailability therapist_unavailability_reconcile_appointment_holds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapist_unavailability_reconcile_appointment_holds AFTER INSERT OR DELETE OR UPDATE ON public.therapist_unavailability FOR EACH ROW EXECUTE FUNCTION public.enqueue_appointment_assignment_invalidation();


--
-- Name: therapist_working_hours therapist_working_hours_outlet_match; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapist_working_hours_outlet_match BEFORE INSERT OR UPDATE ON public.therapist_working_hours FOR EACH ROW EXECUTE FUNCTION public.enforce_online_booking_outlet_match();


--
-- Name: therapists therapists_commission_overrides_admin_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapists_commission_overrides_admin_only BEFORE INSERT OR UPDATE OF commission_overrides ON public.therapists FOR EACH ROW EXECUTE FUNCTION public.protect_therapist_commission_overrides();


--
-- Name: therapists therapists_reconcile_appointment_holds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapists_reconcile_appointment_holds AFTER UPDATE OF availability_status, outlet_id, role ON public.therapists FOR EACH ROW WHEN (((old.availability_status IS DISTINCT FROM new.availability_status) OR (old.outlet_id IS DISTINCT FROM new.outlet_id) OR (old.role IS DISTINCT FROM new.role))) EXECUTE FUNCTION public.enqueue_appointment_assignment_invalidation();


--
-- Name: therapists therapists_seed_default_working_hours; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapists_seed_default_working_hours AFTER INSERT ON public.therapists FOR EACH ROW EXECUTE FUNCTION public.seed_default_therapist_working_hours();


--
-- Name: therapists therapists_service_commissions_stay_empty; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapists_service_commissions_stay_empty BEFORE INSERT OR UPDATE OF service_commissions ON public.therapists FOR EACH ROW EXECUTE FUNCTION public.therapists_reject_service_commission_writes();


--
-- Name: therapists therapists_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapists_set_audit_fields BEFORE INSERT OR UPDATE ON public.therapists FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: therapists therapists_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER therapists_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.therapists FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: transactions transactions_initialize_therapist_commission; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transactions_initialize_therapist_commission AFTER INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.initialize_transaction_therapist_commission();


--
-- Name: transactions transactions_normalize_appointment_addon; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transactions_normalize_appointment_addon BEFORE INSERT OR UPDATE OF service_items ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.normalize_appointment_addon_transaction();


--
-- Name: transactions transactions_notify_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transactions_notify_event AFTER INSERT OR UPDATE OF payment_status, total_amount ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.notify_transaction_event();


--
-- Name: transactions transactions_set_audit_fields; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transactions_set_audit_fields BEFORE INSERT OR UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();


--
-- Name: transactions transactions_sync_appointment_payment_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transactions_sync_appointment_payment_status AFTER INSERT OR UPDATE OF payment_status ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.sync_appointment_payment_status();


--
-- Name: transactions transactions_sync_room_unit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transactions_sync_room_unit BEFORE INSERT OR UPDATE OF appointment_id ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.sync_transaction_room_unit();


--
-- Name: transactions transactions_write_audit_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER transactions_write_audit_log AFTER INSERT OR DELETE OR UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();


--
-- Name: appointments zz_appointments_require_mvp_concrete_resources; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_appointments_require_mvp_concrete_resources BEFORE INSERT OR UPDATE OF therapist_id, room_id, room_unit_id, appointment_date, start_time, end_time, buffer_after_minutes, status, actual_started_at ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.enforce_mvp_concrete_appointment();


--
-- Name: appointment_assignment_invalidations appointment_assignment_invalidations_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_assignment_invalidations
    ADD CONSTRAINT appointment_assignment_invalidations_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: appointment_groups appointment_groups_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_groups
    ADD CONSTRAINT appointment_groups_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: appointment_groups appointment_groups_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_groups
    ADD CONSTRAINT appointment_groups_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: appointment_therapist_allocations appointment_therapist_allocations_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_therapist_allocations
    ADD CONSTRAINT appointment_therapist_allocations_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id) ON DELETE CASCADE;


--
-- Name: appointment_therapist_allocations appointment_therapist_allocations_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_therapist_allocations
    ADD CONSTRAINT appointment_therapist_allocations_therapist_id_fkey FOREIGN KEY (therapist_id) REFERENCES public.therapists(id) ON DELETE RESTRICT;


--
-- Name: appointment_therapist_segments appointment_therapist_segments_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_therapist_segments
    ADD CONSTRAINT appointment_therapist_segments_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id) ON DELETE CASCADE;


--
-- Name: appointment_therapist_segments appointment_therapist_segments_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_therapist_segments
    ADD CONSTRAINT appointment_therapist_segments_therapist_id_fkey FOREIGN KEY (therapist_id) REFERENCES public.therapists(id) ON DELETE RESTRICT;


--
-- Name: appointments appointments_appointment_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_appointment_group_id_fkey FOREIGN KEY (appointment_group_id) REFERENCES public.appointment_groups(id) ON DELETE SET NULL;


--
-- Name: appointments appointments_cancelled_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: appointments appointments_checked_in_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_checked_in_by_fkey FOREIGN KEY (checked_in_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: appointments appointments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: appointments appointments_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: appointments appointments_online_booking_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_online_booking_service_id_fkey FOREIGN KEY (online_booking_service_id) REFERENCES public.online_booking_services(id) ON DELETE SET NULL;


--
-- Name: appointments appointments_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: appointments appointments_requested_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_requested_therapist_id_fkey FOREIGN KEY (requested_therapist_id) REFERENCES public.therapists(id);


--
-- Name: appointments appointments_resources_confirmed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_resources_confirmed_by_fkey FOREIGN KEY (resources_confirmed_by) REFERENCES auth.users(id);


--
-- Name: appointments appointments_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE RESTRICT;


--
-- Name: appointments appointments_room_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_room_unit_id_fkey FOREIGN KEY (room_unit_id) REFERENCES public.room_units(id) ON DELETE RESTRICT;


--
-- Name: appointments appointments_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE RESTRICT;


--
-- Name: appointments appointments_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_therapist_id_fkey FOREIGN KEY (therapist_id) REFERENCES public.therapists(id) ON DELETE RESTRICT;


--
-- Name: booking_holds booking_holds_appointment_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_appointment_group_id_fkey FOREIGN KEY (appointment_group_id) REFERENCES public.appointment_groups(id) ON DELETE SET NULL;


--
-- Name: booking_holds booking_holds_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id) ON DELETE SET NULL;


--
-- Name: booking_holds booking_holds_assigned_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_assigned_room_id_fkey FOREIGN KEY (assigned_room_id) REFERENCES public.rooms(id) ON DELETE SET NULL;


--
-- Name: booking_holds booking_holds_assigned_room_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_assigned_room_unit_id_fkey FOREIGN KEY (assigned_room_unit_id) REFERENCES public.room_units(id) ON DELETE RESTRICT;


--
-- Name: booking_holds booking_holds_assigned_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_assigned_therapist_id_fkey FOREIGN KEY (assigned_therapist_id) REFERENCES public.therapists(id) ON DELETE SET NULL;


--
-- Name: booking_holds booking_holds_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: booking_holds booking_holds_online_booking_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_online_booking_service_id_fkey FOREIGN KEY (online_booking_service_id) REFERENCES public.online_booking_services(id) ON DELETE RESTRICT;


--
-- Name: booking_holds booking_holds_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_holds
    ADD CONSTRAINT booking_holds_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: business_hours business_hours_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours
    ADD CONSTRAINT business_hours_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: business_hours_staff_override_archive business_hours_staff_override_archive_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours_staff_override_archive
    ADD CONSTRAINT business_hours_staff_override_archive_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: business_hours_staff_override_archive business_hours_staff_override_archive_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_hours_staff_override_archive
    ADD CONSTRAINT business_hours_staff_override_archive_therapist_id_fkey FOREIGN KEY (therapist_id) REFERENCES public.therapists(id) ON DELETE CASCADE;


--
-- Name: business_settings business_settings_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_settings
    ADD CONSTRAINT business_settings_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: customers customers_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: notifications notifications_appointment_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_appointment_group_id_fkey FOREIGN KEY (appointment_group_id) REFERENCES public.appointment_groups(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_booking_hold_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_booking_hold_id_fkey FOREIGN KEY (booking_hold_id) REFERENCES public.booking_holds(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_transaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES public.transactions(id) ON DELETE SET NULL;


--
-- Name: online_booking_closures online_booking_closures_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_closures
    ADD CONSTRAINT online_booking_closures_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: online_booking_outlet_settings online_booking_outlet_settings_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_outlet_settings
    ADD CONSTRAINT online_booking_outlet_settings_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: online_booking_service_hours online_booking_service_hours_online_booking_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_hours
    ADD CONSTRAINT online_booking_service_hours_online_booking_service_id_fkey FOREIGN KEY (online_booking_service_id) REFERENCES public.online_booking_services(id) ON DELETE CASCADE;


--
-- Name: online_booking_service_hours online_booking_service_hours_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_hours
    ADD CONSTRAINT online_booking_service_hours_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: online_booking_service_rooms online_booking_service_rooms_online_booking_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_rooms
    ADD CONSTRAINT online_booking_service_rooms_online_booking_service_id_fkey FOREIGN KEY (online_booking_service_id) REFERENCES public.online_booking_services(id) ON DELETE CASCADE;


--
-- Name: online_booking_service_rooms online_booking_service_rooms_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_rooms
    ADD CONSTRAINT online_booking_service_rooms_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: online_booking_service_rooms online_booking_service_rooms_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_service_rooms
    ADD CONSTRAINT online_booking_service_rooms_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE CASCADE;


--
-- Name: online_booking_services online_booking_services_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_services
    ADD CONSTRAINT online_booking_services_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: online_booking_services online_booking_services_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.online_booking_services
    ADD CONSTRAINT online_booking_services_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE RESTRICT;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: room_units room_units_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_units
    ADD CONSTRAINT room_units_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: room_units room_units_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_units
    ADD CONSTRAINT room_units_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.rooms(id) ON DELETE CASCADE;


--
-- Name: rooms rooms_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: service_categories service_categories_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_categories
    ADD CONSTRAINT service_categories_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: services services_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: settings settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: therapist_queue_day therapist_queue_day_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_queue_day
    ADD CONSTRAINT therapist_queue_day_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id);


--
-- Name: therapist_queue_day therapist_queue_day_starter_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_queue_day
    ADD CONSTRAINT therapist_queue_day_starter_therapist_id_fkey FOREIGN KEY (starter_therapist_id) REFERENCES public.therapists(id);


--
-- Name: therapist_queue therapist_queue_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_queue
    ADD CONSTRAINT therapist_queue_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id);


--
-- Name: therapist_queue therapist_queue_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_queue
    ADD CONSTRAINT therapist_queue_therapist_id_fkey FOREIGN KEY (therapist_id) REFERENCES public.therapists(id) ON DELETE CASCADE;


--
-- Name: therapist_unavailability therapist_unavailability_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_unavailability
    ADD CONSTRAINT therapist_unavailability_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: therapist_unavailability therapist_unavailability_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_unavailability
    ADD CONSTRAINT therapist_unavailability_therapist_id_fkey FOREIGN KEY (therapist_id) REFERENCES public.therapists(id) ON DELETE CASCADE;


--
-- Name: therapist_working_hours therapist_working_hours_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_working_hours
    ADD CONSTRAINT therapist_working_hours_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE CASCADE;


--
-- Name: therapist_working_hours therapist_working_hours_therapist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapist_working_hours
    ADD CONSTRAINT therapist_working_hours_therapist_id_fkey FOREIGN KEY (therapist_id) REFERENCES public.therapists(id) ON DELETE CASCADE;


--
-- Name: therapists therapists_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.therapists
    ADD CONSTRAINT therapists_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: transactions transactions_appointment_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_appointment_group_id_fkey FOREIGN KEY (appointment_group_id) REFERENCES public.appointment_groups(id) ON DELETE SET NULL;


--
-- Name: transactions transactions_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id) ON DELETE CASCADE;


--
-- Name: transactions transactions_counter_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_counter_staff_id_fkey FOREIGN KEY (counter_staff_id) REFERENCES public.therapists(id) ON DELETE SET NULL;


--
-- Name: transactions transactions_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: transactions transactions_outlet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_outlet_id_fkey FOREIGN KEY (outlet_id) REFERENCES public.outlets(id) ON DELETE RESTRICT;


--
-- Name: transactions transactions_room_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_room_unit_id_fkey FOREIGN KEY (room_unit_id) REFERENCES public.room_units(id) ON DELETE SET NULL;


--
-- Name: appointments Authenticated users can read appointments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read appointments" ON public.appointments FOR SELECT TO authenticated USING (true);


--
-- Name: customers Authenticated users can read customers; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read customers" ON public.customers FOR SELECT TO authenticated USING (true);


--
-- Name: profiles Authenticated users can read profiles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read profiles" ON public.profiles FOR SELECT TO authenticated USING (true);


--
-- Name: rooms Authenticated users can read rooms; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read rooms" ON public.rooms FOR SELECT TO authenticated USING (true);


--
-- Name: services Authenticated users can read services; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read services" ON public.services FOR SELECT TO authenticated USING (true);


--
-- Name: settings Authenticated users can read settings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read settings" ON public.settings FOR SELECT TO authenticated USING (true);


--
-- Name: therapists Authenticated users can read therapists; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read therapists" ON public.therapists FOR SELECT TO authenticated USING (true);


--
-- Name: transactions Authenticated users can read transactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Authenticated users can read transactions" ON public.transactions FOR SELECT TO authenticated USING (true);


--
-- Name: appointment_assignment_invalidations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.appointment_assignment_invalidations ENABLE ROW LEVEL SECURITY;

--
-- Name: appointment_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.appointment_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: appointment_groups appointment_groups_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointment_groups_delete_admin ON public.appointment_groups FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: appointment_groups appointment_groups_insert_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointment_groups_insert_staff_admin ON public.appointment_groups FOR INSERT TO authenticated WITH CHECK (public.is_staff_or_admin());


--
-- Name: appointment_groups appointment_groups_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointment_groups_select_staff_admin ON public.appointment_groups FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: appointment_groups appointment_groups_update_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointment_groups_update_staff_admin ON public.appointment_groups FOR UPDATE TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: appointment_therapist_allocations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.appointment_therapist_allocations ENABLE ROW LEVEL SECURITY;

--
-- Name: appointment_therapist_allocations appointment_therapist_allocations_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointment_therapist_allocations_staff_select ON public.appointment_therapist_allocations FOR SELECT TO authenticated USING (( SELECT public.is_staff_or_admin() AS is_staff_or_admin));


--
-- Name: appointment_therapist_segments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.appointment_therapist_segments ENABLE ROW LEVEL SECURITY;

--
-- Name: appointment_therapist_segments appointment_therapist_segments_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointment_therapist_segments_staff_select ON public.appointment_therapist_segments FOR SELECT TO authenticated USING (( SELECT public.is_staff_or_admin() AS is_staff_or_admin));


--
-- Name: appointments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.appointments ENABLE ROW LEVEL SECURITY;

--
-- Name: appointments appointments_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointments_delete_admin ON public.appointments FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: appointments appointments_insert_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointments_insert_staff_admin ON public.appointments FOR INSERT TO authenticated WITH CHECK (public.is_staff_or_admin());


--
-- Name: appointments appointments_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointments_select_staff_admin ON public.appointments FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: appointments appointments_update_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointments_update_staff_admin ON public.appointments FOR UPDATE TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log audit_log_select_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY audit_log_select_admin ON public.audit_log FOR SELECT TO authenticated USING (public.is_admin());


--
-- Name: booking_holds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_holds ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_holds booking_holds_admin_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_holds_admin_delete ON public.booking_holds FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: booking_holds booking_holds_staff_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_holds_staff_insert ON public.booking_holds FOR INSERT TO authenticated WITH CHECK (public.is_staff_or_admin());


--
-- Name: booking_holds booking_holds_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_holds_staff_select ON public.booking_holds FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: booking_holds booking_holds_staff_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_holds_staff_update ON public.booking_holds FOR UPDATE TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: business_hours; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_hours ENABLE ROW LEVEL SECURITY;

--
-- Name: business_hours business_hours_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_hours_select ON public.business_hours FOR SELECT USING (public.is_staff_or_admin());


--
-- Name: business_hours_staff_override_archive; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_hours_staff_override_archive ENABLE ROW LEVEL SECURITY;

--
-- Name: business_hours business_hours_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_hours_write ON public.business_hours USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: business_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: business_settings business_settings_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_settings_insert_admin ON public.business_settings FOR INSERT TO authenticated WITH CHECK (public.is_admin());


--
-- Name: business_settings business_settings_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_settings_select_staff_admin ON public.business_settings FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: business_settings business_settings_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_settings_update_admin ON public.business_settings FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: customers customers_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_delete_admin ON public.customers FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: customers customers_insert_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_insert_staff_admin ON public.customers FOR INSERT TO authenticated WITH CHECK (public.is_staff_or_admin());


--
-- Name: customers customers_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_select_staff_admin ON public.customers FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: customers customers_update_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_update_staff_admin ON public.customers FOR UPDATE TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications notifications_admin_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_admin_delete ON public.notifications FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: notifications notifications_staff_admin_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_staff_admin_select ON public.notifications FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: notifications notifications_staff_admin_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_staff_admin_update ON public.notifications FOR UPDATE TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: online_booking_closures; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.online_booking_closures ENABLE ROW LEVEL SECURITY;

--
-- Name: online_booking_closures online_booking_closures_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY online_booking_closures_admin_all ON public.online_booking_closures TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: online_booking_outlet_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.online_booking_outlet_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: online_booking_outlet_settings online_booking_outlet_settings_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY online_booking_outlet_settings_admin_all ON public.online_booking_outlet_settings TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: online_booking_service_hours; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.online_booking_service_hours ENABLE ROW LEVEL SECURITY;

--
-- Name: online_booking_service_hours online_booking_service_hours_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY online_booking_service_hours_admin_all ON public.online_booking_service_hours TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: online_booking_service_rooms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.online_booking_service_rooms ENABLE ROW LEVEL SECURITY;

--
-- Name: online_booking_service_rooms online_booking_service_rooms_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY online_booking_service_rooms_admin_all ON public.online_booking_service_rooms TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: online_booking_services; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.online_booking_services ENABLE ROW LEVEL SECURITY;

--
-- Name: online_booking_services online_booking_services_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY online_booking_services_admin_all ON public.online_booking_services TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: outlets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.outlets ENABLE ROW LEVEL SECURITY;

--
-- Name: outlets outlets_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY outlets_admin_all ON public.outlets TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: outlets outlets_public_read_active; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY outlets_public_read_active ON public.outlets FOR SELECT TO authenticated, anon USING (is_active);


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_admin_all ON public.profiles TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: profiles profiles_select_authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_authenticated ON public.profiles FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: room_units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.room_units ENABLE ROW LEVEL SECURITY;

--
-- Name: room_units room_units_admin_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY room_units_admin_delete ON public.room_units FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: room_units room_units_admin_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY room_units_admin_insert ON public.room_units FOR INSERT TO authenticated WITH CHECK (public.is_admin());


--
-- Name: room_units room_units_admin_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY room_units_admin_update ON public.room_units FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: room_units room_units_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY room_units_staff_select ON public.room_units FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: rooms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;

--
-- Name: rooms rooms_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rooms_admin_all ON public.rooms TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: rooms rooms_insert_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rooms_insert_staff_admin ON public.rooms FOR INSERT TO authenticated WITH CHECK (public.is_staff_or_admin());


--
-- Name: rooms rooms_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rooms_select_staff_admin ON public.rooms FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: rooms rooms_update_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rooms_update_staff_admin ON public.rooms FOR UPDATE TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: service_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.service_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: service_categories service_categories_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_categories_admin_all ON public.service_categories TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: service_categories service_categories_staff_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_categories_staff_read ON public.service_categories FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: services; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;

--
-- Name: services services_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY services_admin_all ON public.services TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: services services_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY services_insert_admin ON public.services FOR INSERT TO authenticated WITH CHECK (public.is_admin());


--
-- Name: services services_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY services_select_staff_admin ON public.services FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: services services_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY services_update_admin ON public.services FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

--
-- Name: settings settings_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY settings_admin_all ON public.settings TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: settings settings_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY settings_select_staff_admin ON public.settings FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: therapist_queue; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.therapist_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: therapist_queue_day; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.therapist_queue_day ENABLE ROW LEVEL SECURITY;

--
-- Name: therapist_queue_day therapist_queue_day_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapist_queue_day_staff_select ON public.therapist_queue_day FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: therapist_queue therapist_queue_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapist_queue_staff_select ON public.therapist_queue FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: therapist_unavailability; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.therapist_unavailability ENABLE ROW LEVEL SECURITY;

--
-- Name: therapist_unavailability therapist_unavailability_staff_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapist_unavailability_staff_admin_all ON public.therapist_unavailability TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: therapist_working_hours; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.therapist_working_hours ENABLE ROW LEVEL SECURITY;

--
-- Name: therapist_working_hours therapist_working_hours_staff_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapist_working_hours_staff_admin_all ON public.therapist_working_hours TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: therapists; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.therapists ENABLE ROW LEVEL SECURITY;

--
-- Name: therapists therapists_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapists_admin_all ON public.therapists TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: therapists therapists_insert_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapists_insert_staff_admin ON public.therapists FOR INSERT TO authenticated WITH CHECK (public.is_staff_or_admin());


--
-- Name: therapists therapists_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapists_select_staff_admin ON public.therapists FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: therapists therapists_update_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY therapists_update_staff_admin ON public.therapists FOR UPDATE TO authenticated USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());


--
-- Name: transactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: transactions transactions_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY transactions_delete_admin ON public.transactions FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: transactions transactions_insert_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY transactions_insert_staff_admin ON public.transactions FOR INSERT TO authenticated WITH CHECK (public.is_staff_or_admin());


--
-- Name: transactions transactions_select_staff_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY transactions_select_staff_admin ON public.transactions FOR SELECT TO authenticated USING (public.is_staff_or_admin());


--
-- Name: transactions transactions_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY transactions_update_admin ON public.transactions FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: TABLE appointments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.appointments TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointments TO service_role;


--
-- Name: FUNCTION adjust_appointment_service_end(p_appointment_id uuid, p_expected_end_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.adjust_appointment_service_end(p_appointment_id uuid, p_expected_end_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.adjust_appointment_service_end(p_appointment_id uuid, p_expected_end_at timestamp with time zone) TO authenticated;


--
-- Name: FUNCTION allocate_preference_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.allocate_preference_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.allocate_preference_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid) TO authenticated;


--
-- Name: FUNCTION allocate_preference_provisional_slots_122r_impl(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.allocate_preference_provisional_slots_122r_impl(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid) TO authenticated;


--
-- Name: FUNCTION allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_pax integer, p_room_type text, p_buffer_after_minutes integer, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_pax integer, p_room_type text, p_buffer_after_minutes integer, p_exclude_appointment_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.allocate_provisional_slots(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_pax integer, p_room_type text, p_buffer_after_minutes integer, p_exclude_appointment_group_id uuid) TO authenticated;


--
-- Name: FUNCTION allocate_provisional_slots_unfiltered_rooms_legacy(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.allocate_provisional_slots_unfiltered_rooms_legacy(p_outlet_id uuid, p_date date, p_start_time time without time zone, p_requirements jsonb, p_exclude_appointment_group_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION allocate_specific_room_unit(p_zone_id uuid, p_start_at timestamp without time zone, p_block_end_at timestamp without time zone, p_requested_unit_id uuid, p_exclude_appointment_id uuid, p_exclude_hold_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.allocate_specific_room_unit(p_zone_id uuid, p_start_at timestamp without time zone, p_block_end_at timestamp without time zone, p_requested_unit_id uuid, p_exclude_appointment_id uuid, p_exclude_hold_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.allocate_specific_room_unit(p_zone_id uuid, p_start_at timestamp without time zone, p_block_end_at timestamp without time zone, p_requested_unit_id uuid, p_exclude_appointment_id uuid, p_exclude_hold_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.allocate_specific_room_unit(p_zone_id uuid, p_start_at timestamp without time zone, p_block_end_at timestamp without time zone, p_requested_unit_id uuid, p_exclude_appointment_id uuid, p_exclude_hold_id uuid) TO service_role;


--
-- Name: FUNCTION apply_appointment_service_buffer(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.apply_appointment_service_buffer() FROM PUBLIC;


--
-- Name: FUNCTION appointment_addon_minutes(p_appointment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.appointment_addon_minutes(p_appointment_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.appointment_addon_minutes(p_appointment_id uuid) TO authenticated;


--
-- Name: FUNCTION assignment_reconcile_retry_delay(p_attempt_count integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.assignment_reconcile_retry_delay(p_attempt_count integer) FROM PUBLIC;


--
-- Name: FUNCTION automatic_therapist_queue_starter(p_outlet_id uuid, p_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.automatic_therapist_queue_starter(p_outlet_id uuid, p_date date) FROM PUBLIC;


--
-- Name: FUNCTION begin_business_hours_staff_sync(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.begin_business_hours_staff_sync() FROM PUBLIC;


--
-- Name: FUNCTION can_manage_app_images(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_manage_app_images() FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_manage_app_images() TO authenticated;


--
-- Name: FUNCTION cancel_appointment(p_appointment_id uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cancel_appointment(p_appointment_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_appointment(p_appointment_id uuid, p_reason text) TO authenticated;


--
-- Name: FUNCTION cancel_appointment_group(p_group_id uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cancel_appointment_group(p_group_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_appointment_group(p_group_id uuid, p_reason text) TO authenticated;


--
-- Name: FUNCTION capacity_bipartite_saturates(p_adjacency jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capacity_bipartite_saturates(p_adjacency jsonb) FROM PUBLIC;


--
-- Name: FUNCTION capacity_feasible(p_outlet_id uuid, p_demands jsonb, p_mode text, p_exclude_appointment_id uuid, p_exclude_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capacity_feasible(p_outlet_id uuid, p_demands jsonb, p_mode text, p_exclude_appointment_id uuid, p_exclude_group_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION capacity_feasible_119b_legacy(p_outlet_id uuid, p_demands jsonb, p_mode text, p_exclude_appointment_id uuid, p_exclude_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capacity_feasible_119b_legacy(p_outlet_id uuid, p_demands jsonb, p_mode text, p_exclude_appointment_id uuid, p_exclude_group_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION capacity_first_enabled(p_outlet_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capacity_first_enabled(p_outlet_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.capacity_first_enabled(p_outlet_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.capacity_first_enabled(p_outlet_id uuid) TO service_role;


--
-- Name: FUNCTION capacity_kuhn_augment(p_demand text, p_adjacency jsonb, p_match jsonb, p_visited jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capacity_kuhn_augment(p_demand text, p_adjacency jsonb, p_match jsonb, p_visited jsonb) FROM PUBLIC;


--
-- Name: FUNCTION change_today_queue_starter(p_outlet_id uuid, p_date date, p_starter_therapist_id uuid, p_reason text, p_confirm_reset boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.change_today_queue_starter(p_outlet_id uuid, p_date date, p_starter_therapist_id uuid, p_reason text, p_confirm_reset boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.change_today_queue_starter(p_outlet_id uuid, p_date date, p_starter_therapist_id uuid, p_reason text, p_confirm_reset boolean) TO authenticated;


--
-- Name: FUNCTION check_booking_availability(p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_exclude_appointment_id uuid, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_booking_availability(p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_exclude_appointment_id uuid, p_exclude_appointment_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_booking_availability(p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_exclude_appointment_id uuid, p_exclude_appointment_group_id uuid) TO authenticated;


--
-- Name: FUNCTION check_in_appointment(p_appointment_id uuid, p_addon_service_items jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_in_appointment(p_appointment_id uuid, p_addon_service_items jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_in_appointment(p_appointment_id uuid, p_addon_service_items jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION check_in_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_in_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_in_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION check_in_paid_appointment_group_with_addon(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_per_appointment_updates jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_in_paid_appointment_group_with_addon(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_per_appointment_updates jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_in_paid_appointment_group_with_addon(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_per_appointment_updates jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION check_in_paid_appointment_with_addon(p_appointment_id uuid, p_addon_service_items jsonb, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_in_paid_appointment_with_addon(p_appointment_id uuid, p_addon_service_items jsonb, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_in_paid_appointment_with_addon(p_appointment_id uuid, p_addon_service_items jsonb, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION check_walkin_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_walkin_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_walkin_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid) TO authenticated;


--
-- Name: FUNCTION check_walkin_protects_future(p_outlet_id uuid, p_start timestamp without time zone, p_duration integer, p_therapist_id uuid, p_exclude_appointment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_walkin_protects_future(p_outlet_id uuid, p_start timestamp without time zone, p_duration integer, p_therapist_id uuid, p_exclude_appointment_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_walkin_protects_future(p_outlet_id uuid, p_start timestamp without time zone, p_duration integer, p_therapist_id uuid, p_exclude_appointment_id uuid) TO authenticated;


--
-- Name: FUNCTION checkout_appointment_group_with_payment(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_id uuid, p_customer_name text, p_customer_phone text, p_per_appointment_updates jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.checkout_appointment_group_with_payment(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_id uuid, p_customer_name text, p_customer_phone text, p_per_appointment_updates jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.checkout_appointment_group_with_payment(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_id uuid, p_customer_name text, p_customer_phone text, p_per_appointment_updates jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) TO authenticated;


--
-- Name: FUNCTION checkout_appointment_with_payment(p_appointment_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_booked_date date, p_booked_start_time time without time zone, p_booked_end_time time without time zone, p_booked_start_at timestamp with time zone, p_booked_end_at timestamp with time zone, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.checkout_appointment_with_payment(p_appointment_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_booked_date date, p_booked_start_time time without time zone, p_booked_end_time time without time zone, p_booked_start_at timestamp with time zone, p_booked_end_at timestamp with time zone, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.checkout_appointment_with_payment(p_appointment_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_booked_date date, p_booked_start_time time without time zone, p_booked_end_time time without time zone, p_booked_start_at timestamp with time zone, p_booked_end_at timestamp with time zone, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) TO authenticated;


--
-- Name: FUNCTION claim_billplz_bill_v2(p_token uuid, p_bill_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_billplz_bill_v2(p_token uuid, p_bill_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_billplz_bill_v2(p_token uuid, p_bill_id text) TO service_role;


--
-- Name: FUNCTION claim_booking_bill_cancellation(p_token uuid, p_target_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_booking_bill_cancellation(p_token uuid, p_target_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_booking_bill_cancellation(p_token uuid, p_target_status text) TO service_role;


--
-- Name: FUNCTION claim_expired_billplz_cancellations(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_expired_billplz_cancellations(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_expired_billplz_cancellations(p_limit integer) TO service_role;


--
-- Name: FUNCTION clamp_booking_hold_expiry(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.clamp_booking_hold_expiry() FROM PUBLIC;


--
-- Name: FUNCTION clear_appointment_resources(p_appointment_id uuid, p_clear_therapist boolean, p_clear_room boolean, p_clear_room_unit boolean, p_clear_requested_therapist boolean, p_clear_requested_gender boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.clear_appointment_resources(p_appointment_id uuid, p_clear_therapist boolean, p_clear_room boolean, p_clear_room_unit boolean, p_clear_requested_therapist boolean, p_clear_requested_gender boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.clear_appointment_resources(p_appointment_id uuid, p_clear_therapist boolean, p_clear_room boolean, p_clear_room_unit boolean, p_clear_requested_therapist boolean, p_clear_requested_gender boolean) TO authenticated;


--
-- Name: FUNCTION complete_billplz_cancellation(p_hold_id uuid, p_claim_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.complete_billplz_cancellation(p_hold_id uuid, p_claim_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_billplz_cancellation(p_hold_id uuid, p_claim_token uuid) TO service_role;


--
-- Name: FUNCTION complete_due_appointments(p_outlet_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.complete_due_appointments(p_outlet_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_due_appointments(p_outlet_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.complete_due_appointments(p_outlet_id uuid) TO service_role;


--
-- Name: FUNCTION confirm_and_start_appointment(p_appointment_id uuid, p_idempotency_key text, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_and_start_appointment(p_appointment_id uuid, p_idempotency_key text, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_and_start_appointment(p_appointment_id uuid, p_idempotency_key text, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.confirm_and_start_appointment(p_appointment_id uuid, p_idempotency_key text, p_end_time time without time zone, p_end_at timestamp with time zone, p_allow_late_extension_overlap boolean, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) TO service_role;


--
-- Name: FUNCTION confirm_and_start_group(p_group_id uuid, p_idempotency_key text, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_and_start_group(p_group_id uuid, p_idempotency_key text, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_and_start_group(p_group_id uuid, p_idempotency_key text, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.confirm_and_start_group(p_group_id uuid, p_idempotency_key text, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text) TO service_role;


--
-- Name: FUNCTION confirm_public_booking_group_v1(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_public_booking_group_v1(p_token uuid) FROM PUBLIC;


--
-- Name: FUNCTION confirm_public_booking_hold(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_public_booking_hold(p_token uuid) FROM PUBLIC;


--
-- Name: FUNCTION consume_queue_on_appointment_start(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consume_queue_on_appointment_start() FROM PUBLIC;


--
-- Name: FUNCTION consume_therapist_queue_turn_for_start(p_outlet_id uuid, p_queue_date date, p_therapist_id uuid, p_started_at timestamp with time zone, p_appointment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consume_therapist_queue_turn_for_start(p_outlet_id uuid, p_queue_date date, p_therapist_id uuid, p_started_at timestamp with time zone, p_appointment_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION create_appointment_group_with_csp(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_created_by uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_appointment_group_with_csp(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_created_by uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_appointment_group_with_csp(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_created_by uuid) TO authenticated;


--
-- Name: FUNCTION create_appointment_with_csp(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_price numeric, p_type text, p_created_by uuid, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_appointment_group_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_appointment_with_csp(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_price numeric, p_type text, p_created_by uuid, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_appointment_group_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_appointment_with_csp(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_price numeric, p_type text, p_created_by uuid, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_appointment_group_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) TO authenticated;


--
-- Name: FUNCTION create_appointment_with_csp_121_legacy(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_price numeric, p_type text, p_created_by uuid, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_appointment_group_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_appointment_with_csp_121_legacy(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_price numeric, p_type text, p_created_by uuid, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_appointment_group_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) FROM PUBLIC;


--
-- Name: FUNCTION create_public_booking_group_hold_v1(p_allocations jsonb, p_start_at timestamp with time zone, p_customer_name text, p_customer_phone text, p_customer_email text, p_notes text, p_request_fingerprint text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_public_booking_group_hold_v1(p_allocations jsonb, p_start_at timestamp with time zone, p_customer_name text, p_customer_phone text, p_customer_email text, p_notes text, p_request_fingerprint text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_public_booking_group_hold_v1(p_allocations jsonb, p_start_at timestamp with time zone, p_customer_name text, p_customer_phone text, p_customer_email text, p_notes text, p_request_fingerprint text) TO service_role;


--
-- Name: FUNCTION create_public_booking_hold_v2(p_catalogue_id uuid, p_start_at timestamp with time zone, p_therapist_preference text, p_customer_name text, p_customer_phone text, p_customer_email text, p_therapist_request text, p_notes text, p_request_fingerprint text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_public_booking_hold_v2(p_catalogue_id uuid, p_start_at timestamp with time zone, p_therapist_preference text, p_customer_name text, p_customer_phone text, p_customer_email text, p_therapist_request text, p_notes text, p_request_fingerprint text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_public_booking_hold_v2(p_catalogue_id uuid, p_start_at timestamp with time zone, p_therapist_preference text, p_customer_name text, p_customer_phone text, p_customer_email text, p_therapist_request text, p_notes text, p_request_fingerprint text) TO service_role;


--
-- Name: FUNCTION create_staff_walkin_and_start_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_draft_session_id text, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_started_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_staff_walkin_and_start_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_draft_session_id text, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_started_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_staff_walkin_and_start_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_draft_session_id text, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_started_at timestamp with time zone) TO authenticated;


--
-- Name: FUNCTION create_staff_walkin_group_and_start_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_draft_session_id text, p_started_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_staff_walkin_group_and_start_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_draft_session_id text, p_started_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_staff_walkin_group_and_start_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_draft_session_id text, p_started_at timestamp with time zone) TO authenticated;


--
-- Name: FUNCTION create_staff_walkin_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_start_immediately boolean, p_draft_session_id text, p_created_by uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_staff_walkin_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_start_immediately boolean, p_draft_session_id text, p_created_by uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_staff_walkin_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_start_immediately boolean, p_draft_session_id text, p_created_by uuid) TO authenticated;


--
-- Name: FUNCTION create_staff_walkin_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_start_immediately boolean, p_draft_session_id text, p_created_by uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_staff_walkin_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_start_immediately boolean, p_draft_session_id text, p_created_by uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_staff_walkin_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_start_immediately boolean, p_draft_session_id text, p_created_by uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text) TO authenticated;


--
-- Name: FUNCTION create_walkin_appointment_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_created_by uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_walkin_appointment_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_created_by uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_walkin_appointment_group_with_payment(p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_created_by uuid) TO authenticated;


--
-- Name: FUNCTION create_walkin_appointment_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_created_by uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_walkin_appointment_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_created_by uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_walkin_appointment_with_payment(p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_service_price numeric, p_service_name text, p_service_items jsonb, p_item_count integer, p_notes text, p_customer_name text, p_customer_phone text, p_counter_staff_id uuid, p_counter_staff_name text, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text, p_transaction_notes text, p_created_by uuid) TO authenticated;


--
-- Name: FUNCTION csp_commission_for_items(p_service_items jsonb, p_staff_id uuid, p_role text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.csp_commission_for_items(p_service_items jsonb, p_staff_id uuid, p_role text) FROM PUBLIC;


--
-- Name: FUNCTION csp_commission_for_transaction_items(p_service_items jsonb, p_default_therapist_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.csp_commission_for_transaction_items(p_service_items jsonb, p_default_therapist_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.csp_commission_for_transaction_items(p_service_items jsonb, p_default_therapist_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.csp_commission_for_transaction_items(p_service_items jsonb, p_default_therapist_id uuid) TO service_role;


--
-- Name: FUNCTION current_user_role(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.current_user_role() FROM PUBLIC;
GRANT ALL ON FUNCTION public.current_user_role() TO authenticated;


--
-- Name: FUNCTION enforce_mvp_concrete_appointment(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_mvp_concrete_appointment() FROM PUBLIC;


--
-- Name: FUNCTION enforce_online_appointment_conversion(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_online_appointment_conversion() FROM PUBLIC;


--
-- Name: FUNCTION enforce_online_booking_outlet_match(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_online_booking_outlet_match() FROM PUBLIC;


--
-- Name: FUNCTION enforce_online_hold_concrete_resources(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_online_hold_concrete_resources() FROM PUBLIC;


--
-- Name: FUNCTION enforce_online_service_buffer(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_online_service_buffer() FROM PUBLIC;


--
-- Name: FUNCTION enforce_walkin_future_capacity(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_walkin_future_capacity() FROM PUBLIC;


--
-- Name: FUNCTION enqueue_appointment_assignment_invalidation(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enqueue_appointment_assignment_invalidation() FROM PUBLIC;


--
-- Name: FUNCTION expire_stale_booking_holds(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.expire_stale_booking_holds() FROM PUBLIC;
GRANT ALL ON FUNCTION public.expire_stale_booking_holds() TO service_role;


--
-- Name: FUNCTION fail_billplz_cancellation(p_hold_id uuid, p_claim_token uuid, p_error text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fail_billplz_cancellation(p_hold_id uuid, p_claim_token uuid, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fail_billplz_cancellation(p_hold_id uuid, p_claim_token uuid, p_error text) TO service_role;


--
-- Name: FUNCTION finalize_and_start_appointment(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_and_start_appointment(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION finalize_and_start_appointment_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_and_start_appointment_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_payment_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION finalize_and_start_appointment_core(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment_core(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone) FROM PUBLIC;


--
-- Name: FUNCTION finalize_and_start_appointment_core_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment_core_122t_capacity_first_dormant(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone) FROM PUBLIC;


--
-- Name: FUNCTION finalize_and_start_appointment_core_124_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment_core_124_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone) FROM PUBLIC;


--
-- Name: FUNCTION finalize_and_start_appointment_core_126_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment_core_126_legacy(p_appointment_id uuid, p_customer_name text, p_customer_phone text, p_guest_name text, p_guest_phone text, p_service_items jsonb, p_therapist_id uuid, p_assignment_source text, p_requested_gender text, p_room_id uuid, p_room_unit_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone) FROM PUBLIC;


--
-- Name: FUNCTION finalize_and_start_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_and_start_appointment_group(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION finalize_and_start_appointment_group_122t_capacity_first_dorman(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_and_start_appointment_group_122t_capacity_first_dorman(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_and_start_appointment_group_122t_capacity_first_dorman(p_appointment_group_id uuid, p_appointment_ids uuid[], p_customer_name text, p_customer_phone text, p_pax_updates jsonb, p_payment_items jsonb, p_started_at timestamp with time zone, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid) TO authenticated;


--
-- Name: FUNCTION get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid, p_buffer_after_minutes integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid, p_buffer_after_minutes integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_available_slots(p_date date, p_therapist_id uuid, p_room_id uuid, p_duration integer, p_exclude_id uuid, p_buffer_after_minutes integer) TO authenticated;


--
-- Name: FUNCTION get_booking_group_for_payment(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_booking_group_for_payment(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_booking_group_for_payment(p_token uuid) TO service_role;


--
-- Name: FUNCTION get_booking_group_token_by_bill(p_bill_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_booking_group_token_by_bill(p_bill_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_booking_group_token_by_bill(p_bill_id text) TO service_role;


--
-- Name: FUNCTION get_booking_hold_for_payment(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_booking_hold_for_payment(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_booking_hold_for_payment(p_token uuid) TO service_role;


--
-- Name: FUNCTION get_booking_hold_token_by_bill(p_bill_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_booking_hold_token_by_bill(p_bill_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_booking_hold_token_by_bill(p_bill_id text) TO service_role;


--
-- Name: FUNCTION get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid) TO authenticated;


--
-- Name: FUNCTION get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_duration integer, p_pax integer, p_room_type text, p_buffer_after_minutes integer, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_duration integer, p_pax integer, p_room_type text, p_buffer_after_minutes integer, p_exclude_appointment_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_counter_capacity_slots(p_outlet_id uuid, p_date date, p_duration integer, p_pax integer, p_room_type text, p_buffer_after_minutes integer, p_exclude_appointment_group_id uuid) TO authenticated;


--
-- Name: FUNCTION get_counter_preference_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_counter_preference_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_counter_preference_capacity_slots(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid) TO authenticated;


--
-- Name: FUNCTION get_counter_preference_capacity_slots_122r_impl(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_counter_preference_capacity_slots_122r_impl(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION get_counter_preference_capacity_slots_v2(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_counter_preference_capacity_slots_v2(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_counter_preference_capacity_slots_v2(p_outlet_id uuid, p_date date, p_requirements jsonb, p_exclude_appointment_group_id uuid, p_exclude_appointment_id uuid) TO authenticated;


--
-- Name: FUNCTION get_public_booking_dates_v2(p_catalogue_id uuid, p_therapist_preference text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_dates_v2(p_catalogue_id uuid, p_therapist_preference text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_dates_v2(p_catalogue_id uuid, p_therapist_preference text) TO service_role;


--
-- Name: FUNCTION get_public_booking_grid_times_v1(p_catalogue_id uuid, p_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_grid_times_v1(p_catalogue_id uuid, p_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_grid_times_v1(p_catalogue_id uuid, p_date date) TO service_role;


--
-- Name: FUNCTION get_public_booking_group_date_range_v1(p_allocations jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_group_date_range_v1(p_allocations jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_group_date_range_v1(p_allocations jsonb) TO service_role;


--
-- Name: FUNCTION get_public_booking_group_dates_v1(p_allocations jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_group_dates_v1(p_allocations jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_group_dates_v1(p_allocations jsonb) TO service_role;


--
-- Name: FUNCTION get_public_booking_group_slot_status_v1(p_allocations jsonb, p_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_group_slot_status_v1(p_allocations jsonb, p_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_group_slot_status_v1(p_allocations jsonb, p_date date) TO service_role;


--
-- Name: FUNCTION get_public_booking_group_slots_scan_v1(p_allocations jsonb, p_date date, p_stop_after_first boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_group_slots_scan_v1(p_allocations jsonb, p_date date, p_stop_after_first boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_group_slots_scan_v1(p_allocations jsonb, p_date date, p_stop_after_first boolean) TO service_role;


--
-- Name: FUNCTION get_public_booking_group_slots_v1(p_allocations jsonb, p_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_group_slots_v1(p_allocations jsonb, p_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_group_slots_v1(p_allocations jsonb, p_date date) TO service_role;


--
-- Name: FUNCTION get_public_booking_group_status_v1(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_group_status_v1(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_group_status_v1(p_token uuid) TO service_role;


--
-- Name: FUNCTION get_public_booking_hold_status_v2(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_hold_status_v2(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_hold_status_v2(p_token uuid) TO service_role;


--
-- Name: FUNCTION get_public_booking_slots_v2(p_catalogue_id uuid, p_date date, p_therapist_preference text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_public_booking_slots_v2(p_catalogue_id uuid, p_date date, p_therapist_preference text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_public_booking_slots_v2(p_catalogue_id uuid, p_date date, p_therapist_preference text) TO service_role;


--
-- Name: FUNCTION get_queue_schedule_status(p_outlet_id uuid, p_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_queue_schedule_status(p_outlet_id uuid, p_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_queue_schedule_status(p_outlet_id uuid, p_date date) TO authenticated;


--
-- Name: FUNCTION get_room_unit_availability(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_room_unit_availability(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_room_unit_availability(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_room_unit_availability(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer) TO service_role;


--
-- Name: FUNCTION get_room_unit_availability_v2(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_room_unit_availability_v2(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_room_unit_availability_v2(p_zone_id uuid, p_date date, p_start_time time without time zone, p_duration integer) TO authenticated;


--
-- Name: FUNCTION get_staff_booking_schedule_context(p_date date, p_therapist_id uuid, p_exclude_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_staff_booking_schedule_context(p_date date, p_therapist_id uuid, p_exclude_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_staff_booking_schedule_context(p_date date, p_therapist_id uuid, p_exclude_id uuid) TO authenticated;


--
-- Name: FUNCTION get_therapist_queue(p_outlet_id uuid, p_date date, p_now_time time without time zone, p_duration integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_therapist_queue(p_outlet_id uuid, p_date date, p_now_time time without time zone, p_duration integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_therapist_queue(p_outlet_id uuid, p_date date, p_now_time time without time zone, p_duration integer) TO authenticated;


--
-- Name: FUNCTION get_today_queue_management(p_outlet_id uuid, p_date date, p_now_time time without time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_today_queue_management(p_outlet_id uuid, p_date date, p_now_time time without time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_today_queue_management(p_outlet_id uuid, p_date date, p_now_time time without time zone) TO authenticated;


--
-- Name: FUNCTION get_walkin_room_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_walkin_room_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_walkin_room_availability(p_today date, p_now_time time without time zone, p_duration integer, p_room_id uuid) TO authenticated;


--
-- Name: FUNCTION get_walkin_therapist_availability(p_today date, p_now_time time without time zone, p_duration integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_walkin_therapist_availability(p_today date, p_now_time time without time zone, p_duration integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_walkin_therapist_availability(p_today date, p_now_time time without time zone, p_duration integer) TO authenticated;


--
-- Name: FUNCTION initialize_appointment_therapist_allocation(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.initialize_appointment_therapist_allocation() FROM PUBLIC;


--
-- Name: FUNCTION initialize_transaction_therapist_commission(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.initialize_transaction_therapist_commission() FROM PUBLIC;


--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_admin() TO authenticated;


--
-- Name: FUNCTION is_staff_or_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_staff_or_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_staff_or_admin() TO authenticated;


--
-- Name: FUNCTION list_public_booking_catalogue(p_outlet_code text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_public_booking_catalogue(p_outlet_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_public_booking_catalogue(p_outlet_code text) TO service_role;


--
-- Name: FUNCTION list_public_booking_outlets(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_public_booking_outlets() FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_public_booking_outlets() TO service_role;


--
-- Name: FUNCTION list_public_booking_outlets_v2(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_public_booking_outlets_v2() FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_public_booking_outlets_v2() TO service_role;


--
-- Name: FUNCTION mark_booking_group_payment_failed(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.mark_booking_group_payment_failed(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_booking_group_payment_failed(p_token uuid) TO service_role;


--
-- Name: FUNCTION mark_booking_hold_payment_failed(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.mark_booking_hold_payment_failed(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_booking_hold_payment_failed(p_token uuid) TO service_role;


--
-- Name: FUNCTION mark_past_appointments_no_show(p_outlet_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.mark_past_appointments_no_show(p_outlet_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_past_appointments_no_show(p_outlet_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.mark_past_appointments_no_show(p_outlet_id uuid) TO service_role;


--
-- Name: FUNCTION match_finalize_start_group_therapists(p_appointment_group_id uuid, p_pax_updates jsonb, p_started_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.match_finalize_start_group_therapists(p_appointment_group_id uuid, p_pax_updates jsonb, p_started_at timestamp with time zone) FROM PUBLIC;


--
-- Name: FUNCTION match_finalize_start_therapists_recursive(p_requirements jsonb, p_requirement_index integer, p_used_therapists uuid[], p_outlet_id uuid, p_exclude_appointment_id uuid, p_exclude_appointment_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.match_finalize_start_therapists_recursive(p_requirements jsonb, p_requirement_index integer, p_used_therapists uuid[], p_outlet_id uuid, p_exclude_appointment_id uuid, p_exclude_appointment_group_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION normalize_appointment_addon_transaction(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.normalize_appointment_addon_transaction() FROM PUBLIC;


--
-- Name: FUNCTION normalize_appointment_assignment_states(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.normalize_appointment_assignment_states() FROM PUBLIC;


--
-- Name: FUNCTION notify_appointment_event(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.notify_appointment_event() FROM PUBLIC;


--
-- Name: FUNCTION notify_booking_hold_event(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.notify_booking_hold_event() FROM PUBLIC;


--
-- Name: FUNCTION notify_transaction_event(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.notify_transaction_event() FROM PUBLIC;


--
-- Name: FUNCTION outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric) TO authenticated;
GRANT ALL ON FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric) TO service_role;


--
-- Name: FUNCTION outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric, p_payment_origin text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric, p_payment_origin text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric, p_payment_origin text) TO authenticated;
GRANT ALL ON FUNCTION public.outlet_payment_breakdown(p_outlet_id uuid, p_display_price numeric, p_payment_origin text) TO service_role;


--
-- Name: FUNCTION pay_appointment_addons(p_appointment_id uuid, p_addon_service_items jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pay_appointment_addons(p_appointment_id uuid, p_addon_service_items jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pay_appointment_addons(p_appointment_id uuid, p_addon_service_items jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION pay_appointment_group_addons(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pay_appointment_group_addons(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pay_appointment_group_addons(p_appointment_group_id uuid, p_appointment_ids uuid[], p_addon_items_by_appointment jsonb, p_counter_staff_id uuid, p_counter_staff_name text, p_service_price numeric, p_sst_amount numeric, p_total_amount numeric, p_payment_method text, p_receipt_number text) TO authenticated;


--
-- Name: FUNCTION prevent_appointment_resource_overlap(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.prevent_appointment_resource_overlap() FROM PUBLIC;


--
-- Name: FUNCTION prevent_staff_hours_on_closed_day(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.prevent_staff_hours_on_closed_day() FROM PUBLIC;


--
-- Name: FUNCTION preview_check_in(p_appointment_id uuid, p_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.preview_check_in(p_appointment_id uuid, p_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.preview_check_in(p_appointment_id uuid, p_group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.preview_check_in(p_appointment_id uuid, p_group_id uuid) TO service_role;


--
-- Name: FUNCTION process_paid_public_booking_group(p_token uuid, p_bill_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.process_paid_public_booking_group(p_token uuid, p_bill_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.process_paid_public_booking_group(p_token uuid, p_bill_id text) TO service_role;


--
-- Name: FUNCTION process_paid_public_booking_hold(p_token uuid, p_bill_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.process_paid_public_booking_hold(p_token uuid, p_bill_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.process_paid_public_booking_hold(p_token uuid, p_bill_id text) TO service_role;


--
-- Name: FUNCTION project_appointment_end_on_actual_start(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.project_appointment_end_on_actual_start() FROM PUBLIC;


--
-- Name: FUNCTION protect_therapist_commission_overrides(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.protect_therapist_commission_overrides() FROM PUBLIC;


--
-- Name: FUNCTION queue_business_hours_assignment_reconcile(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_business_hours_assignment_reconcile() FROM PUBLIC;


--
-- Name: FUNCTION reactivate_no_show_appointment(p_appointment_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_updates jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reactivate_no_show_appointment(p_appointment_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_updates jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reactivate_no_show_appointment(p_appointment_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_therapist_id uuid, p_room_id uuid, p_room_unit_id uuid, p_updates jsonb) TO authenticated;


--
-- Name: FUNCTION rebuild_therapist_queue_from_starter(p_outlet_id uuid, p_date date, p_starter_therapist_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rebuild_therapist_queue_from_starter(p_outlet_id uuid, p_date date, p_starter_therapist_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION recalculate_appointment_therapist_commission(p_appointment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recalculate_appointment_therapist_commission(p_appointment_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION reconcile_appointment_resources(p_appointment_id uuid, p_confirm boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reconcile_appointment_resources(p_appointment_id uuid, p_confirm boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reconcile_appointment_resources(p_appointment_id uuid, p_confirm boolean) TO authenticated;
GRANT ALL ON FUNCTION public.reconcile_appointment_resources(p_appointment_id uuid, p_confirm boolean) TO service_role;


--
-- Name: FUNCTION reconcile_appointment_resources_112_core(p_appointment_id uuid, p_confirm boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reconcile_appointment_resources_112_core(p_appointment_id uuid, p_confirm boolean) FROM PUBLIC;


--
-- Name: FUNCTION reconcile_upcoming_appointment_assignments(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reconcile_upcoming_appointment_assignments() FROM PUBLIC;
GRANT ALL ON FUNCTION public.reconcile_upcoming_appointment_assignments() TO service_role;


--
-- Name: FUNCTION record_billplz_bill(p_token uuid, p_bill_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_billplz_bill(p_token uuid, p_bill_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_billplz_bill(p_token uuid, p_bill_id text) TO service_role;


--
-- Name: FUNCTION record_billplz_group_bill(p_token uuid, p_bill_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_billplz_group_bill(p_token uuid, p_bill_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_billplz_group_bill(p_token uuid, p_bill_id text) TO service_role;


--
-- Name: FUNCTION record_online_booking_group_payment(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_online_booking_group_payment(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_online_booking_group_payment(p_token uuid) TO service_role;


--
-- Name: FUNCTION record_online_booking_payment(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_online_booking_payment(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_online_booking_payment(p_token uuid) TO service_role;


--
-- Name: FUNCTION record_therapist_queue_turn_consumption(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_therapist_queue_turn_consumption() FROM PUBLIC;


--
-- Name: FUNCTION release_staff_walkin_draft(p_draft_session_id text, p_pax_index integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.release_staff_walkin_draft(p_draft_session_id text, p_pax_index integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.release_staff_walkin_draft(p_draft_session_id text, p_pax_index integer) TO authenticated;


--
-- Name: FUNCTION reorder_current_therapist_queue(p_outlet_id uuid, p_date date, p_therapist_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reorder_current_therapist_queue(p_outlet_id uuid, p_date date, p_therapist_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reorder_current_therapist_queue(p_outlet_id uuid, p_date date, p_therapist_ids uuid[]) TO authenticated;


--
-- Name: FUNCTION reorder_staff_display_order(p_outlet_id uuid, p_staff_ids uuid[], p_display_orders integer[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reorder_staff_display_order(p_outlet_id uuid, p_staff_ids uuid[], p_display_orders integer[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reorder_staff_display_order(p_outlet_id uuid, p_staff_ids uuid[], p_display_orders integer[]) TO authenticated;


--
-- Name: FUNCTION request_appointment_assignment_reconcile(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.request_appointment_assignment_reconcile() FROM PUBLIC;


--
-- Name: FUNCTION reserve_staff_walkin_allocation(p_draft_session_id text, p_pax_index integer, p_outlet_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_therapist_id uuid, p_room_id uuid, p_service_items jsonb, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_amount numeric, p_room_unit_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reserve_staff_walkin_allocation(p_draft_session_id text, p_pax_index integer, p_outlet_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_therapist_id uuid, p_room_id uuid, p_service_items jsonb, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_amount numeric, p_room_unit_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reserve_staff_walkin_allocation(p_draft_session_id text, p_pax_index integer, p_outlet_id uuid, p_customer_id uuid, p_customer_name text, p_customer_phone text, p_therapist_id uuid, p_room_id uuid, p_service_items jsonb, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_total_amount numeric, p_room_unit_id uuid) TO authenticated;


--
-- Name: FUNCTION reset_today_queue_to_automatic(p_outlet_id uuid, p_date date, p_reason text, p_confirm_reset boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reset_today_queue_to_automatic(p_outlet_id uuid, p_date date, p_reason text, p_confirm_reset boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reset_today_queue_to_automatic(p_outlet_id uuid, p_date date, p_reason text, p_confirm_reset boolean) TO authenticated;


--
-- Name: FUNCTION rls_auto_enable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC;


--
-- Name: FUNCTION seed_default_therapist_working_hours(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.seed_default_therapist_working_hours() FROM PUBLIC;


--
-- Name: FUNCTION seed_therapist_queue(p_outlet_id uuid, p_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.seed_therapist_queue(p_outlet_id uuid, p_date date) FROM PUBLIC;


--
-- Name: FUNCTION set_appointment_assignment_metadata(p_appointment_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_appointment_assignment_metadata(p_appointment_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_appointment_assignment_metadata(p_appointment_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) TO authenticated;


--
-- Name: FUNCTION set_audit_fields(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_audit_fields() FROM PUBLIC;


--
-- Name: FUNCTION set_completed_therapist_allocations(p_appointment_id uuid, p_allocations jsonb, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_completed_therapist_allocations(p_appointment_id uuid, p_allocations jsonb, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_completed_therapist_allocations(p_appointment_id uuid, p_allocations jsonb, p_reason text) TO authenticated;


--
-- Name: FUNCTION start_appointment_group_service(p_group_id uuid, p_started_at timestamp with time zone, p_allow_late_extension_overlap boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.start_appointment_group_service(p_group_id uuid, p_started_at timestamp with time zone, p_allow_late_extension_overlap boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_appointment_group_service(p_group_id uuid, p_started_at timestamp with time zone, p_allow_late_extension_overlap boolean) TO authenticated;


--
-- Name: FUNCTION start_appointment_group_service(p_appointment_group_id uuid, p_appointment_ids uuid[], p_started_at timestamp with time zone, p_expected_end_by_appointment jsonb, p_allow_overlap_by_appointment jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.start_appointment_group_service(p_appointment_group_id uuid, p_appointment_ids uuid[], p_started_at timestamp with time zone, p_expected_end_by_appointment jsonb, p_allow_overlap_by_appointment jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_appointment_group_service(p_appointment_group_id uuid, p_appointment_ids uuid[], p_started_at timestamp with time zone, p_expected_end_by_appointment jsonb, p_allow_overlap_by_appointment jsonb) TO authenticated;


--
-- Name: FUNCTION start_appointment_service(p_appointment_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_allow_late_extension_overlap boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.start_appointment_service(p_appointment_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_allow_late_extension_overlap boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_appointment_service(p_appointment_id uuid, p_started_at timestamp with time zone, p_expected_end_at timestamp with time zone, p_allow_late_extension_overlap boolean) TO authenticated;


--
-- Name: FUNCTION switch_appointment_therapist(p_appointment_id uuid, p_new_therapist_id uuid, p_split_method text, p_reason text, p_assignment_source text, p_requested_gender text, p_keep_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.switch_appointment_therapist(p_appointment_id uuid, p_new_therapist_id uuid, p_split_method text, p_reason text, p_assignment_source text, p_requested_gender text, p_keep_provisional boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.switch_appointment_therapist(p_appointment_id uuid, p_new_therapist_id uuid, p_split_method text, p_reason text, p_assignment_source text, p_requested_gender text, p_keep_provisional boolean) TO authenticated;


--
-- Name: FUNCTION switch_appointment_therapist_core(p_appointment_id uuid, p_new_therapist_id uuid, p_split_method text, p_reason text, p_assignment_source text, p_requested_gender text, p_keep_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.switch_appointment_therapist_core(p_appointment_id uuid, p_new_therapist_id uuid, p_split_method text, p_reason text, p_assignment_source text, p_requested_gender text, p_keep_provisional boolean) FROM PUBLIC;


--
-- Name: FUNCTION sync_appointment_payment_status(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_appointment_payment_status() FROM PUBLIC;


--
-- Name: FUNCTION sync_business_settings_envelope(p_outlet uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_business_settings_envelope(p_outlet uuid) FROM PUBLIC;


--
-- Name: FUNCTION sync_completed_appointment_commission(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_completed_appointment_commission() FROM PUBLIC;


--
-- Name: FUNCTION sync_inherited_staff_business_hours(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_inherited_staff_business_hours() FROM PUBLIC;


--
-- Name: FUNCTION sync_room_units_for_zone(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_room_units_for_zone() FROM PUBLIC;


--
-- Name: FUNCTION sync_service_buffer_after(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_service_buffer_after() FROM PUBLIC;


--
-- Name: FUNCTION sync_staff_hours_from_business_hours(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_staff_hours_from_business_hours() FROM PUBLIC;


--
-- Name: FUNCTION today_queue_has_started(p_outlet_id uuid, p_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.today_queue_has_started(p_outlet_id uuid, p_date date) FROM PUBLIC;


--
-- Name: FUNCTION touch_business_hours_updated_at(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.touch_business_hours_updated_at() FROM PUBLIC;


--
-- Name: FUNCTION update_appointment_group_with_csp(p_appointment_group_id uuid, p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_updated_by uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_appointment_group_with_csp(p_appointment_group_id uuid, p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_updated_by uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_appointment_group_with_csp(p_appointment_group_id uuid, p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_updated_by uuid) TO authenticated;


--
-- Name: FUNCTION update_appointment_group_with_csp_concrete_legacy(p_appointment_group_id uuid, p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_updated_by uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_appointment_group_with_csp_concrete_legacy(p_appointment_group_id uuid, p_customer_id uuid, p_group_name text, p_pax_count integer, p_appointment_date date, p_allocations jsonb, p_type text, p_status text, p_notes text, p_updated_by uuid) FROM PUBLIC;


--
-- Name: FUNCTION update_appointment_with_csp(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_appointment_with_csp(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_appointment_with_csp(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) TO authenticated;


--
-- Name: FUNCTION update_appointment_with_csp_121_legacy(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_appointment_with_csp_121_legacy(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) FROM PUBLIC;


--
-- Name: FUNCTION update_appointment_with_csp_v2(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_room_unit_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_appointment_with_csp_v2(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_room_unit_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_appointment_with_csp_v2(p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date, p_start_time time without time zone, p_end_time time without time zone, p_room_unit_id uuid, p_assignment_source text, p_requested_therapist_id uuid, p_requested_gender text, p_is_provisional boolean) TO authenticated;


--
-- Name: FUNCTION validate_one_based_capacity_requirements_122s(p_requirements jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_one_based_capacity_requirements_122s(p_requirements jsonb) FROM PUBLIC;


--
-- Name: FUNCTION write_audit_log(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.write_audit_log() FROM PUBLIC;


--
-- Name: TABLE appointment_assignment_invalidations; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_assignment_invalidations TO service_role;


--
-- Name: TABLE appointment_groups; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_groups TO anon;
GRANT ALL ON TABLE public.appointment_groups TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_groups TO service_role;


--
-- Name: TABLE appointment_therapist_allocations; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_therapist_allocations TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_therapist_allocations TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_therapist_allocations TO service_role;


--
-- Name: TABLE appointment_therapist_segments; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_therapist_segments TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_therapist_segments TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.appointment_therapist_segments TO service_role;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.audit_log TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.audit_log TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.audit_log TO service_role;


--
-- Name: SEQUENCE audit_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.audit_log_id_seq TO authenticated;


--
-- Name: TABLE booking_holds; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.booking_holds TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.booking_holds TO service_role;


--
-- Name: TABLE business_hours; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.business_hours TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.business_hours TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.business_hours TO service_role;


--
-- Name: TABLE business_hours_staff_override_archive; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.business_hours_staff_override_archive TO service_role;


--
-- Name: TABLE business_settings; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.business_settings TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.business_settings TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.business_settings TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customers TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.customers TO service_role;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.notifications TO anon;
GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.notifications TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.notifications TO service_role;


--
-- Name: COLUMN notifications.read_at; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(read_at) ON TABLE public.notifications TO authenticated;


--
-- Name: TABLE online_booking_closures; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.online_booking_closures TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.online_booking_closures TO service_role;


--
-- Name: TABLE online_booking_outlet_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.online_booking_outlet_settings TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.online_booking_outlet_settings TO service_role;


--
-- Name: TABLE online_booking_service_hours; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.online_booking_service_hours TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.online_booking_service_hours TO service_role;


--
-- Name: TABLE online_booking_service_rooms; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.online_booking_service_rooms TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.online_booking_service_rooms TO service_role;


--
-- Name: TABLE online_booking_services; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.online_booking_services TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.online_booking_services TO service_role;


--
-- Name: TABLE outlets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.outlets TO anon;
GRANT ALL ON TABLE public.outlets TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.outlets TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.profiles TO service_role;


--
-- Name: TABLE room_units; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.room_units TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.room_units TO authenticated;
GRANT ALL ON TABLE public.room_units TO service_role;


--
-- Name: TABLE rooms; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.rooms TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.rooms TO service_role;


--
-- Name: TABLE service_categories; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.service_categories TO anon;
GRANT ALL ON TABLE public.service_categories TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.service_categories TO service_role;


--
-- Name: TABLE services; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.services TO authenticated;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.services TO service_role;


--
-- Name: TABLE settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.settings TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.settings TO service_role;


--
-- Name: TABLE therapist_queue; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_queue TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_queue TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_queue TO service_role;


--
-- Name: TABLE therapist_queue_day; Type: ACL; Schema: public; Owner: -
--

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_queue_day TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_queue_day TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_queue_day TO service_role;


--
-- Name: TABLE therapist_unavailability; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.therapist_unavailability TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_unavailability TO service_role;


--
-- Name: TABLE therapist_working_hours; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.therapist_working_hours TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapist_working_hours TO service_role;


--
-- Name: TABLE therapists; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.therapists TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.therapists TO service_role;


--
-- Name: TABLE transactions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.transactions TO authenticated;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.transactions TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- PostgreSQL database dump complete
--

\unrestrict WCUTRHEX31ybwXyaFzdPzypcMqZDUe8gjt6EO0ziJzZLzwk3twuthChppv77VyU

