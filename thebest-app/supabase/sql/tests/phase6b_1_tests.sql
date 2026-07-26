-- Phase 6B.1 repository tests.
--
-- These are safe definition/integrity checks only. They intentionally do not
-- create appointments, enable capacity_first_enabled, or contact any database.
-- Run the integration scenarios through phase6b_concurrency_harness.ps1 only
-- against an explicitly approved disposable database fixture.

begin;

do $assert$
declare
  v_definition text;
begin
  if to_regprocedure('public.capacity_feasible(uuid,jsonb,text,uuid,uuid)') is null
     or to_regprocedure('public.confirm_and_start_appointment(uuid,text,time,timestamptz,boolean,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)') is null
     or to_regprocedure('public.confirm_and_start_group(uuid,text,uuid,text,text,uuid,text,numeric,numeric,numeric,text,text,text)') is null
     or to_regprocedure('public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)') is null then
    raise exception 'Phase 6B.1 required function signature is missing';
  end if;

  select pg_get_functiondef(
    'public.update_appointment_group_with_csp(uuid,uuid,text,integer,date,jsonb,text,text,text,uuid)'::regprocedure
  ) into v_definition;
  if position('update_appointment_group_with_csp_concrete_legacy' in v_definition) = 0
     or position('public.capacity_feasible(' in v_definition) = 0
     or position('pg_advisory_xact_lock' in v_definition) = 0
     or position('v_therapist_id := null;' in v_definition) = 0
     or position('v_room_id := null;' in v_definition) = 0 then
    raise exception 'Phase 6B.1 group-update anonymous-capacity branch is incomplete';
  end if;
end;
$assert$;

rollback;

-- Required approved-fixture integration assertions (executed by the harness):
--   1. two confirm_and_start_appointment requests for one appointment;
--   2. two confirm_and_start_group requests for one group;
--   3. two future bookings for the final eligible therapist;
--   4. two future bookings for the final room slot;
--   5. final confirmation racing a walk-in; and
--   6. post-commit retry after simulated client timeout.
--
-- Each scenario must assert exactly one start transition, one actual_started_at
-- write, one payment transaction, one queue-turn consumption per therapist,
-- an idempotent result or clear capacity conflict for the loser, no partial
-- group state, and no remaining waiting locks/deadlocks. No such assertion is
-- claimed by this repository-only test file.
