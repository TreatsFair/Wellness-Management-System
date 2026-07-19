-- Persist the admin-defined service card order per outlet and category.
alter table public.services
  add column if not exists display_order integer;

with ranked as (
  select
    id,
    row_number() over (
      partition by outlet_id, category
      order by lower(coalesce(name, '')), id
    ) - 1 as position
  from public.services
)
update public.services as service
set display_order = ranked.position
from ranked
where ranked.id = service.id
  and service.display_order is null;

alter table public.services
  alter column display_order set default 0;

update public.services
set display_order = 0
where display_order is null;

alter table public.services
  alter column display_order set not null;

create index if not exists services_outlet_category_display_order_idx
  on public.services(outlet_id, category, display_order, name);

comment on column public.services.display_order is
  'Admin-defined ordering used by service management, appointments, and walk-in ordering.';
