-- Phase 6B.1: single-appointment create and update RPC wrappers.
--
-- Redefines create_appointment_with_csp and update_appointment_with_csp:
--   * capacity_first_enabled OFF delegates immediately to the 121 legacy code
--     with parameters passed through VERBATIM;
--   * capacity_first_enabled ON runs capacity_feasible for every create/update;
--   * deterministic advisory locks over the old and new outlet/date keys;
--   * rejects editing started / terminal / fully resource-confirmed rows
--     (flag-ON only);
--   * exact-room slot and room-type checks for manual overrides;
--   * validates specific_customer_request and manual_override restrictions;
--   * IS DISTINCT FROM guards to skip no-op updates;
--   * accepts p_is_provisional and does NOT persist it (no such column exists;
--     see migrations 122f/122g).
--
-- No explicit BEGIN/COMMIT: every supported apply mechanism already wraps a
-- migration in one transaction.
--
--
-- FLAG-OFF COMPATIBILITY NOTES (diffed against the live pg_get_functiondef of
-- both 121 functions before this file was written):
--
--   1. The deployed update_appointment_with_csp preserves requested_therapist_id
--      and requested_gender when p_assignment_source IS NULL
--      ("case when p_assignment_source is not null then ... else <old> end").
--      The delegation below therefore forwards p_assignment_source unchanged,
--      NOT a coalesced non-null value, which would silently overwrite both
--      columns with NULL on every edit that omits the source.
--
--   2. The editability guard (APPOINTMENT_NOT_EDITABLE) applies only on the
--      flag-ON path. At the time of writing 31 live appointments are unstarted,
--      non-terminal and still carry resources_confirmed_at (the deployed
--      trigger sets it for every specific_customer_request / manual_override
--      row whose room is also confirmed). Applying the guard before the flag
--      check would make all of them uneditable while the flag is OFF.
--
--
-- MANUAL_OVERRIDE RELEASE SEMANTICS (Step 2C) — KNOWN LIMITATION:
--
--   The RPC signature takes bare UUIDs, so it cannot distinguish "parameter
--   omitted" from "parameter explicitly NULL". This migration therefore adopts
--   an unambiguous, conservative rule and does NOT guess:
--
--     * a manual_override edit PRESERVES an existing resource only when that
--       dimension is genuinely protected (*_assignment_state = 'confirmed');
--     * an unprotected (pending / auto_assigned) dimension is taken from the
--       parameter as given, including NULL;
--     * a protected dimension can never be silently released or swapped by
--       this RPC.
--
--   Consequence, stated plainly: switching a therapist-locked appointment to
--   room-only (or the reverse) is NOT supported by this RPC and is NOT claimed
--   to work. Releasing a protected dimension requires either changing
--   p_assignment_source to 'queue'/'gender_preference' (which releases both
--   dimensions to anonymous capacity), or a later explicit patch RPC carrying
--   separate clear/keep flags per dimension. That RPC is out of scope for
--   Phase 6B.1 and is not implemented here.
--
--
-- SPECIFIC_CUSTOMER_REQUEST ROOM RULE:
--   On create, an explicitly supplied room is discarded. This is the documented
--   Project B rule, not an accident — PROJECT_GUIDE/14_PROJECT_B_CAPACITY_FIRST
--   _DESIGN_2026-07-23.md §9: "insert one appointments row per pax as ANONYMOUS
--   demand (therapist_id=NULL unless requested/manual; room_id=NULL; ...)".
--   A requested therapist is a concrete exception on the therapist dimension
--   only; the room stays anonymous until check-in. On update, an already
--   protected room is preserved rather than discarded.

