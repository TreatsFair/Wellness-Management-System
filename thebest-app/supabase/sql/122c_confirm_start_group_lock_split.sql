-- Phase 6B.1 ledger-preserving follow-up for the deployed 122c hotfix.
--
-- Confirmed evidence: PostgreSQL rejects FOR UPDATE with aggregate queries.
-- confirm_and_start_group must lock member rows in a non-aggregate subquery,
-- then run the aggregate in a separate query.
--
-- The checked-in 122 definition already has that form. No unverified remote
-- body is reconstructed here.

begin;

do $check$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.confirm_and_start_group(uuid,text,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)'::regprocedure
  ) into v_definition;

  if position('select count(*) into v_locked from (' in v_definition) = 0
     or position('order by a.start_time, a.id for update) locked' in v_definition) = 0
     or position('select array_agg(a.id order by a.start_time, a.id)' in v_definition) = 0 then
    raise exception
      '122c precondition failed: group locking is not split from aggregation';
  end if;
end;
$check$;

commit;
