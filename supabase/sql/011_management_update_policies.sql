drop policy if exists "rooms_update_staff_admin" on public.rooms;
create policy "rooms_update_staff_admin"
on public.rooms
for update
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());

drop policy if exists "therapists_update_staff_admin" on public.therapists;
create policy "therapists_update_staff_admin"
on public.therapists
for update
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());
