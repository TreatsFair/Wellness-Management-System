\set ON_ERROR_STOP on

-- Static contract coverage for migration 122t. These assertions deliberately
-- avoid production fixtures. Run the existing disposable concurrency harness
-- for end-to-end lock, payment and queue-consumption coverage.

begin;

do $contract$
declare
  v_core regprocedure;
  v_group regprocedure;
  v_matcher regprocedure;
  v_recursive regprocedure;
  v_legacy_core regprocedure;
  v_legacy_single regprocedure;
  v_legacy_group regprocedure;
  v_core_body text;
  v_group_body text;
  v_matcher_body text;
  v_recursive_body text;
  v_legacy_core_body text;
begin
  v_core := to_regprocedure(
    'public.finalize_and_start_appointment_core(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  );
  v_group := to_regprocedure(
    'public.finalize_and_start_appointment_group(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );
  v_matcher := to_regprocedure(
    'public.match_finalize_start_group_therapists(uuid,jsonb,timestamptz)'
  );
  v_recursive := to_regprocedure(
    'public.match_finalize_start_therapists_recursive(jsonb,integer,uuid[],uuid,uuid,uuid)'
  );
  v_legacy_core := to_regprocedure(
    'public.finalize_and_start_appointment_core_122q_legacy(uuid,text,text,text,text,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz)'
  );
  v_legacy_single := to_regprocedure(
    'public.finalize_and_start_appointment_122q_legacy(uuid,text,text,text,text,jsonb,jsonb,uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );
  v_legacy_group := to_regprocedure(
    'public.finalize_and_start_appointment_group_122q_legacy(uuid,uuid[],text,text,jsonb,jsonb,timestamptz,uuid,text,numeric,numeric,numeric,text,text)'
  );

  if v_core is null or v_group is null or v_matcher is null
     or v_recursive is null or v_legacy_core is null
     or v_legacy_single is null
     or v_legacy_group is null then
    raise exception '122t flexible final-start functions are missing';
  end if;

  select pg_get_functiondef(v_core) into v_core_body;
  select pg_get_functiondef(v_group) into v_group_body;
  select pg_get_functiondef(v_matcher) into v_matcher_body;
  select pg_get_functiondef(v_recursive) into v_recursive_body;
  select pg_get_functiondef(v_legacy_core) into v_legacy_core_body;

  -- Regression: a stale provisional therapist must be discarded for queue and
  -- gender bookings so the 122q queue allocator can choose a live alternative.
  if v_core_body not ilike '%v_effective_therapist%'
     or v_core_body not ilike
        '%match_finalize_start_therapists_recursive%'
     or v_core_body not ilike
        '%finalize_and_start_appointment_core_122q_legacy%' then
    raise exception 'stale flexible therapist replacement is not wired';
  end if;

  -- Regression: exact customer requests and staff overrides stay fixed.
  if v_core_body not ilike '%specific_customer_request%'
     or v_core_body not ilike '%manual_override%'
     or v_recursive_body not ilike '%fixed_therapist_id%' then
    raise exception 'fixed therapist sources are not preserved';
  end if;

  -- Regression: gender remains an eligibility constraint during rematching.
  if v_matcher_body not ilike '%requested_gender%'
     or v_recursive_body not ilike '%therapist.gender%'
     or v_recursive_body not ilike '%gender_preference%' then
    raise exception 'gender preference is not preserved by final matching';
  end if;

  -- Regression: multi-pax matching must find a complete distinct combination,
  -- not greedily commit one pax before the remaining pax are feasible.
  if v_recursive_body not ilike
       '%match_finalize_start_therapists_recursive%'
     or v_recursive_body not ilike '%p_used_therapists%'
     or v_recursive_body not ilike '%array_append%'
     or v_group_body not ilike '%NO_THERAPIST_COMBINATION%'
     or v_group_body not ilike '%pg_advisory_xact_lock%'
     or v_group_body not ilike '%app.final_start_preallocated%' then
    raise exception 'atomic multi-pax rematching contract is incomplete';
  end if;

  -- Regression: no-alternative failure remains clear, while the legacy body
  -- retains its row lock and idempotent actual-start early return.
  if v_legacy_core_body not ilike
       '%No eligible therapist is available to start this service.%'
     or v_legacy_core_body not ilike '%for update%'
     or v_legacy_core_body not ilike '%actual_started_at is not null%' then
    raise exception 'no-alternative or idempotent start behavior drifted';
  end if;

  if has_function_privilege('authenticated', v_core, 'EXECUTE')
     or has_function_privilege('authenticated', v_matcher, 'EXECUTE')
     or has_function_privilege('authenticated', v_recursive, 'EXECUTE')
     or has_function_privilege('authenticated', v_legacy_core, 'EXECUTE')
     or has_function_privilege('authenticated', v_legacy_single, 'EXECUTE')
     or has_function_privilege('authenticated', v_legacy_group, 'EXECUTE')
     or has_function_privilege('anon', v_group, 'EXECUTE') then
    raise exception '122t helper or wrapper ACL is too broad';
  end if;
end
$contract$;

rollback;
