-- Phase 6B.1 correctness fix: anonymous room demand.
--
-- Verified against the deployed pg_get_functiondef of
-- public.capacity_feasible(uuid,jsonb,text,uuid,uuid) (migration 119b,
-- remote ledger version 20260723164513):
--
--   * the therapist pass already adds anonymous appointments and anonymous
--     holds as demand nodes in the bipartite graph, but
--   * the room pass only counts rows with a CONCRETE room_id
--     (appointments joined to rooms, holds joined to rooms).
--
-- Once Migration 121 starts creating anonymous appointments, those rows still
-- consume their service's room_type capacity and must be counted.
--
-- This migration renames the deployed 119b body to a private legacy core and
-- wraps it with one additional room pass that, for each room_type actually
-- requested by the proposal, counts:
--   * proposed demands,
--   * concrete appointments,
--   * anonymous appointments (room type derived from services.room_type),
--   * concrete active booking holds, and
--   * anonymous active holds whose online_booking_service_id identifies a
--     service.
--
-- Deliberate scope limits:
--   * The extra pass only ever turns a feasible verdict into an infeasible
--     one; it never relaxes 119b.
--   * Only room types present in p_demands are evaluated. Evaluating unrelated
--     room types would let pre-existing overbooking of an unrelated type
--     reject an unrelated booking.
--   * A degenerate (zero-length) demand window returns 119b's verdict
--     unchanged rather than inventing a new failure mode.
--
-- Feature flags and existing data are not changed.
-- Deployed ACL of capacity_feasible is postgres-only; that is preserved for
-- both the wrapper and the renamed legacy core.

do $preflight$
begin
  if to_regprocedure(
       'public.capacity_feasible(uuid,jsonb,text,uuid,uuid)'
     ) is null then
    raise exception '119c requires public.capacity_feasible(uuid,jsonb,text,uuid,uuid)';
  end if;

  if to_regprocedure(
       'public.capacity_feasible_119b_legacy(uuid,jsonb,text,uuid,uuid)'
     ) is not null then
    raise exception
      '119c cannot continue: capacity_feasible_119b_legacy already exists';
  end if;
end;
$preflight$;

alter function public.capacity_feasible(
  uuid, jsonb, text, uuid, uuid
) rename to capacity_feasible_119b_legacy;

