-- Phase 6B.1 Batch 1.3 — therapist switching guards.
--
-- APPLIED TO STAGING 2026-07-26 as ledger version 20260726074030.
--
-- switch_appointment_therapist carries commission-splitting logic that must not
-- be re-derived by hand, so it is renamed to a private core and wrapped, the
-- same pattern as 122d/122e. The wrapper adds the missing validation and leaves
-- the commission behaviour untouched.
--
-- Guards added:
--   * replacement therapist must be active, a therapist, and in the same outlet
--   * reject a therapist who is MID-SERVICE on another appointment
--     (actual_started_at set, not completed, status in_progress)
--   * reject an overlapping appointment against the covered window
--   * require rostered working hours at the window start
--
-- In-progress switching IS allowed: the covered window is then measured from
-- NOW to the operational end rather than from the scheduled start, so the
-- replacement only needs to be free for the remainder. The appointment SCHEDULE
-- is never modified by this RPC.
--
-- The queue is untouched: consumption is bound to the actual_started_at
-- transition, which switching never makes, so a switch never burns a turn.
--
-- Flag awareness: the guards read concrete therapist_id/status only and behave
-- identically with capacity_first_enabled ON or OFF. Anonymous (NULL-therapist)
-- rows have nothing to switch and are rejected by the core's own SAME_THERAPIST
-- / NOT_FOUND paths.
--
-- VERIFIED transactionally before applying: switching to a therapist who is
-- mid-service on another appointment returns THERAPIST_BUSY and leaves the
-- appointment's scheduled start_time unchanged.
--
-- ROLLBACK:
--   drop function public.switch_appointment_therapist(uuid,uuid,text,text,text,text,boolean);
--   alter function public.switch_appointment_therapist_core(uuid,uuid,text,text,text,text,boolean)
--     rename to switch_appointment_therapist;
--   grant execute on function public.switch_appointment_therapist(uuid,uuid,text,text,text,text,boolean)
--     to authenticated;

alter function public.switch_appointment_therapist(uuid,uuid,text,text,text,text,boolean)
  rename to switch_appointment_therapist_core;

-- The rename carries the old ACL (which included authenticated) onto the core.
-- Lock it down so clients cannot bypass the guards.
revoke all on function public.switch_appointment_therapist_core(uuid,uuid,text,text,text,text,boolean)
  from public, anon, authenticated, service_role;

create or replace function public.switch_appointment_therapist(
  p_appointment_id uuid, p_new_therapist_id uuid,
  p_split_method text default 'service_time', p_reason text default '',
  p_assignment_source text default null, p_requested_gender text default null,
  p_keep_provisional boolean default false)
returns table(success boolean, commission_method text, error_code text, error_message text)
language plpgsql security definer set search_path = public
as $function$
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
$function$;

revoke all on function public.switch_appointment_therapist(uuid,uuid,text,text,text,text,boolean)
  from public, anon;
grant execute on function public.switch_appointment_therapist(uuid,uuid,text,text,text,text,boolean)
  to authenticated;
