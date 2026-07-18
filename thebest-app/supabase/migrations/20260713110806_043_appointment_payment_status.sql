alter table public.appointments
  add column if not exists payment_status public.payment_status not null default 'unpaid';

update public.appointments a
set payment_status = t.payment_status
from public.transactions t
where t.appointment_id = a.id;

update public.appointments a
set payment_status = t.payment_status
from public.transactions t
where a.appointment_group_id is not null
  and t.appointment_group_id = a.appointment_group_id;

create or replace function public.sync_appointment_payment_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.appointment_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where id = new.appointment_id
      and payment_status is distinct from new.payment_status;
  end if;

  if new.appointment_group_id is not null then
    update public.appointments
    set payment_status = new.payment_status
    where appointment_group_id = new.appointment_group_id
      and payment_status is distinct from new.payment_status;
  end if;

  return new;
end;
$$;

drop trigger if exists transactions_sync_appointment_payment_status on public.transactions;
create trigger transactions_sync_appointment_payment_status
after insert or update of payment_status on public.transactions
for each row execute function public.sync_appointment_payment_status();;
