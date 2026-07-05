-- Controlled, outlet-specific public booking catalogue and scheduling rules.

create table if not exists public.online_booking_outlet_settings (
  outlet_id uuid primary key references public.outlets(id) on delete cascade,
  online_booking_enabled boolean not null default false,
  public_open_time time not null default '09:00',
  public_close_time time not null default '21:00',
  slot_interval_minutes integer not null default 30 check (slot_interval_minutes = 30),
  minimum_advance_minutes integer not null default 60 check (minimum_advance_minutes >= 0),
  maximum_booking_days integer not null default 7 check (maximum_booking_days = 7),
  same_day_booking_allowed boolean not null default false,
  customer_therapist_selection_allowed boolean not null default true,
  public_therapist_names_allowed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.online_booking_outlet_settings (
  outlet_id, public_open_time, public_close_time
)
select o.id, coalesce(bs.open_time, '09:00'::time), coalesce(bs.close_time, '21:00'::time)
from public.outlets o
left join public.business_settings bs on bs.outlet_id = o.id
on conflict (outlet_id) do nothing;

create table if not exists public.online_booking_services (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  enabled boolean not null default false,
  public_name text not null default '',
  short_description text not null default '',
  public_image_url text not null default '',
  display_price numeric(12,2) not null default 0 check (display_price >= 0),
  show_price boolean not null default true,
  display_order integer not null default 0,
  buffer_before_minutes integer not null default 0 check (buffer_before_minutes between 0 and 240),
  buffer_after_minutes integer not null default 0 check (buffer_after_minutes between 0 and 240),
  maximum_concurrent_bookings integer not null default 3 check (maximum_concurrent_bookings between 1 and 100),
  use_custom_hours boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (outlet_id, service_id)
);

create table if not exists public.online_booking_service_rooms (
  online_booking_service_id uuid not null references public.online_booking_services(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  primary key (online_booking_service_id, room_id)
);

create table if not exists public.online_booking_service_hours (
  id uuid primary key default gen_random_uuid(),
  online_booking_service_id uuid not null references public.online_booking_services(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  day_of_week integer not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now(),
  check (end_time <> start_time),
  unique (online_booking_service_id, day_of_week, start_time)
);

create table if not exists public.online_booking_closures (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  closure_date date not null,
  is_full_day boolean not null default true,
  start_time time,
  end_time time,
  internal_reason text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (is_full_day and start_time is null and end_time is null)
    or (not is_full_day and start_time is not null and end_time is not null and start_time <> end_time)
  )
);

create table if not exists public.therapist_working_hours (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  therapist_id uuid not null references public.therapists(id) on delete cascade,
  day_of_week integer not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now(),
  check (end_time <> start_time),
  unique (therapist_id, day_of_week, start_time)
);

create table if not exists public.therapist_unavailability (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  therapist_id uuid not null references public.therapists(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  internal_reason text not null default '',
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

alter table public.booking_holds
  add column if not exists online_booking_service_id uuid references public.online_booking_services(id) on delete restrict,
  add column if not exists buffer_before_minutes integer not null default 0,
  add column if not exists buffer_after_minutes integer not null default 0;

alter table public.appointments
  add column if not exists online_booking_service_id uuid references public.online_booking_services(id) on delete set null;

create index if not exists online_booking_services_public_idx
  on public.online_booking_services(outlet_id, enabled, display_order);
create index if not exists online_booking_closures_date_idx on public.online_booking_closures(outlet_id, closure_date);
create index if not exists therapist_working_hours_lookup_idx on public.therapist_working_hours(outlet_id, therapist_id, day_of_week);
create index if not exists therapist_unavailability_lookup_idx on public.therapist_unavailability(outlet_id, therapist_id, starts_at, ends_at);
create index if not exists booking_holds_online_service_idx on public.booking_holds(online_booking_service_id, start_at, end_at);

create or replace function public.enforce_online_booking_outlet_match()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_parent_outlet uuid; v_resource_outlet uuid;
begin
  if tg_table_name = 'online_booking_service_rooms' then
    select outlet_id into v_parent_outlet from public.online_booking_services where id = new.online_booking_service_id;
    select outlet_id into v_resource_outlet from public.rooms where id = new.room_id;
  elsif tg_table_name = 'online_booking_service_hours' then
    select outlet_id into v_parent_outlet from public.online_booking_services where id = new.online_booking_service_id;
    v_resource_outlet := new.outlet_id;
  elsif tg_table_name in ('therapist_working_hours', 'therapist_unavailability') then
    select outlet_id into v_resource_outlet from public.therapists where id = new.therapist_id;
    v_parent_outlet := new.outlet_id;
  else
    select outlet_id into v_resource_outlet from public.services where id = new.service_id;
    v_parent_outlet := new.outlet_id;
  end if;
  if v_parent_outlet is null or v_resource_outlet is null or v_parent_outlet <> v_resource_outlet then
    raise exception 'Online booking records must belong to the same outlet';
  end if;
  new.outlet_id := v_parent_outlet;
  return new;
end; $$;

drop trigger if exists online_booking_services_outlet_match on public.online_booking_services;
create trigger online_booking_services_outlet_match before insert or update on public.online_booking_services
for each row execute function public.enforce_online_booking_outlet_match();
drop trigger if exists online_booking_service_rooms_outlet_match on public.online_booking_service_rooms;
create trigger online_booking_service_rooms_outlet_match before insert or update on public.online_booking_service_rooms
for each row execute function public.enforce_online_booking_outlet_match();
drop trigger if exists online_booking_service_hours_outlet_match on public.online_booking_service_hours;
create trigger online_booking_service_hours_outlet_match before insert or update on public.online_booking_service_hours
for each row execute function public.enforce_online_booking_outlet_match();
drop trigger if exists therapist_working_hours_outlet_match on public.therapist_working_hours;
create trigger therapist_working_hours_outlet_match before insert or update on public.therapist_working_hours
for each row execute function public.enforce_online_booking_outlet_match();
drop trigger if exists therapist_unavailability_outlet_match on public.therapist_unavailability;
create trigger therapist_unavailability_outlet_match before insert or update on public.therapist_unavailability
for each row execute function public.enforce_online_booking_outlet_match();

do $$ declare t text; begin
  foreach t in array array['online_booking_outlet_settings','online_booking_services','online_booking_service_rooms','online_booking_service_hours','online_booking_closures','therapist_working_hours','therapist_unavailability'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('grant select, insert, update, delete on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_admin_all', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t || '_admin_all', t);
  end loop;
end $$;

revoke all on table public.online_booking_outlet_settings, public.online_booking_services,
  public.online_booking_service_rooms, public.online_booking_service_hours,
  public.online_booking_closures, public.therapist_working_hours,
  public.therapist_unavailability from anon;
