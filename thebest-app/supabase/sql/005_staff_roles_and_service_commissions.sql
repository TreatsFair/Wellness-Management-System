alter table if exists therapists
  add column if not exists role text not null default 'Therapist',
  add column if not exists service_commissions jsonb not null default '{}'::jsonb;

update therapists
set role = 'Therapist'
where role is null or btrim(role) = '';

alter table if exists services
  add column if not exists therapist_commission numeric not null default 0,
  add column if not exists counter_commission numeric not null default 0;
