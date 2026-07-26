-- 119_capacity_feasible_engine.sql
-- Phase 6A / Project B. Additive, READ-ONLY "shadow" capacity engine. These
-- functions are wired to NOTHING (no trigger, no RPC, no booking path). They do
-- not read or write any production behaviour; they only *compute* a feasibility
-- verdict so we can validate the algorithm against the live
-- check_walkin_protects_future results before it ever gates a write (that wiring
-- is migration 121+). Nothing here creates rows or enables capacity-first.
--
-- STATUS: UNVERIFIED against a database in this repo (production is the only DB
-- and must not run untested DDL). Validate in a scratch project using
-- tests/phase6a_tests.sql (parity + false-feasible) before relying on it.

begin;

-- ---------------------------------------------------------------------------
-- Exact bipartite matching (Kuhn's algorithm). Decides whether every demand can
-- be matched to a DISTINCT eligible therapist. This is what makes the engine
-- provably correct instead of a greedy per-bucket count that can report a false
-- feasible. p_adjacency: { "<demand_key>": ["<therapist_id>", ...], ... }.
-- Therapist/demand counts per outlet are tiny, so plain Kuhn is more than fast
-- enough.
-- ---------------------------------------------------------------------------

-- One augmenting DFS from a single demand. State (match + visited) is threaded
-- through the return value so recursion stays purely functional (plpgsql has no
-- by-reference args). Returns {"ok":bool,"match":{tid:did},"visited":{tid:true}}.
create or replace function public.capacity_kuhn_augment(
  p_demand   text,
  p_adjacency jsonb,
  p_match    jsonb,
  p_visited  jsonb
)
returns jsonb
language plpgsql
immutable
as $function$
declare
  v_t   text;
  v_m   jsonb := p_match;
  v_vis jsonb := p_visited;
  v_res jsonb;
begin
  for v_t in
    select jsonb_array_elements_text(coalesce(p_adjacency -> p_demand, '[]'::jsonb))
  loop
    if v_vis ? v_t then
      continue;
    end if;
    v_vis := v_vis || jsonb_build_object(v_t, true);

    if not (v_m ? v_t) then
      -- therapist v_t is free: match it to this demand
      v_m := v_m || jsonb_build_object(v_t, p_demand);
      return jsonb_build_object('ok', true, 'match', v_m, 'visited', v_vis);
    else
      -- try to re-route the demand currently holding v_t
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
$function$;

-- True iff a matching exists that saturates EVERY demand key.
create or replace function public.capacity_bipartite_saturates(p_adjacency jsonb)
returns boolean
language plpgsql
immutable
as $function$
declare
  v_d   text;
  v_m   jsonb := '{}'::jsonb;
  v_res jsonb;
begin
  if p_adjacency is null then
    return true;
  end if;
  for v_d in select jsonb_object_keys(p_adjacency) loop
    -- fresh visited set per source demand (standard Kuhn)
    v_res := public.capacity_kuhn_augment(v_d, p_adjacency, v_m, '{}'::jsonb);
    if not (v_res ->> 'ok')::boolean then
      return false;   -- this demand cannot be matched -> not saturable
    end if;
    v_m := v_res -> 'match';
  end loop;
  return true;
end;
$function$;

revoke all on function public.capacity_kuhn_augment(text, jsonb, jsonb, jsonb)
  from public, anon;
revoke all on function public.capacity_bipartite_saturates(jsonb)
  from public, anon;

-- ---------------------------------------------------------------------------
-- capacity_feasible: interval-exact, read-only feasibility verdict.
--
-- p_demands: JSON array; each element:
--   {
--     "start": "YYYY-MM-DD HH:MM:SS",        -- local (Asia/Kuala_Lumpur)
--     "duration_minutes": 60,
--     "buffer_after_minutes": 5,
--     "service_id": "<uuid>",
--     "room_type": "body_room",
--     "requested_gender": "Female" | null,
--     "requested_therapist_id": "<uuid>" | null,   -- specific_customer_request
--     "manual_lock_id": "<uuid>" | null,           -- manual_override
--     "pax_index": 0
--   }
-- p_mode: 'hard' (paid) or 'soft' (unpaid) -- identical math; caller decides the
--   consequence. Returned in the verdict for the caller's use.
--
-- Returns: { "feasible": bool, "mode": text,
--            "dimension": "therapist"|"room"|null, "at": timestamp|null,
--            "room_type": text|null }
--
-- Interval-exactness: the timeline is partitioned at every point where supply or
-- demand can change (proposed/appointment/hold start,end,end+buffer; therapist
-- shift start/end; unavailability start/end). Supply+demand are constant within a
-- segment, so evaluating each segment's start instant is exact for the interval.
-- ---------------------------------------------------------------------------
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
set search_path to 'public'
as $function$
declare
  v_min timestamp;
  v_max timestamp;
  v_now timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_points timestamp[];
  c timestamp;
  v_supply text[];
  v_adjacency jsonb;
  v_demand jsonb;
  v_key text;
  v_eligible text[];
  v_rt text;
  v_needed integer;
  v_slots integer;
  v_used integer;
begin
  if p_demands is null or jsonb_array_length(p_demands) = 0 then
    return jsonb_build_object('feasible', true, 'mode', p_mode);
  end if;

  select
    min((d ->> 'start')::timestamp),
    max((d ->> 'start')::timestamp
        + make_interval(mins => (d ->> 'duration_minutes')::int
            + greatest(coalesce((d ->> 'buffer_after_minutes')::int, 0), 0)))
  into v_min, v_max
  from jsonb_array_elements(p_demands) d;

  -- Segment boundary points across the window (deduped, only those >= now).
  select array_agg(distinct pt order by pt)
  into v_points
  from (
    -- proposed demand start / end / end+buffer
    select (d ->> 'start')::timestamp as pt
      from jsonb_array_elements(p_demands) d
    union
    select (d ->> 'start')::timestamp
           + make_interval(mins => (d ->> 'duration_minutes')::int)
      from jsonb_array_elements(p_demands) d
    union
    select (d ->> 'start')::timestamp
           + make_interval(mins => (d ->> 'duration_minutes')::int
               + greatest(coalesce((d ->> 'buffer_after_minutes')::int, 0), 0))
      from jsonb_array_elements(p_demands) d
    -- existing appointment start / block-end within window
    union
    select public.csp_appointment_start_at(a)
      from public.appointments a
      where a.outlet_id = p_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null
             or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_appointment_start_at(a) < v_max
        and public.csp_appointment_block_end_at(a) > v_min
    union
    select public.csp_appointment_block_end_at(a)
      from public.appointments a
      where a.outlet_id = p_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null
             or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_appointment_start_at(a) < v_max
        and public.csp_appointment_block_end_at(a) > v_min
    -- booking-hold start / end+buffer within window
    union
    select (h.start_at at time zone 'Asia/Kuala_Lumpur')
      from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_max
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_min
    union
    select ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
             at time zone 'Asia/Kuala_Lumpur')
      from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < v_max
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > v_min
    -- therapist shift boundaries (supply changes) across the window's dates
    union
    select gs.d + wh.start_time
      from generate_series(v_min::date - 1, v_max::date, interval '1 day') gs(d)
      join public.therapists th on th.outlet_id = p_outlet_id
        and coalesce(th.availability_status, true)
        and lower(coalesce(th.role, 'therapist')) = 'therapist'
      join public.therapist_working_hours wh on wh.therapist_id = th.id
        and wh.day_of_week = extract(dow from gs.d)::int
    union
    select gs.d + wh.end_time
           + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
      from generate_series(v_min::date - 1, v_max::date, interval '1 day') gs(d)
      join public.therapists th on th.outlet_id = p_outlet_id
        and coalesce(th.availability_status, true)
        and lower(coalesce(th.role, 'therapist')) = 'therapist'
      join public.therapist_working_hours wh on wh.therapist_id = th.id
        and wh.day_of_week = extract(dow from gs.d)::int
    -- unavailability boundaries (supply changes)
    union
    select (u.starts_at at time zone 'Asia/Kuala_Lumpur')
      from public.therapist_unavailability u
      join public.therapists th on th.id = u.therapist_id and th.outlet_id = p_outlet_id
      where (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_max
        and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_min
    union
    select (u.ends_at at time zone 'Asia/Kuala_Lumpur')
      from public.therapist_unavailability u
      join public.therapists th on th.id = u.therapist_id and th.outlet_id = p_outlet_id
      where (u.starts_at at time zone 'Asia/Kuala_Lumpur') < v_max
        and (u.ends_at at time zone 'Asia/Kuala_Lumpur') > v_min
  ) pts
  where pt >= greatest(v_min, v_now)
    and pt < v_max;

  if v_points is null then
    v_points := array[greatest(v_min, v_now)];
  end if;

  foreach c in array v_points loop
    -- SUPPLY: eligible therapists at c NOT already concretely committed.
    select array_agg(th.id::text)
    into v_supply
    from public.therapists th
    where th.outlet_id = p_outlet_id
      and coalesce(th.availability_status, true)
      and lower(coalesce(th.role, 'therapist')) = 'therapist'
      -- within a working shift at c (handles overnight shifts)
      and exists (
        select 1 from public.therapist_working_hours wh
        where wh.therapist_id = th.id
          and (
            (wh.day_of_week = extract(dow from c::date)::int
             and c::date + wh.start_time <= c
             and c::date + wh.end_time
                 + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end > c)
            or (wh.end_time <= wh.start_time
                and wh.day_of_week = extract(dow from c::date - 1)::int
                and (c::date - 1) + wh.start_time <= c
                and (c::date - 1) + wh.end_time + interval '1 day' > c)
          )
      )
      -- not on leave/unavailability at c
      and not exists (
        select 1 from public.therapist_unavailability u
        where u.therapist_id = th.id
          and (u.starts_at at time zone 'Asia/Kuala_Lumpur') <= c
          and (u.ends_at   at time zone 'Asia/Kuala_Lumpur') >  c
      )
      -- not holding a CONCRETE appointment at c (that therapist is busy)
      and not exists (
        select 1 from public.appointments a
        where a.therapist_id = th.id
          and a.id is distinct from p_exclude_appointment_id
          and (p_exclude_group_id is null
               or a.appointment_group_id is distinct from p_exclude_group_id)
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) <= c
          and public.csp_appointment_block_end_at(a) > c
      )
      -- not held by a CONCRETE (requested/manual) online hold at c
      and not exists (
        select 1 from public.booking_holds h
        where h.assigned_therapist_id = th.id
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
          and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= c
          and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
                at time zone 'Asia/Kuala_Lumpur') > c
      );

    v_supply := coalesce(v_supply, array[]::text[]);

    -- DEMAND -> eligible-therapist adjacency for demands active at c.
    -- Active demands = proposed demands + anonymous existing appts + anonymous
    -- holds (concrete existing already removed from supply above). While the
    -- feature flag is off there are no anonymous existing rows, so this reduces
    -- to the proposed demands only (the shadow-parity case).
    v_adjacency := '{}'::jsonb;

    -- proposed demands
    for v_demand in select * from jsonb_array_elements(p_demands) loop
      if (v_demand ->> 'start')::timestamp <= c
         and (v_demand ->> 'start')::timestamp
             + make_interval(mins => (v_demand ->> 'duration_minutes')::int
                 + greatest(coalesce((v_demand ->> 'buffer_after_minutes')::int, 0), 0)) > c
      then
        v_key := 'p' || (v_demand ->> 'pax_index');
        select array_agg(t)
        into v_eligible
        from unnest(v_supply) t
        join public.therapists th on th.id = t::uuid
        where
          -- gender
          (v_demand ->> 'requested_gender' is null
           or lower(th.gender) = lower(v_demand ->> 'requested_gender'))
          -- service eligibility ({} means "can do all services")
          and (
            th.service_commissions = '{}'::jsonb
            or th.service_commissions ? (v_demand ->> 'service_id')
          )
          -- exact request (specific_customer_request)
          and (v_demand ->> 'requested_therapist_id' is null
               or th.id = (v_demand ->> 'requested_therapist_id')::uuid)
          -- manual lock (manual_override)
          and (v_demand ->> 'manual_lock_id' is null
               or th.id = (v_demand ->> 'manual_lock_id')::uuid);
        v_adjacency := v_adjacency
          || jsonb_build_object(v_key, to_jsonb(coalesce(v_eligible, array[]::text[])));
      end if;
    end loop;

    -- anonymous existing appointments active at c (therapist_id IS NULL).
    -- NOTE (119b fix): build a jsonb object per row; a multi-column FOR loop into a
    -- jsonb variable is a runtime error once anonymous rows exist.
    for v_demand in
      select jsonb_build_object('id', a.id::text, 'service_id', a.service_id::text,
               'requested_gender', a.requested_gender,
               'requested_therapist_id', a.requested_therapist_id::text) as j
      from public.appointments a
      where a.outlet_id = p_outlet_id
        and a.therapist_id is null
        and a.actual_started_at is null
        and public.csp_blocks_schedule(a.status::text)
        and a.id is distinct from p_exclude_appointment_id
        and (p_exclude_group_id is null
             or a.appointment_group_id is distinct from p_exclude_group_id)
        and public.csp_appointment_start_at(a) <= c
        and public.csp_appointment_block_end_at(a) > c
    loop
      v_key := 'a' || (v_demand ->> 'id');
      select array_agg(t)
      into v_eligible
      from unnest(v_supply) t
      join public.therapists th on th.id = t::uuid
      where (v_demand ->> 'requested_gender' is null
             or lower(th.gender) = lower(v_demand ->> 'requested_gender'))
        and (th.service_commissions = '{}'::jsonb
             or th.service_commissions ? (v_demand ->> 'service_id'))
        and (v_demand ->> 'requested_therapist_id' is null
             or th.id = (v_demand ->> 'requested_therapist_id')::uuid);
      v_adjacency := v_adjacency
        || jsonb_build_object(v_key, to_jsonb(coalesce(v_eligible, array[]::text[])));
    end loop;

    -- anonymous online holds active at c (assigned_therapist_id IS NULL).
    -- NOTE (119b fix): build a jsonb object per row (see anonymous-appt loop above).
    for v_demand in
      select jsonb_build_object('id', h.id::text, 'therapist_preference', h.therapist_preference) as j
      from public.booking_holds h
      where h.outlet_id = p_outlet_id
        and h.assigned_therapist_id is null
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= c
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
              at time zone 'Asia/Kuala_Lumpur') > c
    loop
      v_key := 'h' || (v_demand ->> 'id');
      select array_agg(t)
      into v_eligible
      from unnest(v_supply) t
      join public.therapists th on th.id = t::uuid
      where (v_demand ->> 'therapist_preference' is null
             or v_demand ->> 'therapist_preference' in ('none', 'specific')
             or lower(th.gender) = lower(v_demand ->> 'therapist_preference'));
      v_adjacency := v_adjacency
        || jsonb_build_object(v_key, to_jsonb(coalesce(v_eligible, array[]::text[])));
    end loop;

    -- THERAPIST feasibility: exact matching must saturate all active demands.
    if jsonb_typeof(v_adjacency) = 'object'
       and (select count(*) from jsonb_object_keys(v_adjacency)) > 0
       and not public.capacity_bipartite_saturates(v_adjacency)
    then
      return jsonb_build_object(
        'feasible', false, 'mode', p_mode,
        'dimension', 'therapist', 'at', c, 'room_type', null
      );
    end if;

    -- ROOM feasibility per room_type among active proposed demands.
    for v_rt in
      select distinct lower(trim(d ->> 'room_type'))
      from jsonb_array_elements(p_demands) d
      where (d ->> 'start')::timestamp <= c
        and (d ->> 'start')::timestamp
            + make_interval(mins => (d ->> 'duration_minutes')::int
                + greatest(coalesce((d ->> 'buffer_after_minutes')::int, 0), 0)) > c
    loop
      select count(*) into v_needed
      from jsonb_array_elements(p_demands) d
      where lower(trim(d ->> 'room_type')) = v_rt
        and (d ->> 'start')::timestamp <= c
        and (d ->> 'start')::timestamp
            + make_interval(mins => (d ->> 'duration_minutes')::int
                + greatest(coalesce((d ->> 'buffer_after_minutes')::int, 0), 0)) > c;

      select coalesce(sum(greatest(coalesce(r.total_slots, 1), 1)), 0)
      into v_slots
      from public.rooms r
      where r.outlet_id = p_outlet_id
        and coalesce(r.is_active, true)
        and lower(coalesce(r.room_type::text, '')) = v_rt;

      v_used := (
        select count(*)
        from public.appointments a
        join public.rooms r on r.id = a.room_id
        where a.room_id is not null
          and r.outlet_id = p_outlet_id
          and lower(coalesce(r.room_type::text, '')) = v_rt
          and a.id is distinct from p_exclude_appointment_id
          and (p_exclude_group_id is null
               or a.appointment_group_id is distinct from p_exclude_group_id)
          and public.csp_blocks_schedule(a.status::text)
          and public.csp_appointment_start_at(a) <= c
          and public.csp_appointment_block_end_at(a) > c
      ) + (
        select count(*)
        from public.booking_holds h
        join public.rooms r on r.id = h.assigned_room_id
        where h.assigned_room_id is not null
          and r.outlet_id = p_outlet_id
          and lower(coalesce(r.room_type::text, '')) = v_rt
          and h.status = 'pending_payment'
          and h.expires_at > now()
          and coalesce(h.hold_kind, '') <> 'staff_walkin_draft'
          and (h.start_at at time zone 'Asia/Kuala_Lumpur') <= c
          and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
                at time zone 'Asia/Kuala_Lumpur') > c
      );

      if v_used + v_needed > v_slots then
        return jsonb_build_object(
          'feasible', false, 'mode', p_mode,
          'dimension', 'room', 'at', c, 'room_type', v_rt
        );
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'feasible', true, 'mode', p_mode, 'dimension', null, 'at', null, 'room_type', null
  );
end;
$function$;

revoke all on function public.capacity_feasible(uuid, jsonb, text, uuid, uuid)
  from public, anon;
-- Intentionally NOT granted to any booking path. Shadow use only:
--   grant execute ... to authenticated;  -- (add only when validated & wired, 121+)

comment on function public.capacity_feasible(uuid, jsonb, text, uuid, uuid) is
  'Project B SHADOW engine (migration 119): interval-exact, read-only capacity feasibility with exact bipartite therapist matching + per-room_type slot capacity. Wired to nothing; validate before use.';

commit;
