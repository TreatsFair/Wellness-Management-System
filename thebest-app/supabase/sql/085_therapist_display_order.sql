-- Persist the admin-defined staff card order per outlet and role.
alter table public.therapists
  add column if not exists display_order integer;

with ranked as (
  select
    id,
    row_number() over (
      partition by outlet_id, role
      order by join_date desc nulls last, lower(coalesce(name, '')), id
    ) - 1 as position
  from public.therapists
)
update public.therapists as therapist
set display_order = ranked.position
from ranked
where ranked.id = therapist.id
  and therapist.display_order is null;

alter table public.therapists
  alter column display_order set default 0;

update public.therapists
set display_order = 0
where display_order is null;

alter table public.therapists
  alter column display_order set not null;

create index if not exists therapists_outlet_role_display_order_idx
  on public.therapists(outlet_id, role, display_order, name);

comment on column public.therapists.display_order is
  'Admin-defined ordering used by staff management, booking, and timetable staff lists.';
