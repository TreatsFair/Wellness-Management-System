-- Dashboard -> Staff is an operational screen used by both staff and admins.
-- Keep public online-booking configuration admin-only, but allow authenticated
-- staff/admin users to manage therapist schedules and leave.

grant select, insert, update, delete on table
  public.therapist_working_hours,
  public.therapist_unavailability
to authenticated;

drop policy if exists therapist_working_hours_admin_all
  on public.therapist_working_hours;
drop policy if exists therapist_working_hours_staff_admin_all
  on public.therapist_working_hours;

create policy therapist_working_hours_staff_admin_all
on public.therapist_working_hours
for all
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());

drop policy if exists therapist_unavailability_admin_all
  on public.therapist_unavailability;
drop policy if exists therapist_unavailability_staff_admin_all
  on public.therapist_unavailability;

create policy therapist_unavailability_staff_admin_all
on public.therapist_unavailability
for all
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());

