drop policy if exists "services_update_staff_admin" on public.services;
create policy "services_update_staff_admin"
on public.services
for update
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());
