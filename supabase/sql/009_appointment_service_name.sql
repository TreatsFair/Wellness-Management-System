alter table if exists public.appointments
  add column if not exists service_name text not null default '';
