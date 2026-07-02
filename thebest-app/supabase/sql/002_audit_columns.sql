BEGIN;

create or replace function public.set_audit_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at = coalesce(new.created_at, now());
    new.created_by = coalesce(new.created_by, auth.uid());
  end if;

  new.updated_at = now();
  new.updated_by = auth.uid();

  return new;
end;
$$;

revoke all on function public.set_audit_fields() from public;

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id text not null,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  changed_at timestamptz not null default now(),
  changed_by uuid,
  old_data jsonb,
  new_data jsonb
);

alter table public.audit_log enable row level security;

grant select on table public.audit_log to authenticated;
grant usage, select on sequence public.audit_log_id_seq to authenticated;

drop policy if exists "audit_log_select_admin" on public.audit_log;
create policy "audit_log_select_admin"
on public.audit_log
for select
to authenticated
using (public.is_admin());

create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_row jsonb;
  new_row jsonb;
  record_key text;
begin
  old_row := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  new_row := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end;
  record_key := coalesce(new_row ->> 'id', old_row ->> 'id');

  insert into public.audit_log (
    table_name,
    record_id,
    action,
    changed_at,
    changed_by,
    old_data,
    new_data
  )
  values (
    tg_table_name,
    coalesce(record_key, ''),
    tg_op,
    now(),
    auth.uid(),
    old_row,
    new_row
  );

  return coalesce(new, old);
end;
$$;

revoke all on function public.write_audit_log() from public;

alter table public.profiles
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.customers
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.therapists
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.rooms
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.services
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.appointments
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.transactions
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.settings
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

drop trigger if exists profiles_set_audit_fields on public.profiles;
create trigger profiles_set_audit_fields
before insert or update on public.profiles
for each row execute function public.set_audit_fields();

drop trigger if exists profiles_write_audit_log on public.profiles;
create trigger profiles_write_audit_log
after insert or update or delete on public.profiles
for each row execute function public.write_audit_log();

drop trigger if exists customers_set_audit_fields on public.customers;
create trigger customers_set_audit_fields
before insert or update on public.customers
for each row execute function public.set_audit_fields();

drop trigger if exists customers_write_audit_log on public.customers;
create trigger customers_write_audit_log
after insert or update or delete on public.customers
for each row execute function public.write_audit_log();

drop trigger if exists therapists_set_audit_fields on public.therapists;
create trigger therapists_set_audit_fields
before insert or update on public.therapists
for each row execute function public.set_audit_fields();

drop trigger if exists therapists_write_audit_log on public.therapists;
create trigger therapists_write_audit_log
after insert or update or delete on public.therapists
for each row execute function public.write_audit_log();

drop trigger if exists rooms_set_audit_fields on public.rooms;
create trigger rooms_set_audit_fields
before insert or update on public.rooms
for each row execute function public.set_audit_fields();

drop trigger if exists rooms_write_audit_log on public.rooms;
create trigger rooms_write_audit_log
after insert or update or delete on public.rooms
for each row execute function public.write_audit_log();

drop trigger if exists services_set_audit_fields on public.services;
create trigger services_set_audit_fields
before insert or update on public.services
for each row execute function public.set_audit_fields();

drop trigger if exists services_write_audit_log on public.services;
create trigger services_write_audit_log
after insert or update or delete on public.services
for each row execute function public.write_audit_log();

drop trigger if exists appointments_set_audit_fields on public.appointments;
create trigger appointments_set_audit_fields
before insert or update on public.appointments
for each row execute function public.set_audit_fields();

drop trigger if exists appointments_write_audit_log on public.appointments;
create trigger appointments_write_audit_log
after insert or update or delete on public.appointments
for each row execute function public.write_audit_log();

drop trigger if exists transactions_set_audit_fields on public.transactions;
create trigger transactions_set_audit_fields
before insert or update on public.transactions
for each row execute function public.set_audit_fields();

drop trigger if exists transactions_write_audit_log on public.transactions;
create trigger transactions_write_audit_log
after insert or update or delete on public.transactions
for each row execute function public.write_audit_log();

drop trigger if exists settings_set_audit_fields on public.settings;
create trigger settings_set_audit_fields
before insert or update on public.settings
for each row execute function public.set_audit_fields();

drop trigger if exists settings_write_audit_log on public.settings;
create trigger settings_write_audit_log
after insert or update or delete on public.settings
for each row execute function public.write_audit_log();

COMMIT;
