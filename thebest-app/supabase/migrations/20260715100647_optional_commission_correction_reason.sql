-- The allocation change itself, actor, and timestamp remain audited. A staff
-- note is useful context but is not required to save a correction.

create or replace function public.set_completed_therapist_allocations(
  p_appointment_id uuid,
  p_allocations jsonb,
  p_reason text
)
returns table (success boolean, error_code text, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total numeric;
  v_item jsonb;
  v_therapist_id uuid;
  v_share numeric;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin permission required';
  end if;
  if not exists (
    select 1 from public.appointments
    where id = p_appointment_id and status = 'completed'
  ) then
    success := false; error_code := 'NOT_COMPLETED';
    error_message := 'Only completed services can be corrected in history.';
    return next; return;
  end if;
  if jsonb_typeof(p_allocations) is distinct from 'array'
    or jsonb_array_length(p_allocations) = 0 then
    success := false; error_code := 'INVALID_ALLOCATIONS';
    error_message := 'At least one therapist allocation is required.';
    return next; return;
  end if;

  select coalesce(sum((value ->> 'commission_share')::numeric), 0)
  into v_total from jsonb_array_elements(p_allocations);
  if abs(v_total - 1) > 0.0001 then
    success := false; error_code := 'INVALID_TOTAL';
    error_message := 'Commission shares must total 100%.';
    return next; return;
  end if;
  if (
    select count(*) <> count(distinct value ->> 'therapist_id')
    from jsonb_array_elements(p_allocations)
  ) then
    success := false; error_code := 'DUPLICATE_THERAPIST';
    error_message := 'Each therapist can appear only once.';
    return next; return;
  end if;

  delete from public.appointment_therapist_allocations
  where appointment_id = p_appointment_id;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_item ->> 'therapist_id')::uuid;
    v_share := (v_item ->> 'commission_share')::numeric;
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method,
      reason, created_by
    ) values (
      p_appointment_id, v_therapist_id, v_share, 'manual',
      coalesce(trim(p_reason), ''), auth.uid()
    );
  end loop;

  perform public.recalculate_appointment_therapist_commission(p_appointment_id);
  success := true; error_code := null; error_message := null;
  return next;
end;
$$;

revoke all on function public.set_completed_therapist_allocations(uuid, jsonb, text) from public, anon;
grant execute on function public.set_completed_therapist_allocations(uuid, jsonb, text) to authenticated;
