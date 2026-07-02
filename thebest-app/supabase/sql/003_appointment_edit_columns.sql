BEGIN;

alter table public.appointments
  add column if not exists notes text not null default '',
  add column if not exists total_price numeric not null default 0;

alter table public.transactions
  add column if not exists appointment_id uuid,
  alter column appointment_id drop not null,
  add column if not exists customer_id uuid,
  add column if not exists service_price numeric not null default 0,
  add column if not exists sst_amount numeric not null default 0,
  add column if not exists total_amount numeric not null default 0,
  add column if not exists payment_method text not null default '',
  add column if not exists payment_status text not null default 'paid',
  add column if not exists receipt_number text not null default '',
  add column if not exists item_count integer not null default 1,
  add column if not exists notes text not null default '';

COMMIT;
