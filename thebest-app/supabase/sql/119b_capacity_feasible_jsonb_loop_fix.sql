-- Phase 6B.1 ledger-preserving follow-up for the deployed 119b hotfix.
--
-- Confirmed evidence: capacity_feasible must iterate anonymous appointments and
-- holds as ONE jsonb value per loop row. Assigning a multi-column SELECT row to
-- the jsonb loop variable fails once anonymous capacity demand exists.
--
-- The checked-in 119 source already contains the corrected jsonb_build_object
-- loops.  The original deployed hotfix body is not available in this repository,
-- so this migration deliberately does NOT manufacture a second function body.
-- It makes the clean-database order explicit and fails closed if 119 no longer
-- contains the confirmed repair.

begin;

do $check$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.capacity_feasible(uuid,jsonb,text,uuid,uuid)'::regprocedure
  ) into v_definition;

  if position('select jsonb_build_object(''id'', a.id::text' in v_definition) = 0
     or position('select jsonb_build_object(''id'', h.id::text' in v_definition) = 0 then
    raise exception
      '119b precondition failed: capacity_feasible lacks the confirmed one-jsonb-value anonymous-demand loops';
  end if;
end;
$check$;

commit;
