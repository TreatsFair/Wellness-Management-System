-- MVP concrete resource locking.
--
-- Capacity-first migrations 118-122t remain installed and reviewable. This
-- follow-up keeps their per-outlet flag as the dormant rollback boundary, but
-- explicitly disables it for every outlet and restores concrete resource
-- ownership for the active counter flow.
--
-- Contract:
--   * queue/gender automatic choices lock the first eligible therapist in the
--     live queue when the appointment is created;
--   * specific/manual choices keep the submitted therapist;
--   * body-room zones receive an exact room_unit_id from the existing
--     assign_appointment_room_unit trigger;
--   * queue order changes only on the first actual_started_at transition;
--   * no protected-turn preference or protected-turn mutation is active;
--   * Check In & Start validates the already locked therapist and room. It
--     never rematches them.

begin;

alter table public.business_settings
  alter column capacity_first_enabled set default false;

update public.business_settings
set capacity_first_enabled = false
where capacity_first_enabled is distinct from false;

-- Existing columns are retained for rollback/audit compatibility, but their
-- values have no meaning in the MVP queue.
update public.therapist_queue
set protected_turn_owed = false,
    protected_turn_reason = null
where protected_turn_owed
   or protected_turn_reason is not null;

-- Queue-ranked concrete allocator used by counter appointment creation.
-- The historical name is retained so capacity slot preview and creation use
-- one identical eligibility/overlap decision.
create or replace function public.allocate_provisional_slots(
  p_outlet_id uuid,
  p_date date,
  p_start_time time,
  p_requirements jsonb,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  pax_index integer,
  therapist_id uuid,
  room_id uuid,
  end_time time
)
language plpgsql
stable
set search_path = public
as $function$
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
$function$;

revoke all on function public.allocate_provisional_slots(
  uuid, date, time, jsonb, uuid
) from public, anon;
grant execute on function public.allocate_provisional_slots(
  uuid, date, time, jsonb, uuid
) to authenticated;

-- The output shape remains rolling-deployment compatible, but the protected
-- field is always false and never affects ranking.
drop function if exists public.get_therapist_queue(uuid, date, time, integer);
create function public.get_therapist_queue(
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
  reservation_start_at time,
  reservation_end_at time,
  free_in_minutes integer,
  protected_turn_owed boolean,
  is_recommended boolean,
  rotation_rank bigint
)
language plpgsql
security definer
set search_path = public
as $function$
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
        order by
          queue_row.turn_consumed_at nulls first,
          queue_row.queue_position,
          queue_row.therapist_id
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
$function$;

revoke all on function public.get_therapist_queue(
  uuid, date, time, integer
) from public, anon;
grant execute on function public.get_therapist_queue(
  uuid, date, time, integer
) to authenticated;

-- Actual service start is the sole rotation boundary. The timestamp guard makes
-- the operation idempotent, and every source consumes one ordinary turn.
create or replace function public.consume_therapist_queue_turn_for_start(
  p_outlet_id uuid,
  p_queue_date date,
  p_therapist_id uuid,
  p_started_at timestamptz,
  p_appointment_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
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
$function$;

revoke all on function public.consume_therapist_queue_turn_for_start(
  uuid, date, uuid, timestamptz, uuid
) from public, anon, authenticated;

-- Convert any still-anonymous future rows before enforcing the new invariant.
-- The existing reconciler is group-aware and uses the queue without consuming
-- it. If any row cannot receive a complete resource pair, the migration fails
-- atomically instead of leaving a partially locked schedule.
do $backfill$
declare
  v_appointment record;
begin
  for v_appointment in
    select appointment.id
    from public.appointments appointment
    where appointment.actual_started_at is null
      and appointment.status::text in ('pending', 'confirmed')
      and public.csp_appointment_block_end_at(appointment)
            > now() at time zone 'Asia/Kuala_Lumpur'
      and (
        appointment.therapist_id is null
        or appointment.room_id is null
      )
    order by
      appointment.appointment_date,
      appointment.start_time,
      appointment.appointment_group_id nulls last,
      appointment.id
  loop
    perform public.reconcile_appointment_resources(
      v_appointment.id,
      true
    );
  end loop;

  if exists (
    select 1
    from public.appointments appointment
    where appointment.actual_started_at is null
      and appointment.status::text in ('pending', 'confirmed')
      and public.csp_appointment_block_end_at(appointment)
            > now() at time zone 'Asia/Kuala_Lumpur'
      and (
        appointment.therapist_id is null
        or appointment.room_id is null
      )
  ) then
    raise exception
      'Concrete locking could not assign every active future appointment.';
  end if;
end;
$backfill$;

create or replace function public.enforce_mvp_concrete_appointment()
returns trigger
language plpgsql
set search_path = public
as $function$
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
$function$;

drop trigger if exists zz_appointments_require_mvp_concrete_resources
  on public.appointments;
create trigger zz_appointments_require_mvp_concrete_resources
before insert or update of
  therapist_id,
  room_id,
  room_unit_id,
  appointment_date,
  start_time,
  end_time,
  buffer_after_minutes,
  status,
  actual_started_at
on public.appointments
for each row
execute function public.enforce_mvp_concrete_appointment();

revoke all on function public.enforce_mvp_concrete_appointment()
  from public, anon, authenticated;

-- Put 122t's flexible-at-start wrappers behind dormant names and reactivate
-- 122q's concrete validation wrappers. No prior migration is edited.
do $preflight$
begin
  if to_regprocedure(
    'public.finalize_and_start_appointment_core_122q_legacy(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  ) is null
     or to_regprocedure(
       'public.finalize_and_start_appointment_122q_legacy(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
     ) is null
     or to_regprocedure(
       'public.finalize_and_start_appointment_group_122q_legacy(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
     ) is null then
    raise exception 'MVP concrete locking requires the 122t/122q function pair.';
  end if;
end;
$preflight$;

alter function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) rename to finalize_and_start_appointment_core_122t_capacity_first_dormant;

alter function public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment_122t_capacity_first_dormant;

alter function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment_group_122t_capacity_first_dormant;

alter function public.finalize_and_start_appointment_core_122q_legacy(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) rename to finalize_and_start_appointment_core;

alter function public.finalize_and_start_appointment_122q_legacy(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment;

alter function public.finalize_and_start_appointment_group_122q_legacy(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) rename to finalize_and_start_appointment_group;

revoke all on function public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

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

revoke all on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) from public, anon;
grant execute on function public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
) to authenticated;

comment on column public.business_settings.capacity_first_enabled is
  'Dormant capacity-first rollback flag. MVP concrete locking keeps this false for both outlets.';

commit;
