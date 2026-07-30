--
-- 000001_recovery_continue_after_platform_function.sql
--
-- Target : erjttzhownsxohpvzjbs  (Treats PRODUCTION, ap-southeast-1)
-- Purpose: resume a PARTIALLY APPLIED 000001_baseline_public.sql.
-- Status : DRAFT — NOT APPLIED.
--
-- WHY THIS FILE EXISTS
-- The first production apply of the restore-ready baseline ran without
-- --single-transaction, so each statement committed as it went. It stopped at:
--
--     ERROR: function "rls_auto_enable" already exists with same argument types
--
-- public.rls_auto_enable() is a Supabase PLATFORM object, present in every new
-- project and backing the platform event trigger `ensure_rls`. The dump carried
-- staging's copy of it, which collided. Its definition was verified byte-for-byte
-- identical to production's (same body, same SECURITY DEFINER, same
-- search_path=pg_catalog, same owner), so nothing was lost by removing it from
-- the baseline.
--
-- Everything BEFORE that statement committed successfully: 161 application
-- functions, 7 enum types, and the `appointments` table (pulled forward by
-- pg_dump because later functions depend on its row type). ON_ERROR_STOP=1 then
-- aborted psql, so NOTHING after the failed statement ran.
--
-- This file therefore contains the untouched remainder of the corrected
-- baseline, in its original order, starting at the function immediately after
-- the removed platform block.
--
-- IT MUST NOT BE USED ON AN EMPTY PROJECT. For a fresh project, apply the
-- corrected 000001_baseline_public.sql instead. The preflight guard below
-- enforces that.
--
-- DOES NOT:
--   * repeat any statement that already committed
--   * contain CREATE FUNCTION public.rls_auto_enable()
--   * touch or drop the `ensure_rls` event trigger
--   * alter the platform function's ownership or permissions
--   * contain any configuration seed or operational data
--   * contain any password, URL, connection string or secret
--
-- MUST be applied with --single-transaction and ON_ERROR_STOP=1 so a failure
-- rolls the whole thing back. See README.md.
--

estrict WCUTRHEX31ybwXyaFzdPzypcMqZDUe8gjt6EO0ziJzZLzwk3twuthChppv77VyU

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

-- ============================================================================
-- PREFLIGHT GUARD — refuses to run unless production is in the known
-- partially-applied failure state. Aborts before any later statement.
-- ============================================================================
DO $preflight$
DECLARE
  v_tables    bigint;
  v_functions bigint;
  v_enums     bigint;
  v_policies  bigint;
  v_triggers  bigint;
  v_indexes   bigint;
  v_appts     boolean;
  v_platform  boolean;
  v_evt       boolean;
  v_problems  text := '';
BEGIN
  SELECT count(*) INTO v_tables
    FROM information_schema.tables
   WHERE table_schema='public' AND table_type='BASE TABLE';

  SELECT count(*) INTO v_functions
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public';

  SELECT count(*) INTO v_enums
    FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
   WHERE n.nspname='public' AND t.typtype='e';

  SELECT count(*) INTO v_policies
    FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public';

  SELECT count(*) INTO v_triggers
    FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND NOT tg.tgisinternal;

  SELECT count(*) INTO v_indexes
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='i';

  SELECT EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema='public' AND table_name='appointments')
    INTO v_appts;

  SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                  WHERE n.nspname='public' AND p.proname='rls_auto_enable')
    INTO v_platform;

  SELECT EXISTS (
      SELECT 1 FROM pg_event_trigger et
       JOIN pg_proc p ON p.oid = et.evtfoid
       JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE et.evtname='ensure_rls'
         AND n.nspname='public'
         AND p.proname='rls_auto_enable')
    INTO v_evt;

  IF v_tables    <> 1   THEN v_problems := v_problems || format('  base tables: expected 1, found %s%s', v_tables, chr(10)); END IF;
  IF NOT v_appts        THEN v_problems := v_problems || '  public.appointments is missing' || chr(10); END IF;
  IF v_functions <> 162 THEN v_problems := v_problems || format('  public functions: expected 162, found %s%s', v_functions, chr(10)); END IF;
  IF v_enums     <> 7   THEN v_problems := v_problems || format('  enum types: expected 7, found %s%s', v_enums, chr(10)); END IF;
  IF v_policies  <> 0   THEN v_problems := v_problems || format('  policies: expected 0, found %s%s', v_policies, chr(10)); END IF;
  IF v_triggers  <> 0   THEN v_problems := v_problems || format('  ordinary triggers: expected 0, found %s%s', v_triggers, chr(10)); END IF;
  IF v_indexes   <> 0   THEN v_problems := v_problems || format('  indexes: expected 0, found %s%s', v_indexes, chr(10)); END IF;
  IF NOT v_platform     THEN v_problems := v_problems || '  public.rls_auto_enable() is missing' || chr(10); END IF;
  IF NOT v_evt          THEN v_problems := v_problems || '  event trigger ensure_rls -> public.rls_auto_enable() not found' || chr(10); END IF;

  IF v_problems <> '' THEN
    RAISE EXCEPTION
      E'PREFLIGHT FAILED. Production is not in the expected partially-applied state.
%
Do NOT continue. Re-inspect the project. If it is EMPTY, apply the corrected 000001_baseline_public.sql instead of this recovery file.',
      v_problems;
  END IF;

  RAISE NOTICE 'Preflight OK: partially-applied state confirmed (1 table, 162 functions, 7 enums, 0 policies/triggers/indexes). Resuming.';
END
$preflight$;


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

