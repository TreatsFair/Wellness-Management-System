-- Ledger-preserving assertion for the already-applied 122c hotfix.
-- This timestamp matches the remote migration ledger.

begin;

do $check$
declare
  v_definition text;
begin
  select lower(pg_get_functiondef(
    'public.confirm_and_start_group(uuid,text,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)'::regprocedure
  ))
  into v_definition;

  if position('select count(*) into v_locked from (' in v_definition) = 0
     or position('order by a.start_time, a.id for update) locked' in v_definition) = 0
     or position('select array_agg(a.id order by a.start_time, a.id)' in v_definition) = 0 then
    raise exception
      '122c precondition failed: group locking is not split from aggregation';
  end if;
end;
$check$;

commit;
