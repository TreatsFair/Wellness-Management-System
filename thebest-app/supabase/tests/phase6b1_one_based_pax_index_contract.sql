-- Phase 6B.1 122s SQL contract coverage.
--
-- Verifies that the one-based pax_index guard is installed in front of BOTH
-- preference-aware capacity RPCs without losing any 122r behaviour:
--   * both public wrappers validate before delegating;
--   * the renamed 122r implementations still carry the full eligibility and
--     diagnostic logic;
--   * owner-only objects (both impls + the validator) are unreachable by
--     anon/authenticated, while the public wrappers stay executable by
--     authenticated only;
--   * every malformed or zero-based pax_index is rejected with SQLSTATE 22023
--     and the one-based message, on both entry points;
--   * a valid one-based payload is NOT rejected by the guard, and 122r's own
--     pass-through validation errors are preserved verbatim.
--
-- Read-only: no rows are written. Wrapped in begin/rollback anyway so a failed
-- assertion cannot leave anything behind.

\set ON_ERROR_STOP on
begin;

do $test$
declare
  v_preview regprocedure;
  v_allocate regprocedure;
  v_preview_impl regprocedure;
  v_allocate_impl regprocedure;
  v_validator regprocedure;
  v_preview_body text;
  v_allocate_body text;
  v_preview_impl_body text;
  v_allocate_impl_body text;
  v_expected text :=
    'Every pax requirement must use a one-based pax_index starting from 1.';
  v_bad jsonb;
  v_case text;
  v_outlet uuid;
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date + 1;
  v_valid jsonb;
  v_rows integer;
  v_appt_before bigint;
  v_appt_after bigint;
  v_txn_before bigint;
  v_txn_after bigint;
  v_caught text;
  v_state text;
