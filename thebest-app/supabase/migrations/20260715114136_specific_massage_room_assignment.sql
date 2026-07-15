-- Physical massage rooms live under the existing capacity/zone records.
alter table public.rooms
  add column if not exists allocation_mode text not null default 'capacity';

alter table public.rooms drop constraint if exists rooms_allocation_mode_check;
alter table public.rooms add constraint rooms_allocation_mode_check
  check (allocation_mode in ('capacity', 'specific_room'));

-- The existing Foot Zone rows were incorrectly tagged as body rooms. Their
-- capacity behavior remains unchanged and they intentionally receive no units.
update public.rooms
set room_type = 'foot_chair', allocation_mode = 'capacity'
where lower(name) like '%foot%zone%';

update public.rooms
set allocation_mode = 'specific_room'
where lower(name) like '%body%massage%room%';

create table if not exists public.room_units (
  id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.rooms(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  name text not null,
  unit_number integer not null check (unit_number > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (zone_id, unit_number),
  unique (zone_id, name)
);

create index if not exists room_units_outlet_zone_idx
  on public.room_units(outlet_id, zone_id, is_active, unit_number);

insert into public.room_units(zone_id, outlet_id, name, unit_number)
select r.id, r.outlet_id, 'Room ' || unit_number, unit_number
from public.rooms r
cross join lateral generate_series(1, greatest(r.total_slots, 1)) unit_number
where r.allocation_mode = 'specific_room'
on conflict (zone_id, unit_number) do update
set name = excluded.name, outlet_id = excluded.outlet_id, is_active = true,
    updated_at = now();

alter table public.appointments
  add column if not exists room_unit_id uuid references public.room_units(id) on delete restrict,
  add column if not exists room_unit_name text not null default '';

alter table public.booking_holds
  add column if not exists assigned_room_unit_id uuid references public.room_units(id) on delete restrict;

alter table public.transactions
  add column if not exists room_unit_id uuid references public.room_units(id) on delete set null,
  add column if not exists room_unit_name text not null default '';

create index if not exists appointments_room_unit_schedule_idx
  on public.appointments(room_unit_id, appointment_date, start_time, end_time)
  where room_unit_id is not null;
create index if not exists booking_holds_room_unit_schedule_idx
  on public.booking_holds(assigned_room_unit_id, start_at, end_at, expires_at)
  where assigned_room_unit_id is not null and status = 'pending_payment';

alter table public.room_units enable row level security;
grant select on table public.room_units to authenticated;
grant select, insert, update, delete on table public.room_units to service_role;

drop policy if exists room_units_staff_select on public.room_units;
create policy room_units_staff_select on public.room_units
for select to authenticated
using (public.is_staff_or_admin());

drop policy if exists room_units_admin_all on public.room_units;
create policy room_units_admin_all on public.room_units
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

create or replace function public.allocate_specific_room_unit(
  p_zone_id uuid,
  p_start_at timestamp,
  p_block_end_at timestamp,
  p_requested_unit_id uuid default null,
  p_exclude_appointment_id uuid default null,
  p_exclude_hold_id uuid default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = public
as $$
declare
  v_mode text;
  v_unit_id uuid;
begin
  select allocation_mode into v_mode from public.rooms where id = p_zone_id;
  if coalesce(v_mode, 'capacity') <> 'specific_room' then
    return null;
  end if;
  if p_block_end_at <= p_start_at then
    raise exception using errcode = '22023', message = 'Invalid room reservation window.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('specific-room-zone:' || p_zone_id::text, 0));

  select u.id into v_unit_id
  from public.room_units u
  where u.zone_id = p_zone_id
    and u.is_active
    and (p_requested_unit_id is null or u.id = p_requested_unit_id)
    and not exists (
      select 1 from public.appointments a
      where a.room_unit_id = u.id
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < p_block_end_at
        and public.csp_appointment_block_end_at(a) > p_start_at
        and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    )
    and not exists (
      select 1 from public.booking_holds h
      where h.assigned_room_unit_id = u.id
        and h.status = 'pending_payment'
        and h.expires_at > now()
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < p_block_end_at
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
          at time zone 'Asia/Kuala_Lumpur') > p_start_at
        and (p_exclude_hold_id is null or h.id <> p_exclude_hold_id)
    )
  order by case when p_requested_unit_id is not null then 0 else random() end,
           u.unit_number
  for update of u skip locked
  limit 1;

  if v_unit_id is null then
    if p_requested_unit_id is null then
      raise exception using errcode = 'P0001', message = 'No massage room is available for that service and cleanup window.';
    end if;
    raise exception using errcode = 'P0001', message = 'The selected massage room is occupied or cleaning during that time.';
  end if;
  return v_unit_id;
end;
$$;

create or replace function public.assign_appointment_room_unit()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_start timestamp;
  v_block_end timestamp;
  v_hold_id uuid;
begin
  if (select allocation_mode from public.rooms where id = new.room_id) <> 'specific_room' then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;
  v_start := public.csp_start_at(new.appointment_date, new.start_time);
  v_block_end := public.csp_end_at(new.appointment_date, new.start_time, new.end_time)
    + make_interval(mins => greatest(coalesce(new.buffer_after_minutes, 0), 0));
  if new.room_unit_id is null then
    select h.id, h.assigned_room_unit_id
    into v_hold_id, new.room_unit_id
    from public.booking_holds h
    where h.assigned_room_id = new.room_id
      and h.assigned_therapist_id = new.therapist_id
      and h.assigned_room_unit_id is not null
      and h.status not in ('expired', 'cancelled', 'failed')
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') = v_start
      and (h.end_at at time zone 'Asia/Kuala_Lumpur') =
        public.csp_end_at(new.appointment_date, new.start_time, new.end_time)
    order by h.updated_at desc nulls last, h.created_at desc
    limit 1;
  end if;
  new.room_unit_id := public.allocate_specific_room_unit(
    new.room_id, v_start, v_block_end, new.room_unit_id, new.id, v_hold_id
  );
  select name into new.room_unit_name from public.room_units where id = new.room_unit_id;
  return new;
end;
$$;

create or replace function public.assign_booking_hold_room_unit()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.assigned_room_id is null or new.status <> 'pending_payment' then
    return new;
  end if;
  if (select allocation_mode from public.rooms where id = new.assigned_room_id) <> 'specific_room' then
    new.assigned_room_unit_id := null;
    return new;
  end if;
  new.assigned_room_unit_id := public.allocate_specific_room_unit(
    new.assigned_room_id,
    new.start_at at time zone 'Asia/Kuala_Lumpur',
    (new.end_at + make_interval(mins => greatest(coalesce(new.buffer_after_minutes, 0), 0)))
      at time zone 'Asia/Kuala_Lumpur',
    new.assigned_room_unit_id,
    null,
    new.id
  );
  return new;
end;
$$;

-- Backfill active/future reservations before requiring the triggers for new work.
do $$
declare
  v_row record;
  v_unit uuid;
begin
  for v_row in
    select a.* from public.appointments a
    join public.rooms r on r.id = a.room_id
    where r.allocation_mode = 'specific_room'
      and a.room_unit_id is null
      and a.appointment_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date
      and public.csp_blocks_schedule(a.status::text)
    order by a.appointment_date, a.start_time, a.created_at, a.id
  loop
    v_unit := public.allocate_specific_room_unit(
      v_row.room_id,
      public.csp_appointment_start_at(v_row),
      public.csp_appointment_block_end_at(v_row),
      null,
      v_row.id,
      null
    );
    update public.appointments
    set room_unit_id = v_unit,
        room_unit_name = (select name from public.room_units where id = v_unit)
    where id = v_row.id;
  end loop;
end;
$$;

do $$
declare
  v_row record;
begin
  for v_row in
    select h.* from public.booking_holds h
    join public.rooms r on r.id = h.assigned_room_id
    where r.allocation_mode = 'specific_room'
      and h.assigned_room_unit_id is null
      and h.status = 'pending_payment' and h.expires_at > now()
    order by h.start_at, h.created_at, h.id
  loop
    update public.booking_holds
    set assigned_room_unit_id = public.allocate_specific_room_unit(
      v_row.assigned_room_id,
      v_row.start_at at time zone 'Asia/Kuala_Lumpur',
      (v_row.end_at + make_interval(mins => greatest(coalesce(v_row.buffer_after_minutes, 0), 0)))
        at time zone 'Asia/Kuala_Lumpur',
      null,
      null,
      v_row.id
    )
    where id = v_row.id;
  end loop;
end;
$$;

drop trigger if exists appointments_assign_room_unit on public.appointments;
create trigger appointments_assign_room_unit
before insert or update of room_id, room_unit_id, appointment_date, start_time, end_time,
  buffer_after_minutes, status
on public.appointments
for each row execute function public.assign_appointment_room_unit();

drop trigger if exists booking_holds_assign_room_unit on public.booking_holds;
create trigger booking_holds_assign_room_unit
before insert or update of assigned_room_id, assigned_room_unit_id, start_at, end_at,
  buffer_after_minutes, status
on public.booking_holds
for each row execute function public.assign_booking_hold_room_unit();

create or replace function public.sync_transaction_room_unit()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.appointment_id is not null then
    select a.room_unit_id, a.room_unit_name
    into new.room_unit_id, new.room_unit_name
    from public.appointments a
    where a.id = new.appointment_id;
  end if;
  return new;
end;
$$;

drop trigger if exists transactions_sync_room_unit on public.transactions;
create trigger transactions_sync_room_unit
before insert or update of appointment_id
on public.transactions
for each row execute function public.sync_transaction_room_unit();

update public.transactions t
set room_unit_id = a.room_unit_id,
    room_unit_name = a.room_unit_name
from public.appointments a
where a.id = t.appointment_id
  and a.room_unit_id is not null;

-- Extended staff hold RPC. Passing a room unit requests that exact room; a
-- null value keeps automatic random assignment for scheduled booking flows.
create or replace function public.reserve_staff_walkin_allocation(
  p_draft_session_id text,
  p_pax_index integer,
  p_outlet_id uuid,
  p_customer_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_therapist_id uuid,
  p_room_id uuid,
  p_service_items jsonb,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_total_amount numeric,
  p_room_unit_id uuid
)
returns table (
  success boolean,
  hold_id uuid,
  error_code text,
  error_message text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check record;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_buffer_after_minutes integer;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if coalesce(trim(p_draft_session_id), '') = '' or p_pax_index < 0 then
    success := false; hold_id := null; error_code := 'INVALID_DRAFT';
    error_message := 'Draft session and pax index are required.'; expires_at := null;
    return next; return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_therapist_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('room:' || p_room_id::text, 0));
  perform set_config('app.ignore_cleanup_buffer', 'on', true);

  update public.booking_holds set status = 'expired', updated_at = now()
  where hold_kind = 'staff_walkin_draft' and status = 'pending_payment'
    and booking_holds.expires_at <= now();
  update public.booking_holds set status = 'cancelled', updated_at = now()
  where hold_kind = 'staff_walkin_draft'
    and draft_session_id = p_draft_session_id and pax_index = p_pax_index
    and status = 'pending_payment';

  select * into v_check from public.check_booking_availability(
    p_date, p_start_time, p_end_time, p_therapist_id, p_room_id
  );
  if not coalesce(v_check.therapist_available, false) then
    success := false; hold_id := null; error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Therapist is already reserved at that time.'; expires_at := null;
    return next; return;
  end if;
  if coalesce(v_check.room_full, false) then
    success := false; hold_id := null; error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full at that time.'; expires_at := null;
    return next; return;
  end if;

  v_start_at := (p_date + p_start_time) at time zone 'Asia/Kuala_Lumpur';
  v_end_at := (p_date + p_end_time) at time zone 'Asia/Kuala_Lumpur';
  select coalesce(max(
    case
      when item->>'bufferAfterMinutes' ~ '^[0-9]+$'
        then (item->>'bufferAfterMinutes')::integer
      else 0
    end
  ), 0)
  into v_buffer_after_minutes
  from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb)) item;

  begin
    insert into public.booking_holds (
      outlet_id, customer_id, customer_name, customer_phone, customer_email,
      assigned_therapist_id, assigned_room_id, assigned_room_unit_id,
      service_items, start_at, end_at, buffer_after_minutes,
      total_amount, status, expires_at, notes,
      hold_kind, draft_session_id, pax_index
    ) values (
      p_outlet_id, p_customer_id, coalesce(p_customer_name, 'Guest'),
      coalesce(p_customer_phone, ''), '', p_therapist_id, p_room_id,
      p_room_unit_id, coalesce(p_service_items, '[]'::jsonb), v_start_at,
      v_end_at, v_buffer_after_minutes,
      greatest(coalesce(p_total_amount, 0), 0), 'pending_payment',
      now() + interval '10 minutes', 'Staff walk-in draft',
      'staff_walkin_draft', p_draft_session_id, p_pax_index
    ) returning id, booking_holds.expires_at into hold_id, expires_at;
  exception when raise_exception then
    success := false; hold_id := null; error_code := 'ROOM_UNIT_UNAVAILABLE';
    error_message := sqlerrm; expires_at := null;
    return next; return;
  end;

  success := true; error_code := null; error_message := null;
  return next;
