alter table public.transactions
  add column if not exists counter_staff_id uuid references public.therapists(id) on delete set null,
  add column if not exists counter_staff_name text,
  add column if not exists therapist_commission_amount numeric not null default 0,
  add column if not exists counter_commission_amount numeric not null default 0;

create index if not exists transactions_counter_staff_id_idx
  on public.transactions(counter_staff_id);
