-- Multi-outlet foundation and public booking payment holds.
-- Existing operational data belongs to PV128. Taman Wahyu starts separately.

create table if not exists public.outlets (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  address text not null default '',
  phone text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.outlets (id, code, name, address, is_active)
values
  (
    '00000000-0000-0000-0000-000000000128',
    'pv128',
    'PV128',
    'G13-A, PV128, Jalan Genting Kelang',
    true
  ),
  (
    '00000000-0000-0000-0000-000000000002',
    'taman-wahyu',
    'Taman Wahyu',
    '50G, Jalan Seri Utara 1, Taman Wahyu',
    true
  )
on conflict (id) do update
set code = excluded.code,
    name = excluded.name,
    address = excluded.address,
    is_active = excluded.is_active,
    updated_at = now();

grant select on table public.outlets to anon, authenticated;
grant insert, update, delete on table public.outlets to authenticated;
alter table public.outlets enable row level security;

drop policy if exists "outlets_public_read_active" on public.outlets;
create policy "outlets_public_read_active"
on public.outlets
for select
to anon, authenticated
using (is_active);

drop policy if exists "outlets_admin_all" on public.outlets;
create policy "outlets_admin_all"
on public.outlets
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Keep the legacy integer business-settings key for app compatibility, but
-- make each row belong to exactly one outlet.
alter table public.business_settings
  drop constraint if exists business_settings_id_check;

alter table public.business_settings
  add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;

update public.business_settings
set outlet_id = '00000000-0000-0000-0000-000000000128'
where outlet_id is null;

update public.business_settings
set open_time = '10:30', close_time = '23:00'
where outlet_id = '00000000-0000-0000-0000-000000000128';

insert into public.business_settings (id, outlet_id, open_time, close_time)
values (2, '00000000-0000-0000-0000-000000000002', '11:00', '23:00')
on conflict (id) do update
set outlet_id = excluded.outlet_id;

alter table public.business_settings
  alter column outlet_id set not null;

create unique index if not exists business_settings_outlet_id_uidx
  on public.business_settings(outlet_id);

-- All existing records are assigned to PV128. New records are required to
-- carry the active outlet id.
alter table public.customers add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;
alter table public.therapists add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;
alter table public.rooms add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;
alter table public.services add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;
alter table public.appointments add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;
alter table public.transactions add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;
alter table if exists public.appointment_groups add column if not exists outlet_id uuid references public.outlets(id) on delete restrict;

update public.customers set outlet_id = '00000000-0000-0000-0000-000000000128' where outlet_id is null;
update public.therapists set outlet_id = '00000000-0000-0000-0000-000000000128' where outlet_id is null;
update public.rooms set outlet_id = '00000000-0000-0000-0000-000000000128' where outlet_id is null;
update public.services set outlet_id = '00000000-0000-0000-0000-000000000128' where outlet_id is null;
update public.appointments set outlet_id = '00000000-0000-0000-0000-000000000128' where outlet_id is null;
update public.transactions set outlet_id = '00000000-0000-0000-0000-000000000128' where outlet_id is null;
update public.appointment_groups set outlet_id = '00000000-0000-0000-0000-000000000128' where outlet_id is null;

alter table public.customers alter column outlet_id set not null;
alter table public.therapists alter column outlet_id set not null;
alter table public.rooms alter column outlet_id set not null;
alter table public.services alter column outlet_id set not null;
alter table public.appointments alter column outlet_id set not null;
alter table public.transactions alter column outlet_id set not null;
-- Group RPCs create the group before their child appointments. The first child
-- assigns the group outlet atomically through the trigger below.

create index if not exists customers_outlet_id_idx on public.customers(outlet_id);
create index if not exists therapists_outlet_id_idx on public.therapists(outlet_id);
create index if not exists rooms_outlet_id_idx on public.rooms(outlet_id);
create index if not exists services_outlet_id_idx on public.services(outlet_id);
create index if not exists appointments_outlet_date_idx on public.appointments(outlet_id, appointment_date);
create index if not exists transactions_outlet_created_idx on public.transactions(outlet_id, created_at);
create index if not exists appointment_groups_outlet_id_idx on public.appointment_groups(outlet_id);

create table if not exists public.service_categories (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (outlet_id, code)
);

insert into public.service_categories (outlet_id, code, name)
select outlet.id, category.code, category.name
from (
  values
    ('00000000-0000-0000-0000-000000000128'::uuid),
    ('00000000-0000-0000-0000-000000000002'::uuid)
) as outlet(id)
cross join (
  values
    ('services', 'Services'),
    ('packages', 'Packages'),
    ('add-ons', 'Add-ons')
) as category(code, name)
on conflict (outlet_id, code) do update
set name = excluded.name,
    is_active = true,
    updated_at = now();

grant select on table public.service_categories to authenticated;
grant insert, update, delete on table public.service_categories to authenticated;
alter table public.service_categories enable row level security;

drop policy if exists "service_categories_staff_read" on public.service_categories;
create policy "service_categories_staff_read"
on public.service_categories
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "service_categories_admin_all" on public.service_categories;
create policy "service_categories_admin_all"
on public.service_categories
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create table if not exists public.booking_holds (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete set null,
  customer_name text not null,
  customer_phone text not null,
  customer_email text not null,
  therapist_preference text not null default 'none'
    check (therapist_preference in ('none', 'female', 'male', 'specific')),
  therapist_request text not null default '',
  assigned_therapist_id uuid references public.therapists(id) on delete set null,
  assigned_room_id uuid references public.rooms(id) on delete set null,
  service_items jsonb not null default '[]'::jsonb,
  start_at timestamptz not null,
  end_at timestamptz not null,
  total_amount numeric(12,2) not null check (total_amount >= 0),
  currency text not null default 'MYR',
  status text not null default 'pending_payment'
    check (status in ('pending_payment', 'paid', 'confirmed', 'expired', 'cancelled', 'payment_failed')),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  billplz_bill_id text unique,
  billplz_collection_id text,
  appointment_id uuid references public.appointments(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  check (end_at > start_at)
);

create index if not exists booking_holds_outlet_schedule_idx
  on public.booking_holds(outlet_id, start_at, end_at, status);
create index if not exists booking_holds_expiry_idx
  on public.booking_holds(expires_at)
  where status = 'pending_payment';

revoke all on table public.booking_holds from anon;
grant select, insert, update, delete on table public.booking_holds to authenticated;
alter table public.booking_holds enable row level security;

drop policy if exists "booking_holds_staff_select" on public.booking_holds;
create policy "booking_holds_staff_select"
on public.booking_holds
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "booking_holds_staff_insert" on public.booking_holds;
create policy "booking_holds_staff_insert"
on public.booking_holds
for insert
to authenticated
with check (public.is_staff_or_admin());

drop policy if exists "booking_holds_staff_update" on public.booking_holds;
create policy "booking_holds_staff_update"
on public.booking_holds
for update
to authenticated
using (public.is_staff_or_admin())
with check (public.is_staff_or_admin());

drop policy if exists "booking_holds_admin_delete" on public.booking_holds;
create policy "booking_holds_admin_delete"
on public.booking_holds
for delete
to authenticated
using (public.is_admin());

-- Reject references to records owned by a different outlet. This protects the
-- database even if a future client forgets to apply an outlet filter.
create or replace function public.enforce_appointment_outlet_consistency()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.outlet_id is null and new.therapist_id is not null then
    select t.outlet_id into new.outlet_id
    from public.therapists t where t.id = new.therapist_id;
  end if;
  if new.outlet_id is null and new.room_id is not null then
    select r.outlet_id into new.outlet_id
    from public.rooms r where r.id = new.room_id;
  end if;
  if new.outlet_id is null and new.service_id is not null then
    select s.outlet_id into new.outlet_id
    from public.services s where s.id = new.service_id;
  end if;
  if new.outlet_id is null and new.customer_id is not null then
    select c.outlet_id into new.outlet_id
    from public.customers c where c.id = new.customer_id;
  end if;
  if new.outlet_id is null then
    raise exception 'Unable to determine appointment outlet';
  end if;
  if new.customer_id is not null and not exists (
    select 1 from public.customers c where c.id = new.customer_id and c.outlet_id = new.outlet_id
  ) then
    raise exception 'Customer belongs to a different outlet';
  end if;
  if new.therapist_id is not null and not exists (
    select 1 from public.therapists t where t.id = new.therapist_id and t.outlet_id = new.outlet_id
  ) then
    raise exception 'Therapist belongs to a different outlet';
  end if;
  if new.room_id is not null and not exists (
    select 1 from public.rooms r where r.id = new.room_id and r.outlet_id = new.outlet_id
  ) then
    raise exception 'Room belongs to a different outlet';
  end if;
  if new.service_id is not null and not exists (
    select 1 from public.services s where s.id = new.service_id and s.outlet_id = new.outlet_id
  ) then
    raise exception 'Service belongs to a different outlet';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_enforce_outlet on public.appointments;
create trigger appointments_enforce_outlet
before insert or update of outlet_id, customer_id, therapist_id, room_id, service_id
on public.appointments
for each row execute function public.enforce_appointment_outlet_consistency();

create or replace function public.sync_appointment_group_outlet()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_group_outlet_id uuid;
begin
  if new.appointment_group_id is null then return new; end if;

  select g.outlet_id into v_group_outlet_id
  from public.appointment_groups g
  where g.id = new.appointment_group_id
  for update;

  if v_group_outlet_id is null then
    update public.appointment_groups
    set outlet_id = new.outlet_id
    where id = new.appointment_group_id;
  elsif v_group_outlet_id <> new.outlet_id then
    raise exception 'Appointment group belongs to a different outlet';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_sync_group_outlet on public.appointments;
create trigger appointments_sync_group_outlet
after insert or update of appointment_group_id, outlet_id
on public.appointments
for each row execute function public.sync_appointment_group_outlet();

create or replace function public.enforce_booking_hold_outlet_consistency()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.customer_id is not null and not exists (
    select 1 from public.customers c where c.id = new.customer_id and c.outlet_id = new.outlet_id
  ) then
    raise exception 'Customer belongs to a different outlet';
  end if;
  if new.assigned_therapist_id is not null and not exists (
    select 1 from public.therapists t where t.id = new.assigned_therapist_id and t.outlet_id = new.outlet_id
  ) then
    raise exception 'Therapist belongs to a different outlet';
  end if;
  if new.assigned_room_id is not null and not exists (
    select 1 from public.rooms r where r.id = new.assigned_room_id and r.outlet_id = new.outlet_id
  ) then
    raise exception 'Room belongs to a different outlet';
  end if;
  if new.appointment_id is not null and not exists (
    select 1 from public.appointments a where a.id = new.appointment_id and a.outlet_id = new.outlet_id
  ) then
    raise exception 'Appointment belongs to a different outlet';
  end if;
  return new;
end;
$$;

drop trigger if exists booking_holds_enforce_outlet on public.booking_holds;
create trigger booking_holds_enforce_outlet
before insert or update of outlet_id, customer_id, assigned_therapist_id, assigned_room_id, appointment_id
on public.booking_holds
for each row execute function public.enforce_booking_hold_outlet_consistency();