do $preflight$
begin
  if to_regprocedure(
       'public.create_appointment_with_csp(uuid,uuid,uuid,uuid,date,time without time zone,time without time zone,numeric,text,uuid,text,jsonb,integer,text,uuid,text,uuid,text,boolean)'
     ) is null then
    raise exception '122e requires create_appointment_with_csp';
  end if;

  if to_regprocedure(
       'public.update_appointment_with_csp(uuid,uuid,uuid,date,time without time zone,time without time zone,text,uuid,text,boolean)'
     ) is null then
    raise exception '122e requires update_appointment_with_csp';
  end if;

  if to_regprocedure(
       'public.create_appointment_with_csp_121_legacy(uuid,uuid,uuid,uuid,date,time without time zone,time without time zone,numeric,text,uuid,text,jsonb,integer,text,uuid,text,uuid,text,boolean)'
     ) is not null then
    raise exception
      '122e cannot continue: create_appointment_with_csp_121_legacy already exists';
  end if;

  if to_regprocedure(
       'public.update_appointment_with_csp_121_legacy(uuid,uuid,uuid,date,time without time zone,time without time zone,text,uuid,text,boolean)'
     ) is not null then
    raise exception
      '122e cannot continue: update_appointment_with_csp_121_legacy already exists';
  end if;

  if to_regprocedure(
       'public.capacity_feasible(uuid,jsonb,text,uuid,uuid)'
     ) is null then
    raise exception '122e requires capacity_feasible';
  end if;
end;
$preflight$;

alter function public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) rename to create_appointment_with_csp_121_legacy;

alter function public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) rename to update_appointment_with_csp_121_legacy;

-- Step 2A: the renames carried the deployed ACL (postgres + authenticated) onto
-- the legacy names. Revoke every client role so the legacy bodies are reachable
-- only from inside the SECURITY DEFINER wrappers, which execute as the owner.
revoke all on function public.create_appointment_with_csp_121_legacy(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) from public, anon, authenticated, service_role;

revoke all on function public.update_appointment_with_csp_121_legacy(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) from public, anon, authenticated, service_role;

create or replace function public.create_appointment_with_csp(
  p_customer_id uuid, p_therapist_id uuid, p_room_id uuid, p_service_id uuid,
  p_date date, p_start_time time without time zone, p_end_time time without time zone,
  p_total_price numeric, p_type text default 'appointment'::text,
  p_created_by uuid default auth.uid(), p_service_name text default ''::text,
  p_service_items jsonb default '[]'::jsonb, p_item_count integer default 1,
  p_notes text default ''::text, p_appointment_group_id uuid default null::uuid,
  p_assignment_source text default 'queue'::text, p_requested_therapist_id uuid default null::uuid,
  p_requested_gender text default null::text, p_is_provisional boolean default false)
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path = pg_catalog, public
as $function$
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

  -- Walk-ins are in-progress by definition: normalize_appointment_assignment_states
  -- forces both assignment states to 'confirmed' and stamps resources_confirmed_at
  -- for type='walkin', and CHECK appointments_started_requires_concrete then
  -- demands a concrete therapist AND room. An anonymous walk-in is therefore
  -- unrepresentable; walk-ins always take the concrete path.
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
      -- Project B §9: the room stays anonymous until check-in.
      v_room_id := null;
    elsif v_source = 'manual_override' then
      if v_therapist_id is null and v_room_id is null then
        success := false; appointment_id := null; error_code := 'MANUAL_RESOURCE_REQUIRED';
        error_message := 'A manual override must lock a therapist, a room, or both.'; return next; return;
      end if;
      v_requested_therapist := coalesce(v_requested_therapist, v_therapist_id);
    else
      -- queue and gender_preference: both dimensions anonymous.
      v_therapist_id := null;
      v_room_id := null;
      v_requested_therapist := null;
    end if;

    -- Same advisory key as prevent_appointment_resource_overlap.
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

    -- Independent exact-room check when a specific room is manually locked.
    if v_room_id is not null then
      select coalesce(sum(greatest(coalesce(r.total_slots, 1), 1)), 0)
      into v_room_total_slots
      from public.rooms r
      where r.id = v_room_id
        and r.outlet_id = v_outlet
        and coalesce(r.is_active, true)
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
      where h.assigned_room_id = v_room_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at + make_interval(mins => greatest(v_buffer, 0))
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_start_at;

      if v_room_overlap_count + v_hold_overlap_count >= v_room_total_slots then
        success := false; appointment_id := null; error_code := 'ROOM_FULL';
        error_message := 'The selected room is full for the requested time.'; return next; return;
      end if;
    end if;

    v_feasible := public.capacity_feasible(
      v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', p_service_id::text,
        'room_type', v_room_type, 'requested_gender', p_requested_gender,
        'requested_therapist_id', case when v_source = 'specific_customer_request' then v_requested_therapist::text else null end,
        'manual_lock_id', case when v_source = 'manual_override' and v_therapist_id is not null then v_therapist_id::text else null end,
        'pax_index', 0)),
      'hard');

    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough capacity for the requested time.';
      return next; return;
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
      v_start_at at time zone 'Asia/Kuala_Lumpur',
      v_end_at at time zone 'Asia/Kuala_Lumpur',
      coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb),
      greatest(coalesce(p_item_count, 1), 1), coalesce(p_notes, ''), now(), p_created_by,
      v_source, v_requested_therapist, p_requested_gender,
      case when v_therapist_id is not null then 'confirmed'::text else 'pending'::text end,
      case when v_room_id is not null then 'confirmed'::text else 'pending'::text end,
      v_outlet)
    returning id into appointment_id;

    success := true; error_code := null; error_message := null; return next; return;
  end if;

  -- Legacy/concrete branch. Every parameter is forwarded verbatim.
  return query select * from public.create_appointment_with_csp_121_legacy(
    p_customer_id, p_therapist_id, p_room_id, p_service_id, p_date, p_start_time, p_end_time,
    p_total_price, p_type, p_created_by, p_service_name, p_service_items, p_item_count,
    p_notes, p_appointment_group_id, p_assignment_source, p_requested_therapist_id,
    p_requested_gender, p_is_provisional
  );
