-- Rollback for 122d.
-- Preconditions: capacity_first_enabled must be OFF for all outlets and there
-- must be no anonymous group appointment that the legacy function could receive.

begin;

do $preflight$
begin
  if exists (
    select 1
    from public.business_settings bs
    where bs.capacity_first_enabled
  ) then
    raise exception
      'Disable capacity_first_enabled for every outlet before rolling back 122d';
  end if;

  if exists (
    select 1
    from public.appointments a
    where a.appointment_group_id is not null
      and a.actual_started_at is null
      and a.status::text in ('pending', 'confirmed')
      and (a.therapist_id is null or a.room_id is null)
  ) then
    raise exception
      'Re-concretise anonymous future group appointments before rolling back 122d';
  end if;
end;
$preflight$;

drop function if exists public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
);

alter function public.update_appointment_group_with_csp_concrete_legacy(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) rename to update_appointment_group_with_csp;

-- 122d revoked every client role from the legacy name. The rename carries that
-- locked-down ACL back onto the public name, so the deployed grant
-- (postgres + authenticated) must be restored explicitly.
revoke all on function public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) from public, anon, service_role;

grant execute on function public.update_appointment_group_with_csp(
  uuid, uuid, text, integer, date, jsonb, text, text, text, uuid
) to authenticated;

create or replace function public.normalize_appointment_assignment_states()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  new.therapist_assignment_state := coalesce(
    nullif(new.therapist_assignment_state, ''),
    'pending'
  );
  new.room_assignment_state := coalesce(
    nullif(new.room_assignment_state, ''),
    'pending'
  );

  if new.actual_started_at is not null
     or new.status::text in ('in_progress', 'completed')
     or new.type::text = 'walkin' then
    new.therapist_assignment_state := 'confirmed';
    new.room_assignment_state := 'confirmed';
    new.resources_confirmed_at := coalesce(
      new.resources_confirmed_at,
      new.actual_started_at,
      now()
    );
    new.resources_confirmed_by := coalesce(
      new.resources_confirmed_by,
      auth.uid()
    );
  elsif new.assignment_source in (
    'specific_customer_request',
    'manual_override'
  ) then
    new.therapist_assignment_state := 'confirmed';
  end if;

  if new.therapist_assignment_state = 'auto_assigned' then
    new.therapist_auto_assigned_at := coalesce(
      new.therapist_auto_assigned_at,
      now()
    );
  end if;

  if new.therapist_assignment_state = 'confirmed'
     and new.room_assignment_state = 'confirmed' then
    new.resources_confirmed_at := coalesce(
      new.resources_confirmed_at,
      now()
    );
  end if;

  return new;
end;
$function$;

commit;