-- Step 2A: renaming preserves the old ACL. Lock the legacy core down so no
-- client role can reach it directly and bypass the anonymous-room pass.
revoke all on function public.capacity_feasible_119b_legacy(
  uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function public.capacity_feasible(
  p_outlet_id uuid,
  p_demands jsonb,
  p_mode text default 'hard',
  p_exclude_appointment_id uuid default null,
  p_exclude_group_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $function$
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
    p_outlet_id,
    p_demands,
    p_mode,
    p_exclude_appointment_id,
    p_exclude_group_id
  );

  -- Never relax 119b.
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
          mins =>
            (d ->> 'duration_minutes')::integer
            + greatest(
                coalesce((d ->> 'buffer_after_minutes')::integer, 0),
                0
              )
        )
    )
  into v_min, v_max
  from jsonb_array_elements(p_demands) d;

  -- Degenerate window: keep 119b's verdict rather than inventing a failure.
  if v_min is null or v_max is null or v_max <= v_min then
    return v_base;
  end if;

  -- Checkpoints: proposal boundaries plus the boundaries of every appointment
  -- and hold that overlaps the proposal window, so a room-type peak that
  -- starts part-way through the proposal is still evaluated.
  select array_agg(distinct point order by point)
  into v_points
  from (
    select (d ->> 'start')::timestamp as point
    from jsonb_array_elements(p_demands) d

    union
    select
      (d ->> 'start')::timestamp
      + make_interval(mins => (d ->> 'duration_minutes')::integer)
    from jsonb_array_elements(p_demands) d

    union
    select
      (d ->> 'start')::timestamp
      + make_interval(
          mins =>
            (d ->> 'duration_minutes')::integer
            + greatest(
                coalesce((d ->> 'buffer_after_minutes')::integer, 0),
                0
              )
        )
    from jsonb_array_elements(p_demands) d

    union
    select public.csp_appointment_start_at(a)
    from public.appointments a
    where a.outlet_id = p_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.id is distinct from p_exclude_appointment_id
      and (
        p_exclude_group_id is null
        or a.appointment_group_id is distinct from p_exclude_group_id
      )
      and public.csp_appointment_start_at(a) < v_max
      and public.csp_appointment_block_end_at(a) > v_min

    union
    select public.csp_appointment_block_end_at(a)
    from public.appointments a
    where a.outlet_id = p_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.id is distinct from p_exclude_appointment_id
      and (
        p_exclude_group_id is null
        or a.appointment_group_id is distinct from p_exclude_group_id
      )
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
      and (
        (
          h.end_at
          + make_interval(
              mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
            )
        ) at time zone 'Asia/Kuala_Lumpur'
      ) > v_min

    union
    select
      (
        h.end_at
        + make_interval(
            mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
          )
      ) at time zone 'Asia/Kuala_Lumpur'
    from public.booking_holds h
    where h.outlet_id = p_outlet_id
      and h.status = 'pending_payment'
      and h.expires_at > now()
      and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_max
      and (
        (
          h.end_at
          + make_interval(
              mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
            )
        ) at time zone 'Asia/Kuala_Lumpur'
      ) > v_min
  ) boundaries
  where point >= greatest(v_min, v_now)
    and point < v_max;

  if v_points is null then
    v_points := array[greatest(v_min, v_now)];
  end if;

  foreach v_point in array v_points loop
    -- Only room types the proposal itself requests are evaluated.
    for v_room_type in
      select distinct lower(trim(d ->> 'room_type'))
      from jsonb_array_elements(p_demands) d
      where nullif(lower(trim(d ->> 'room_type')), '') is not null
        and (d ->> 'start')::timestamp <= v_point
        and (
          (d ->> 'start')::timestamp
          + make_interval(
              mins =>
                (d ->> 'duration_minutes')::integer
                + greatest(
                    coalesce((d ->> 'buffer_after_minutes')::integer, 0),
                    0
                  )
            )
        ) > v_point
    loop
      select coalesce(
        sum(greatest(coalesce(r.total_slots, 1), 1)),
        0
      )
      into v_slots
      from public.rooms r
      where r.outlet_id = p_outlet_id
        and coalesce(r.is_active, true)
        and lower(
          trim(
            coalesce(
              nullif(r.room_type, ''),
              r.type::text,
              ''
            )
          )
        ) = v_room_type;

      select count(*)
      into v_proposed
      from jsonb_array_elements(p_demands) d
      where lower(trim(d ->> 'room_type')) = v_room_type
        and (d ->> 'start')::timestamp <= v_point
        and (
          (d ->> 'start')::timestamp
          + make_interval(
              mins =>
                (d ->> 'duration_minutes')::integer
                + greatest(
                    coalesce((d ->> 'buffer_after_minutes')::integer, 0),
                    0
                  )
            )
        ) > v_point;

      select count(*)
      into v_concrete_appointments
      from public.appointments a
      join public.rooms r on r.id = a.room_id
      where a.outlet_id = p_outlet_id
        and a.room_id is not null
        and a.id is distinct from p_exclude_appointment_id
        and (
          p_exclude_group_id is null
          or a.appointment_group_id is distinct from p_exclude_group_id
        )
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) <= v_point
        and public.csp_appointment_block_end_at(a) > v_point
        and lower(
          trim(
            coalesce(
              nullif(r.room_type, ''),
              r.type::text,
              ''
            )
          )
        ) = v_room_type;

      -- The 119b gap: anonymous appointments consume their service room type.
      select count(*)
      into v_anonymous_appointments
      from public.appointments a
      join public.services s on s.id = a.service_id
      where a.outlet_id = p_outlet_id
        and a.room_id is null
        and a.id is distinct from p_exclude_appointment_id
        and (
          p_exclude_group_id is null
          or a.appointment_group_id is distinct from p_exclude_group_id
        )
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
        and (
          (
            h.end_at
            + make_interval(
                mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
              )
          ) at time zone 'Asia/Kuala_Lumpur'
        ) > v_point
        and lower(
          trim(
            coalesce(
              nullif(r.room_type, ''),
              r.type::text,
              ''
            )
          )
        ) = v_room_type;

      select count(*)
      into v_anonymous_holds
      from public.booking_holds h
      join public.online_booking_services obs
        on obs.id = h.online_booking_service_id
      join public.services s on s.id = obs.service_id
      where h.outlet_id = p_outlet_id
        and h.assigned_room_id is null
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= v_point
        and (
          (
            h.end_at
            + make_interval(
                mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)
              )
          ) at time zone 'Asia/Kuala_Lumpur'
        ) > v_point
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
$function$;

-- Matches the deployed ACL exactly: postgres only. capacity_feasible is an
-- internal engine reached through SECURITY DEFINER RPCs, never by a client.
revoke all on function public.capacity_feasible(
  uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated, service_role;