end;
$$;

revoke all on function public.reserve_staff_walkin_allocation(
  text, integer, uuid, uuid, text, text, uuid, uuid, jsonb, date, time, time,
  numeric, uuid
) from public, anon;
grant execute on function public.reserve_staff_walkin_allocation(
  text, integer, uuid, uuid, text, text, uuid, uuid, jsonb, date, time, time,
  numeric, uuid
) to authenticated;

create or replace function public.get_room_unit_availability(
  p_zone_id uuid,
  p_date date,
  p_start_time time,
  p_duration integer
)
returns table (
  room_unit_id uuid,
  room_unit_name text,
  status text,
  available_for_requested_time boolean,
  available_at time
)
language sql
stable
security invoker
set search_path = public
as $$
  with requested as (
    select public.csp_start_at(p_date, p_start_time) as starts_at,
           public.csp_start_at(p_date, p_start_time)
             + make_interval(mins => greatest(p_duration, 1)) as ends_at,
           (now() at time zone 'Asia/Kuala_Lumpur') as now_local
  ), conflicts as (
    select u.id,
      max(public.csp_appointment_block_end_at(a)) filter (
        where public.csp_appointment_block_end_at(a) > r.now_local
      ) as appointment_free_at,
      max((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
        at time zone 'Asia/Kuala_Lumpur') filter (where h.expires_at > now()) as hold_free_at,
      bool_or(public.csp_appointment_start_at(a) <= r.now_local
        and public.csp_appointment_end_at(a) > r.now_local) as in_service,
      bool_or(public.csp_appointment_end_at(a) <= r.now_local
        and public.csp_appointment_block_end_at(a) > r.now_local) as cleaning
    from public.room_units u cross join requested r
    left join public.appointments a on a.room_unit_id = u.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < r.ends_at
      and public.csp_appointment_block_end_at(a) > least(r.starts_at, r.now_local)
    left join public.booking_holds h on h.assigned_room_unit_id = u.id
      and h.status = 'pending_payment' and h.expires_at > now()
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') < r.ends_at
      and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
        at time zone 'Asia/Kuala_Lumpur') > least(r.starts_at, r.now_local)
    where u.zone_id = p_zone_id and u.is_active
    group by u.id
  )
  select u.id, u.name,
    case when coalesce(c.in_service, false) then 'occupied'
         when coalesce(c.cleaning, false) then 'cleaning'
         else 'available' end,
    not exists (
      select 1 from public.appointments a, requested r
      where a.room_unit_id = u.id and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < r.ends_at
        and public.csp_appointment_block_end_at(a) > r.starts_at
    ) and not exists (
      select 1 from public.booking_holds h, requested r
      where h.assigned_room_unit_id = u.id and h.status = 'pending_payment'
        and h.expires_at > now()
        and (h.start_at at time zone 'Asia/Kuala_Lumpur') < r.ends_at
        and ((h.end_at + make_interval(mins => greatest(coalesce(h.buffer_after_minutes, 0), 0)))
          at time zone 'Asia/Kuala_Lumpur') > r.starts_at
    ),
    greatest(c.appointment_free_at, c.hold_free_at)::time
  from public.room_units u
  left join conflicts c on c.id = u.id
  where u.zone_id = p_zone_id and u.is_active
  order by 4 desc, 5 nulls last, u.unit_number;
$$;

revoke all on function public.allocate_specific_room_unit(uuid, timestamp, timestamp, uuid, uuid, uuid) from public, anon;
grant execute on function public.allocate_specific_room_unit(uuid, timestamp, timestamp, uuid, uuid, uuid) to authenticated, service_role;
revoke all on function public.get_room_unit_availability(uuid, date, time, integer) from public, anon;
grant execute on function public.get_room_unit_availability(uuid, date, time, integer) to authenticated, service_role;
