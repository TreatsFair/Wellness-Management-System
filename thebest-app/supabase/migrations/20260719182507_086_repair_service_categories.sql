-- Repair: the tail of 016_multi_outlet_booking_holds.sql never executed against
-- production, so public.service_categories was never created even though the
-- rest of that file (outlet_id columns, indexes, booking_holds) did land.
-- Everything below is idempotent and mirrors 016 lines 119-165 verbatim.

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
