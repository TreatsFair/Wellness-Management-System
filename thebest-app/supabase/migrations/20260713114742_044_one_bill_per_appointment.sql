create unique index if not exists transactions_one_bill_per_appointment_uidx
  on public.transactions (appointment_id)
  where appointment_id is not null;

create unique index if not exists transactions_one_bill_per_group_uidx
  on public.transactions (appointment_group_id)
  where appointment_group_id is not null;;
