BEGIN;

grant usage on schema public to authenticated;

revoke all on table public.profiles from anon;
revoke all on table public.customers from anon;
revoke all on table public.therapists from anon;
revoke all on table public.rooms from anon;
revoke all on table public.services from anon;
revoke all on table public.appointments from anon;
revoke all on table public.transactions from anon;
revoke all on table public.settings from anon;

grant select, insert, update, delete on table public.profiles to authenticated;
grant select, insert, update, delete on table public.customers to authenticated;
grant select, insert, update, delete on table public.therapists to authenticated;
grant select, insert, update, delete on table public.rooms to authenticated;
grant select, insert, update, delete on table public.services to authenticated;
grant select, insert, update, delete on table public.appointments to authenticated;
grant select, insert, update, delete on table public.transactions to authenticated;
grant select, insert, update, delete on table public.settings to authenticated;

grant usage, select on all sequences in schema public to authenticated;

alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.therapists enable row level security;
alter table public.rooms enable row level security;
alter table public.services enable row level security;
alter table public.appointments enable row level security;
alter table public.transactions enable row level security;
alter table public.settings enable row level security;

create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
  select role
  from public.profiles
  where id = auth.uid()
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  )
$$;

create or replace function public.is_staff_or_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role in ('admin', 'staff')
  )
$$;

revoke all on function public.current_user_role() from public;
revoke all on function public.is_admin() from public;
revoke all on function public.is_staff_or_admin() from public;

grant execute on function public.current_user_role() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_staff_or_admin() to authenticated;

drop policy if exists "profiles_select_authenticated" on public.profiles;
create policy "profiles_select_authenticated"
on public.profiles
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "profiles_admin_all" on public.profiles;
create policy "profiles_admin_all"
on public.profiles
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "customers_select_staff_admin" on public.customers;
create policy "customers_select_staff_admin"
on public.customers
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "customers_insert_staff_admin" on public.customers;
create policy "customers_insert_staff_admin"
on public.customers
for insert
to authenticated
with check (public.is_staff_or_admin());

drop policy if exists "customers_update_staff_admin" on public.customers;
create policy "customers_update_staff_admin"
on public.customers
for update
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());

drop policy if exists "customers_delete_admin" on public.customers;
create policy "customers_delete_admin"
on public.customers
for delete
to authenticated
using (public.is_admin());

drop policy if exists "therapists_select_staff_admin" on public.therapists;
create policy "therapists_select_staff_admin"
on public.therapists
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "therapists_admin_all" on public.therapists;
create policy "therapists_admin_all"
on public.therapists
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "therapists_insert_staff_admin" on public.therapists;
create policy "therapists_insert_staff_admin"
on public.therapists
for insert
to authenticated
with check (public.is_staff_or_admin());

drop policy if exists "rooms_select_staff_admin" on public.rooms;
create policy "rooms_select_staff_admin"
on public.rooms
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "rooms_admin_all" on public.rooms;
create policy "rooms_admin_all"
on public.rooms
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "rooms_insert_staff_admin" on public.rooms;
create policy "rooms_insert_staff_admin"
on public.rooms
for insert
to authenticated
with check (public.is_staff_or_admin());

drop policy if exists "services_select_staff_admin" on public.services;
create policy "services_select_staff_admin"
on public.services
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "services_admin_all" on public.services;
create policy "services_admin_all"
on public.services
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "services_insert_staff_admin" on public.services;
create policy "services_insert_staff_admin"
on public.services
for insert
to authenticated
with check (public.is_staff_or_admin());

drop policy if exists "appointments_select_staff_admin" on public.appointments;
create policy "appointments_select_staff_admin"
on public.appointments
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "appointments_insert_staff_admin" on public.appointments;
create policy "appointments_insert_staff_admin"
on public.appointments
for insert
to authenticated
with check (public.is_staff_or_admin());

drop policy if exists "appointments_update_staff_admin" on public.appointments;
create policy "appointments_update_staff_admin"
on public.appointments
for update
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());

drop policy if exists "appointments_delete_admin" on public.appointments;
create policy "appointments_delete_admin"
on public.appointments
for delete
to authenticated
using (public.is_admin());

drop policy if exists "transactions_select_staff_admin" on public.transactions;
create policy "transactions_select_staff_admin"
on public.transactions
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "transactions_insert_staff_admin" on public.transactions;
create policy "transactions_insert_staff_admin"
on public.transactions
for insert
to authenticated
with check (public.is_staff_or_admin());

drop policy if exists "transactions_update_admin" on public.transactions;
create policy "transactions_update_admin"
on public.transactions
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "transactions_delete_admin" on public.transactions;
create policy "transactions_delete_admin"
on public.transactions
for delete
to authenticated
using (public.is_admin());

drop policy if exists "settings_select_staff_admin" on public.settings;
create policy "settings_select_staff_admin"
on public.settings
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "settings_admin_all" on public.settings;
create policy "settings_admin_all"
on public.settings
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

COMMIT;
