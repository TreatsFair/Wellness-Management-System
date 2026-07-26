-- Ledger-preserving assertion for the already-applied 119b hotfix.
-- This timestamp matches the remote migration ledger.
-- It does not redefine capacity_feasible; it fails closed if the repaired
-- one-jsonb-object loops are missing from the preceding 119 definition.

begin;

do $check$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.capacity_feasible(uuid,jsonb,text,uuid,uuid)'::regprocedure
  )
  into v_definition;

  if position(
       'select jsonb_build_object(''id'', a.id::text'
       in lower(v_definition)
     ) = 0
     or position(
       'select jsonb_build_object(''id'', h.id::text'
       in lower(v_definition)
     ) = 0 then
    raise exception
      '119b precondition failed: capacity_feasible lacks the confirmed one-jsonb-value anonymous-demand loops';
  end if;
end;
$check$;

commit;