end;
$function$;

create or replace function public.update_appointment_with_csp(
  p_appointment_id uuid, p_therapist_id uuid, p_room_id uuid, p_date date,
  p_start_time time without time zone, p_end_time time without time zone,
  p_assignment_source text default null::text, p_requested_therapist_id uuid default null::uuid,
  p_requested_gender text default null::text, p_is_provisional boolean default null::boolean)
returns table(success boolean, appointment_id uuid, error_code text, error_message text)
language plpgsql security definer set search_path = pg_catalog, public
as $function$
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

    -- Step 2D: protected rows are never mutated through the booking-edit RPC.
    -- Flag-ON only; see the header note about the 31 unstarted rows that carry
    -- resources_confirmed_at today.
    if v_appt.actual_started_at is not null
       or v_appt.resources_confirmed_at is not null
       or v_appt.status::text in ('in_progress', 'completed', 'cancelled', 'no_show') then
      success := false; appointment_id := null; error_code := 'APPOINTMENT_NOT_EDITABLE';
      error_message := 'Started, terminal, or fully resource-confirmed appointments cannot be edited.';
      return next; return;
    end if;

    -- The service cannot be changed by this RPC, so v_outlet is derived from the
    -- same service as the stored row. Assert it anyway: a cross-outlet move must
    -- never be reachable here.
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

      -- An already protected room survives; an unprotected one goes anonymous.
      v_room_id := case when v_protect_room then v_appt.room_id else null end;

    elsif v_source = 'manual_override' then
      -- See the header limitation note: a protected dimension is preserved and
      -- can never be swapped or released here.
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
      -- queue and gender_preference release both dimensions to anonymous
      -- capacity. This is the only supported way to clear a manual lock.
      v_therapist_id := null;
      v_room_id := null;
      v_requested_therapist := null;
    end if;

    -- Lock old and new outlet/date keys in deterministic order.
    perform set_config('lock_timeout', '2s', true);
    begin
      for v_lock_row in
        select distinct o_id, d_val
        from (
          values (v_appt.outlet_id, v_appt.appointment_date), (v_outlet, p_date)
        ) v(o_id, d_val)
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
      select coalesce(sum(greatest(coalesce(r.total_slots, 1), 1)), 0)
      into v_room_total_slots
      from public.rooms r
      where r.id = v_room_id
        and r.outlet_id = v_outlet
        and coalesce(r.is_active, true)
        and lower(trim(coalesce(nullif(r.room_type, ''), r.type::text, ''))) = v_room_type;

      if coalesce(v_room_total_slots, 0) = 0 then
        success := false; appointment_id := null; error_code := 'INVALID_ROOM';
        error_message := 'The selected room is inactive, in another outlet, or the wrong room type for this service.';
        return next; return;
      end if;

      select count(*) into v_room_overlap_count
      from public.appointments a
      where a.room_id = v_room_id
        and a.id is distinct from p_appointment_id
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < v_end_at + make_interval(mins => greatest(v_buffer, 0))
        and public.csp_appointment_block_end_at(a) > v_start_at;

      select count(*) into v_hold_overlap_count
      from public.booking_holds h
      where h.assigned_room_id = v_room_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at + make_interval(mins => greatest(v_buffer, 0))
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_start_at;

      if v_room_overlap_count + v_hold_overlap_count >= v_room_total_slots then
        success := false; appointment_id := null; error_code := 'ROOM_FULL';
        error_message := 'The selected room is full for the requested time.'; return next; return;
      end if;
    end if;

    v_feasible := public.capacity_feasible(
      v_outlet,
      jsonb_build_array(jsonb_build_object(
        'start', to_char(v_start_at, 'YYYY-MM-DD HH24:MI:SS'),
        'duration_minutes', ceil(extract(epoch from (v_end_at - v_start_at)) / 60.0)::int,
        'buffer_after_minutes', v_buffer, 'service_id', v_appt.service_id::text,
        'room_type', v_room_type, 'requested_gender', p_requested_gender,
        'requested_therapist_id', case when v_source = 'specific_customer_request' then v_requested_therapist::text else null end,
        'manual_lock_id', case when v_source = 'manual_override' and v_therapist_id is not null then v_therapist_id::text else null end,
        'pax_index', 0)),
      'hard',
      p_appointment_id);

    if not coalesce((v_feasible ->> 'feasible')::boolean, false) then
      success := false; appointment_id := null;
      error_code := case when v_feasible ->> 'dimension' = 'room' then 'ROOM_FULL' else 'THERAPIST_UNAVAILABLE' end;
      error_message := 'Not enough capacity for the new time.'; return next; return;
    end if;

    -- Step 2D: each dimension's state follows only its own concrete resource.
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

  -- Legacy/concrete branch. p_assignment_source is forwarded VERBATIM: the
  -- deployed body keys requested_therapist_id / requested_gender preservation
  -- off it being NULL.
  return query select * from public.update_appointment_with_csp_121_legacy(
    p_appointment_id, p_therapist_id, p_room_id, p_date, p_start_time, p_end_time,
    p_assignment_source, p_requested_therapist_id, p_requested_gender, p_is_provisional
  );
end;
$function$;

-- Restore exactly the deployed wrapper ACLs (postgres + authenticated). Neither
-- deployed function granted service_role; this migration does not widen that.
revoke all on function public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) from public, anon, service_role;

grant execute on function public.create_appointment_with_csp(
  uuid, uuid, uuid, uuid, date, time without time zone, time without time zone,
  numeric, text, uuid, text, jsonb, integer, text, uuid, text, uuid, text, boolean
) to authenticated;

revoke all on function public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) from public, anon, service_role;

grant execute on function public.update_appointment_with_csp(
  uuid, uuid, uuid, date, time without time zone, time without time zone,
  text, uuid, text, boolean
) to authenticated;
