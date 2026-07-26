-- Ledger-preserving assertion for the already-applied 122b hotfix.
-- This timestamp matches the remote migration ledger.

begin;

do $check$
declare
  v_single text;
  v_group text;
begin
  select lower(pg_get_functiondef(
    'public.confirm_and_start_appointment(uuid,text,time,timestamptz,boolean,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)'::regprocedure
  ))
  into v_single;

  select lower(pg_get_functiondef(
    'public.confirm_and_start_group(uuid,text,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)'::regprocedure
  ))
  into v_group;

  if position('where t.appointment_id = p_appointment_id' in v_single) = 0
     or position('where t.appointment_group_id = p_group_id' in v_group) = 0 then
    raise exception
      '122b precondition failed: confirm-and-start idempotent transaction lookups are not OUT-parameter qualified';
  end if;
end;
$check$;

commit;
