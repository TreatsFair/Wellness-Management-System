-- Phase 6B.1 ledger-preserving follow-up for the deployed 122b hotfix.
--
-- Confirmed evidence: appointment_id and appointment_group_id are OUT parameter
-- names. Transaction lookups in the idempotent branches must qualify table
-- columns and compare them to the input parameters.
--
-- The current 122 source already contains the repaired function bodies. The
-- original remote hotfix text cannot be recovered from this repository, so this
-- migration verifies the confirmed behaviour instead of inventing SQL.

begin;

do $check$
declare
  v_single text;
  v_group text;
begin
  select pg_get_functiondef(
    'public.confirm_and_start_appointment(uuid,text,time,timestamptz,boolean,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)'::regprocedure
  ) into v_single;
  select pg_get_functiondef(
    'public.confirm_and_start_group(uuid,text,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)'::regprocedure
  ) into v_group;

  if position('where t.appointment_id = p_appointment_id' in v_single) = 0
     or position('where t.appointment_group_id = p_group_id' in v_group) = 0 then
    raise exception
      '122b precondition failed: confirm-and-start idempotent transaction lookups are not OUT-parameter qualified';
  end if;
end;
$check$;

commit;
