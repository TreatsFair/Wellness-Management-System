-- Phase 6B.1 follow-up (pre-123): keep queue and gender-preference
-- appointments replaceable until the atomic service-start boundary.
--
-- 122q accepted p_therapist_id before considering assignment_source. A
-- concrete provisional ID therefore behaved like a fixed request. This
-- migration keeps 122q's payment, room, idempotency, actual-start and queue
-- consumption bodies intact behind owner-only legacy names, while:
--   * discarding stale concrete IDs for queue/gender single-pax starts;
--   * preserving specific_customer_request/manual_override IDs;
--   * finding a complete distinct-therapist combination for appointment
--     groups before entering 122q's all-or-nothing group transaction;
--   * preserving concrete walk-in selections.

do $preflight$
begin
  if to_regprocedure(
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  ) is null then
    raise exception '122t requires the applied 122q finalisation core';
  end if;
  if to_regprocedure(
    'public.finalize_and_start_appointment_group(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  ) is null then
    raise exception '122t requires the applied 122q group finaliser';
  end if;
  if to_regprocedure(
    'public.finalize_and_start_appointment(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  ) is null then
    raise exception '122t requires the applied 122q single finaliser';
  end if;
  if to_regprocedure(
    'public.finalize_and_start_appointment_core_122q_legacy(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  ) is not null
     or to_regprocedure(
       'public.finalize_and_start_appointment_122q_legacy(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
     ) is not null
     or to_regprocedure(
       'public.finalize_and_start_appointment_group_122q_legacy(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
     ) is not null then
    raise exception '122t legacy finalisation names already exist';
  end if;
end;
$preflight$;

alter function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) rename to finalize_and_start_appointment_core_122q_legacy;

alter function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment_122q_legacy;

alter function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment_group_122q_legacy;

revoke all on function public.finalize_and_start_appointment_core_122q_legacy(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

revoke all on function public.finalize_and_start_appointment_122q_legacy(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon, authenticated, service_role;

revoke all on function public.finalize_and_start_appointment_group_122q_legacy(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon, authenticated, service_role;

-- Recursive backtracking is intentional. Greedy allocation can reject a
-- feasible group when the first pax takes the only therapist eligible for a
-- later pax. Groups are small, and every recursion step is bounded by the
-- outlet's active therapists and the submitted pax count.
create or replace function public.match_finalize_start_therapists_recursive(
  p_requirements jsonb,
  p_requirement_index integer,
  p_used_therapists uuid[],
  p_outlet_id uuid,
  p_exclude_appointment_id uuid,
  p_exclude_appointment_group_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
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
$function$;

revoke all on function public.match_finalize_start_therapists_recursive(
  jsonb, integer, uuid[], uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function public.match_finalize_start_group_therapists(
  p_appointment_group_id uuid,
  p_pax_updates jsonb,
  p_started_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
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
$function$;

revoke all on function public.match_finalize_start_group_therapists(
  uuid, jsonb, timestamptz
) from public, anon, authenticated, service_role;

-- Same owner-only core signature as 122q. Every non-walk-in single appointment
-- gets a fresh eligible match; stale queue/gender IDs are ignored, while
-- specific/manual IDs constrain the matcher to that exact therapist.
-- Group-preallocated matches and concrete walk-ins are explicit exceptions.
-- The 122q body still owns the row lock, final resource revalidation,
-- confirmation, actual start and idempotent early return.
create or replace function public.finalize_and_start_appointment_core(
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
$function$;

revoke all on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

create or replace function public.finalize_and_start_appointment(
  p_appointment_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_guest_name text default '',
  p_guest_phone text default '',
  p_service_items jsonb default '[]'::jsonb,
  p_payment_items jsonb default '[]'::jsonb,
  p_therapist_id uuid default null,
  p_assignment_source text default 'queue',
  p_requested_gender text default null,
  p_room_id uuid default null,
  p_room_unit_id uuid default null,
  p_started_at timestamptz default now(),
  p_expected_end_at timestamptz default null,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default ''
)
returns table(
  success boolean,
  appointment_id uuid,
  transaction_id uuid,
  actual_started_at timestamptz,
  expected_end_at timestamp,
  therapist_id uuid,
  room_id uuid,
  room_unit_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $function$
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
$function$;

revoke all on function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;

grant execute on function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;

create or replace function public.finalize_and_start_appointment_group(
  p_appointment_group_id uuid,
  p_appointment_ids uuid[],
  p_customer_name text,
  p_customer_phone text,
  p_pax_updates jsonb default '{}'::jsonb,
  p_payment_items jsonb default '[]'::jsonb,
  p_started_at timestamptz default now(),
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default ''
)
returns table(
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  transaction_id uuid,
  actual_started_at timestamptz,
  started_count integer,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $function$
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
$function$;

revoke all on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;

grant execute on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;

comment on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) is
  '122t: ignores stale queue/gender therapist IDs and rematches at atomic start.';

comment on function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) is
  '122t: serializes single final start with the bounded outlet/date lock before live therapist matching.';

comment on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) is
  '122t: atomically matches a complete distinct therapist combination before 122q group start.';
