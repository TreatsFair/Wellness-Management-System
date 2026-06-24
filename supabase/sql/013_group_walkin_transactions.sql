alter table public.transactions
  add column if not exists appointment_group_id uuid
    references public.appointment_groups(id) on delete set null;

alter table public.transactions
  add column if not exists source text not null default '';

create index if not exists transactions_appointment_group_id_idx
  on public.transactions(appointment_group_id);

create index if not exists transactions_source_idx
  on public.transactions(source);

update public.transactions t
set source = case
  when lower(coalesce(a.type::text, '')) = 'walkin' then 'walkin'
  when t.appointment_group_id is not null then 'walkin'
  when t.appointment_id is not null then 'appointment'
  else coalesce(nullif(t.source, ''), 'walkin')
end
from public.appointments a
where t.appointment_id = a.id
  and coalesce(t.source, '') = '';

update public.transactions
set source = 'walkin'
where coalesce(source, '') = ''
  and appointment_group_id is not null;
