begin;

-- Staff may browse the service catalogue, but only administrators may change
-- service definitions. The existing services_admin_all policy continues to
-- cover every administrator operation; these explicit policies make the
-- intended insert/update boundary clear even if the baseline is replayed.
drop policy if exists "services_insert_staff_admin" on public.services;
drop policy if exists "services_update_staff_admin" on public.services;
drop policy if exists "services_insert_admin" on public.services;
drop policy if exists "services_update_admin" on public.services;

create policy "services_insert_admin"
on public.services
for insert
to authenticated
with check (public.is_admin());

create policy "services_update_admin"
on public.services
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Staff can continue maintaining ordinary staff information. Commission-rate
-- overrides are a separate admin-only concern and cannot be changed by sending
-- a direct Data API update that bypasses the Flutter interface.
create or replace function public.protect_therapist_commission_overrides()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.commission_overrides, '{}'::jsonb) <> '{}'::jsonb
       and not public.is_admin() then
      raise exception using
        errcode = '42501',
        message = 'Only an administrator can set staff commission overrides.';
    end if;
  elsif new.commission_overrides is distinct from old.commission_overrides
        and not public.is_admin() then
    raise exception using
      errcode = '42501',
      message = 'Only an administrator can change staff commission overrides.';
  end if;

  return new;
end;
$function$;

revoke all on function public.protect_therapist_commission_overrides()
  from public, anon, authenticated;

drop trigger if exists therapists_commission_overrides_admin_only
  on public.therapists;
create trigger therapists_commission_overrides_admin_only
  before insert or update of commission_overrides on public.therapists
  for each row execute function
    public.protect_therapist_commission_overrides();

commit;
