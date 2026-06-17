alter table if exists appointments
  add column if not exists service_items jsonb not null default '[]'::jsonb,
  add column if not exists item_count integer not null default 1;

alter table if exists transactions
  add column if not exists service_items jsonb not null default '[]'::jsonb,
  add column if not exists item_count integer not null default 1;