begin
  select count(*) into v_appt_before from public.appointments;
  select count(*) into v_txn_before from public.transactions;

  ---------------------------------------------------------------------------
  -- A. Objects exist with the expected signatures.
  ---------------------------------------------------------------------------
  v_preview := to_regprocedure(
    'public.get_counter_preference_capacity_slots(uuid,date,jsonb,uuid,uuid)'
  );
  v_allocate := to_regprocedure(
    'public.allocate_preference_provisional_slots(uuid,date,time without time zone,jsonb,uuid)'
  );
  v_preview_impl := to_regprocedure(
    'public.get_counter_preference_capacity_slots_122r_impl(uuid,date,jsonb,uuid,uuid)'
  );
  v_allocate_impl := to_regprocedure(
    'public.allocate_preference_provisional_slots_122r_impl(uuid,date,time without time zone,jsonb,uuid)'
  );
  v_validator := to_regprocedure(
    'public.validate_one_based_capacity_requirements_122s(jsonb)'
  );

  if v_preview is null or v_allocate is null then
    raise exception '122s: public preference capacity wrappers are missing';
  end if;
  if v_preview_impl is null or v_allocate_impl is null then
    raise exception '122s: renamed 122r implementations are missing';
  end if;
  if v_validator is null then
    raise exception '122s: one-based pax_index validator is missing';
  end if;

  ---------------------------------------------------------------------------
  -- B. Wrappers validate first, then delegate to the renamed 122r bodies.
  ---------------------------------------------------------------------------
  select pg_get_functiondef(v_preview) into v_preview_body;
  select pg_get_functiondef(v_allocate) into v_allocate_body;

  if v_preview_body not ilike '%validate_one_based_capacity_requirements_122s%'
     or v_preview_body not ilike '%get_counter_preference_capacity_slots_122r_impl%'
  then
    raise exception '122s: preview wrapper does not validate then delegate';
  end if;
  if v_allocate_body not ilike '%validate_one_based_capacity_requirements_122s%'
     or v_allocate_body not ilike '%allocate_preference_provisional_slots_122r_impl%'
  then
    raise exception '122s: allocator wrapper does not validate then delegate';
  end if;
  if v_preview_body not ilike '%security definer%'
     or v_allocate_body not ilike '%security definer%'
     or v_preview_body not ilike '%search_path%to%public%'
     or v_allocate_body not ilike '%search_path%to%public%'
  then
    raise exception '122s: wrappers lost security definer / pinned search_path';
  end if;

  ---------------------------------------------------------------------------
  -- C. 122r semantics survive the rename (assertions moved to the impl names).
  ---------------------------------------------------------------------------
  select pg_get_functiondef(v_preview_impl) into v_preview_impl_body;
  select pg_get_functiondef(v_allocate_impl) into v_allocate_impl_body;

  if v_preview_impl_body not ilike '%capacity_feasible%'
     or v_preview_impl_body not ilike '%requested_gender%'
     or v_preview_impl_body not ilike '%requested_therapist_id%'
     or v_preview_impl_body not ilike '%conflict_start%'
  then
    raise exception '122s: preview impl lost 122r preference diagnostics';
  end if;
  if v_allocate_impl_body not ilike '%not (t.id = any(v_used))%'
     or v_allocate_impl_body not ilike '%therapist_working_hours%'
     or v_allocate_impl_body not ilike '%therapist_unavailability%'
     or v_allocate_impl_body not ilike '%service_commissions%'
  then
    raise exception '122s: allocator impl lost full therapist eligibility';
  end if;

  ---------------------------------------------------------------------------
  -- D. ACLs: wrappers authenticated-only; impls + validator owner-only.
  ---------------------------------------------------------------------------
  if not has_function_privilege('authenticated', v_preview, 'EXECUTE')
     or not has_function_privilege('authenticated', v_allocate, 'EXECUTE')
  then
    raise exception '122s: authenticated lost EXECUTE on the public wrappers';
  end if;
  if has_function_privilege('anon', v_preview, 'EXECUTE')
     or has_function_privilege('anon', v_allocate, 'EXECUTE')
  then
    raise exception '122s: anon can execute the public wrappers';
  end if;
  if has_function_privilege('authenticated', v_preview_impl, 'EXECUTE')
     or has_function_privilege('authenticated', v_allocate_impl, 'EXECUTE')
     or has_function_privilege('anon', v_preview_impl, 'EXECUTE')
     or has_function_privilege('anon', v_allocate_impl, 'EXECUTE')
  then
    raise exception '122s: guard is bypassable — impls are not owner-only';
  end if;
  if has_function_privilege('authenticated', v_validator, 'EXECUTE')
     or has_function_privilege('anon', v_validator, 'EXECUTE')
  then
    raise exception '122s: validator is not owner-only';
  end if;

  ---------------------------------------------------------------------------
  -- E. Rejection cases. Each must raise 22023 with the one-based message,
  --    from BOTH entry points.
  ---------------------------------------------------------------------------
  for v_case, v_bad in
    select *
    from (
      values
        ('non-array object',      '{"pax_index": 1}'::jsonb),
        ('json null',             'null'::jsonb),
        ('scalar number',         '3'::jsonb),
        ('scalar string',         '"1"'::jsonb),
        ('zero-based first pax',  '[{"pax_index": 0}]'::jsonb),
        ('negative pax_index',    '[{"pax_index": -3}]'::jsonb),
        ('missing pax_index',     '[{"duration_minutes": 60}]'::jsonb),
        ('null pax_index',        '[{"pax_index": null}]'::jsonb),
        ('empty pax_index',       '[{"pax_index": ""}]'::jsonb),
        ('non-numeric pax_index', '[{"pax_index": "abc"}]'::jsonb),
        ('fractional pax_index',  '[{"pax_index": "1.5"}]'::jsonb),
        ('out-of-range pax_index','[{"pax_index": 2147483648}]'::jsonb),
        ('second pax is zero',
          '[{"pax_index": 1}, {"pax_index": 0}]'::jsonb),
        ('last pax is zero',
          '[{"pax_index": 1}, {"pax_index": 2}, {"pax_index": 0}]'::jsonb)
    ) cases(label, payload)
  loop
    v_caught := null;
    v_state := null;
    begin
      perform *
      from public.get_counter_preference_capacity_slots(
        '00000000-0000-0000-0000-000000000128'::uuid, v_date, v_bad, null, null
      );
    exception when others then
      v_caught := sqlerrm;
      v_state := sqlstate;
    end;
    if v_caught is distinct from v_expected or v_state is distinct from '22023' then
      raise exception
        '122s: preview accepted or mis-reported case "%" (sqlstate=%, message=%)',
        v_case, coalesce(v_state, '<none>'), coalesce(v_caught, '<no error>');
    end if;

    v_caught := null;
    v_state := null;
    begin
      perform *
      from public.allocate_preference_provisional_slots(
        '00000000-0000-0000-0000-000000000128'::uuid, v_date, '10:00'::time,
        v_bad, null
      );
    exception when others then
      v_caught := sqlerrm;
      v_state := sqlstate;
    end;
    if v_caught is distinct from v_expected or v_state is distinct from '22023' then
      raise exception
        '122s: allocator accepted or mis-reported case "%" (sqlstate=%, message=%)',
        v_case, coalesce(v_state, '<none>'), coalesce(v_caught, '<no error>');
    end if;
  end loop;

  ---------------------------------------------------------------------------
  -- F. The guard must not swallow 122r's own validation errors.
  --    An empty array carries no pax_index at all, so 122s passes it through
  --    and 122r must still reject it.
  ---------------------------------------------------------------------------
  v_caught := null;
  begin
    perform *
    from public.get_counter_preference_capacity_slots(
      '00000000-0000-0000-0000-000000000128'::uuid, v_date, '[]'::jsonb, null, null
    );
  exception when others then
    v_caught := sqlerrm;
  end;
  if v_caught is distinct from 'Every pax needs a capacity requirement.' then
    raise exception
      '122s: 122r empty-requirement error was not preserved (got %)',
      coalesce(v_caught, '<no error>');
  end if;

  v_caught := null;
  begin
    perform *
    from public.get_counter_preference_capacity_slots(
      '00000000-0000-0000-0000-000000000128'::uuid,
      v_date,
      '[{"pax_index": 1, "duration_minutes": 0, "room_type": "body_room"}]'::jsonb,
      null, null
    );
  exception when others then
    v_caught := sqlerrm;
  end;
  if v_caught is distinct from 'One or more therapist preferences is incomplete.'
  then
    raise exception
      '122s: 122r incomplete-preference error was not preserved (got %)',
      coalesce(v_caught, '<no error>');
  end if;

  ---------------------------------------------------------------------------
  -- G. A valid one-based payload passes the guard and reaches 122r for real.
  --
  --    The allocator's 122r body reaches public.allocate_provisional_slots,
  --    which is authz-gated (auth.uid() + is_staff_or_admin()). Impersonate a
  --    real staff profile for the transaction so the valid path is exercised
  --    end to end instead of failing on authorisation. Transaction-local.
  ---------------------------------------------------------------------------
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', (
        select p.id::text from public.profiles p
        where p.role = 'staff' order by p.id limit 1
      ),
      'role', 'authenticated'
    )::text,
    true
  );
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception '122s: could not establish a staff context for the valid path';
  end if;

  select o.id into v_outlet
  from public.outlets o
  order by o.id
  limit 1;
  if v_outlet is null then
    raise exception '122s: no outlet available to exercise a valid payload';
  end if;

  v_valid := jsonb_build_array(
    jsonb_build_object(
      'pax_index', 1,
      'assignment_source', 'queue',
      'duration_minutes', 60,
      'buffer_after_minutes', 5,
      'room_type', 'body_room',
      'service_ids', jsonb_build_array(
        (select s.id::text from public.services s
          where s.outlet_id = v_outlet order by s.id limit 1)
      )
    )
  );

  select count(*)
  into v_rows
  from public.get_counter_preference_capacity_slots(
    v_outlet, v_date, v_valid, null, null
  );
  -- Row count depends on business hours; the contract is only that the guard
  -- did not fire and 122r executed.
  if v_rows is null then
    raise exception '122s: valid one-based payload did not reach 122r';
  end if;

  select count(*)
  into v_rows
  from public.allocate_preference_provisional_slots(
    v_outlet, v_date, '10:00'::time, v_valid, null
  );
  if v_rows is null then
    raise exception '122s: valid payload rejected by the allocator wrapper';
  end if;

  ---------------------------------------------------------------------------
  -- H. No residue: the guard and both stable RPCs must not write anything.
  ---------------------------------------------------------------------------
  select count(*) into v_appt_after from public.appointments;
  select count(*) into v_txn_after from public.transactions;
  if v_appt_after <> v_appt_before or v_txn_after <> v_txn_before then
    raise exception
      '122s: contract coverage mutated data (appointments %->%, transactions %->%)',
      v_appt_before, v_appt_after, v_txn_before, v_txn_after;
  end if;

  raise notice '122s contract coverage passed: 14 rejection cases x 2 entry points, 2 pass-through errors, valid payload reaches 122r, ACLs owner-only, no residue.';
end
$test$;

rollback;
