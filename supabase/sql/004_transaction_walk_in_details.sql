BEGIN;

alter table public.transactions
  add column if not exists customer_name text not null default '',
  add column if not exists customer_phone text not null default '',
  add column if not exists service_id uuid,
  add column if not exists service_name text not null default '',
  add column if not exists therapist_id uuid,
  add column if not exists therapist_name text not null default '',
  add column if not exists room_id uuid,
  add column if not exists room_name text not null default '';

COMMIT;
