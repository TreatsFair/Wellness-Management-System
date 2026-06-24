-- Business hours plus overnight-safe CSP.
-- Keeps start_time/end_time for display, and adds start_at/end_at for real
-- cross-midnight scheduling.

create table if not exists public.business_settings (
  id integer primary key default 1 check (id = 1),
  open_time time not null default '09:00',
  close_time time not null default '21:00',
  updated_at timestamptz not null default now()
);

insert into public.business_settings (id, open_time, close_time)
values (1, '09:00', '21:00')
on conflict (id) do nothing;

grant select, insert, update on table public.business_settings to authenticated;
alter table public.business_settings enable row level security;

drop policy if exists "business_settings_select_staff_admin" on public.business_settings;
create policy "business_settings_select_staff_admin"
on public.business_settings
for select
to authenticated
using (public.is_staff_or_admin());

drop policy if exists "business_settings_insert_admin" on public.business_settings;
create policy "business_settings_insert_admin"
on public.business_settings
for insert
to authenticated
with check (public.is_admin());

drop policy if exists "business_settings_update_admin" on public.business_settings;
create policy "business_settings_update_admin"
on public.business_settings
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

alter table public.appointments
  add column if not exists start_at timestamp,
  add column if not exists end_at timestamp;

create or replace function public.csp_start_at(p_date date, p_start_time time)
returns timestamp
language sql
immutable
as $$
  select p_date + p_start_time;
$$;

create or replace function public.csp_end_at(
  p_date date,
  p_start_time time,
  p_end_time time
)
returns timestamp
language sql
immutable
as $$
  select p_date
    + p_end_time
    + case when p_end_time <= p_start_time then interval '1 day' else interval '0' end;
$$;

create or replace function public.csp_appointment_start_at(a public.appointments)
returns timestamp
language sql
stable
as $$
  select coalesce(a.start_at, public.csp_start_at(a.appointment_date::date, a.start_time::time));
$$;

create or replace function public.csp_appointment_end_at(a public.appointments)
returns timestamp
language sql
stable
as $$
  select coalesce(a.end_at, public.csp_end_at(a.appointment_date::date, a.start_time::time, a.end_time::time));
$$;

update public.appointments a
set start_at = public.csp_start_at(a.appointment_date::date, a.start_time::time),
    end_at = public.csp_end_at(a.appointment_date::date, a.start_time::time, a.end_time::time)
where a.start_at is null
   or a.end_at is null;

create index if not exists idx_appointments_csp_therapist_at
  on public.appointments (therapist_id, start_at, end_at)
  where therapist_id is not null;

create index if not exists idx_appointments_csp_room_at
  on public.appointments (room_id, start_at, end_at)
  where room_id is not null;

create or replace function public.check_booking_availability(
  p_date date,
  p_start_time time,
  p_end_time time,
  p_therapist_id uuid,
  p_room_id uuid,
  p_exclude_appointment_id uuid default null,
  p_exclude_appointment_group_id uuid default null
)
returns table (
  therapist_available boolean,
  therapist_busy_until time,
  room_total_slots integer,
  room_booked_slots integer,
  room_available_slots integer,
  room_full boolean,
  room_full_until time
)
language plpgsql
stable
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_date, p_start_time);
  v_end_at timestamp := public.csp_end_at(p_date, p_start_time, p_end_time);
  v_therapist_conflicts integer := 0;
  v_room_conflicts integer := 0;
  v_room_total integer := 1;
  v_therapist_busy_until time;
  v_room_busy_until time;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  select count(*), max(public.csp_appointment_end_at(a)::time)
  into v_therapist_conflicts, v_therapist_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_end_at(a) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (
      p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id
    );

  select count(*), max(public.csp_appointment_end_at(a)::time)
  into v_room_conflicts, v_room_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_end_at(a) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (
      p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id
    );

  therapist_available := v_therapist_conflicts = 0;
  therapist_busy_until := v_therapist_busy_until;
  room_total_slots := v_room_total;
  room_booked_slots := v_room_conflicts;
  room_available_slots := greatest(v_room_total - v_room_conflicts, 0);
  room_full := v_room_conflicts >= v_room_total;
  room_full_until := case when room_full then v_room_busy_until else null end;
  return next;
end;
$$;

create or replace function public.get_available_slots(
  p_date date,
  p_therapist_id uuid,
  p_room_id uuid,
  p_duration integer,
  p_exclude_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  classification text,
  score integer,
  reason text
)
language plpgsql
stable
as $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_close_at timestamp;
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
begin
  if p_duration is null or p_duration <= 0 then
    return;
  end if;

  select coalesce(open_time, '09:00'::time), coalesce(close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings
  where id = 1;

  v_start_at := p_date + v_open;
  v_close_at := p_date
    + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  while v_start_at + make_interval(mins => p_duration) <= v_close_at loop
    v_end_at := v_start_at + make_interval(mins => p_duration);

    select *
    into v_check
    from public.check_booking_availability(
      p_date,
      v_start_at::time,
      v_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    if not coalesce(v_check.therapist_available, false) then
      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
    elsif coalesce(v_check.room_full, false) then
      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
    else
      v_score := 0;
      v_reason := 'standard_slot';

      if exists (
        select 1
        from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and public.csp_blocks_schedule(a.status::text)
          and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
          and public.csp_appointment_end_at(a) = v_start_at
          and (p_exclude_id is null or a.id <> p_exclude_id)
      ) then
        v_score := v_score + 2;
        v_reason := 'minimizes_gap';
      end if;

      if exists (
        select 1
        from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and public.csp_blocks_schedule(a.status::text)
          and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
          and public.csp_appointment_start_at(a) = v_end_at
          and (p_exclude_id is null or a.id <> p_exclude_id)
      ) then
        v_score := v_score + 1;
        if v_reason = 'standard_slot' then
          v_reason := 'minimizes_gap';
        end if;
      end if;

      if v_average_count > 0 and v_therapist_count < v_average_count then
        v_score := v_score + 1;
        if v_reason = 'standard_slot' then
          v_reason := 'balances_workload';
        end if;
      end if;

      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := case when v_score > 0 then 'recommended' else 'standard' end;
      score := v_score;
      reason := v_reason;
      return next;
    end if;

    v_start_at := v_start_at + interval '30 minutes';
  end loop;
end;
$$;

create or replace function public.create_appointment_with_csp(
  p_customer_id uuid,
  p_therapist_id uuid,
  p_room_id uuid,
  p_service_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_total_price numeric,
  p_type text default 'appointment',
  p_created_by uuid default auth.uid(),
  p_service_name text default '',
  p_service_items jsonb default '[]'::jsonb,
  p_item_count integer default 1,
  p_notes text default '',
  p_appointment_group_id uuid default null
)
returns table (
  success boolean,
  appointment_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check record;
  v_start_at timestamp;
  v_end_at timestamp;
begin
  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false;
    appointment_id := null;
    error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.';
    return next;
    return;
  end if;

  v_start_at := public.csp_start_at(p_date, p_start_time);
  v_end_at := public.csp_end_at(p_date, p_start_time, p_end_time);

  select *
  into v_check
  from public.check_booking_availability(
    p_date,
    p_start_time,
    p_end_time,
    p_therapist_id,
    p_room_id
  );

  if not coalesce(v_check.therapist_available, false) then
    success := false;
    appointment_id := null;
    error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.';
    return next;
    return;
  end if;

  if coalesce(v_check.room_full, false) then
    success := false;
    appointment_id := null;
    error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.';
    return next;
    return;
  end if;

  insert into public.appointments (
    appointment_group_id,
    customer_id,
    therapist_id,
    room_id,
    service_id,
    appointment_date,
    start_time,
    end_time,
    start_at,
    end_at,
    status,
    total_price,
    type,
    service_name,
    service_items,
    item_count,
    notes,
    created_at,
    created_by
  )
  values (
    p_appointment_group_id,
    p_customer_id,
    p_therapist_id,
    p_room_id,
    p_service_id,
    p_date,
    p_start_time,
    p_end_time,
    v_start_at,
    v_end_at,
    'confirmed',
    p_total_price,
    coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
    coalesce(p_service_name, ''),
    coalesce(p_service_items, '[]'::jsonb),
    greatest(coalesce(p_item_count, 1), 1),
    coalesce(p_notes, ''),
    now(),
    p_created_by
  )
  returning id into appointment_id;

  success := true;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

create or replace function public.update_appointment_with_csp(
  p_appointment_id uuid,
  p_therapist_id uuid,
  p_room_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time
)
returns table (
  success boolean,
  appointment_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check record;
begin
  if not exists (select 1 from public.appointments a where a.id = p_appointment_id) then
    success := false;
    appointment_id := null;
    error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.';
    return next;
    return;
  end if;

  if p_start_time is null or p_end_time is null or p_end_time = p_start_time then
    success := false;
    appointment_id := null;
    error_code := 'INVALID_DURATION';
    error_message := 'End time must be after start time.';
    return next;
    return;
  end if;

  select *
  into v_check
  from public.check_booking_availability(
    p_date,
    p_start_time,
    p_end_time,
    p_therapist_id,
    p_room_id,
    p_appointment_id
  );

  if not coalesce(v_check.therapist_available, false) then
    success := false;
    appointment_id := null;
    error_code := 'THERAPIST_UNAVAILABLE';
    error_message := 'Staff is booked until ' || coalesce(v_check.therapist_busy_until::text, 'later') || '.';
    return next;
    return;
  end if;

  if coalesce(v_check.room_full, false) then
    success := false;
    appointment_id := null;
    error_code := 'ROOM_FULL';
    error_message := 'Room or zone is full until ' || coalesce(v_check.room_full_until::text, 'later') || '.';
    return next;
    return;
  end if;

  update public.appointments
  set therapist_id = p_therapist_id,
      room_id = p_room_id,
      appointment_date = p_date,
      start_time = p_start_time,
      end_time = p_end_time,
      start_at = public.csp_start_at(p_date, p_start_time),
      end_at = public.csp_end_at(p_date, p_start_time, p_end_time),
      updated_at = now()
  where id = p_appointment_id
  returning id into appointment_id;

  success := true;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

create or replace function public.create_appointment_group_with_csp(
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_type text default 'appointment',
  p_status text default 'confirmed',
  p_notes text default '',
  p_created_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allocation jsonb;
  v_new_appointment_id uuid;
  v_check record;
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_start time;
  v_end time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_group_conflicts integer;
  v_group_room_slots integer;
begin
  appointment_ids := array[]::uuid[];

  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) = 0 then
    success := false;
    appointment_group_id := null;
    error_code := 'INVALID_ALLOCATIONS';
    error_message := 'Group booking requires at least one pax allocation.';
    return next;
    return;
  end if;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_start is null or v_end is null or v_end = v_start then
      success := false;
      appointment_group_id := null;
      error_code := 'INVALID_DURATION';
      error_message := 'One pax allocation has an invalid time range.';
      return next;
      return;
    end if;

    v_start_at := public.csp_start_at(p_appointment_date, v_start);
    v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);

    select *
    into v_check
    from public.check_booking_availability(
      p_appointment_date,
      v_start,
      v_end,
      v_therapist_id,
      v_room_id
    );

    if not coalesce(v_check.therapist_available, false) then
      success := false;
      appointment_group_id := null;
      error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'One pax allocation has a staff conflict.';
      return next;
      return;
    end if;

    select count(*)
    into v_group_conflicts
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'therapist_id')::uuid = v_therapist_id
      and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if v_group_conflicts > 1 then
      success := false;
      appointment_group_id := null;
      error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'The same staff cannot serve overlapping pax in one group.';
      return next;
      return;
    end if;

    select count(*)
    into v_group_room_slots
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'room_id')::uuid = v_room_id
      and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots > coalesce(v_check.room_total_slots, 1) then
      success := false;
      appointment_group_id := null;
      error_code := 'ROOM_FULL';
      error_message := 'A room or zone does not have enough slots for this group.';
      return next;
      return;
    end if;
  end loop;

  insert into public.appointment_groups (
    customer_id,
    group_name,
    pax_count,
    appointment_date,
    status,
    notes,
    created_at,
    created_by
  )
  values (
    p_customer_id,
    coalesce(p_group_name, ''),
    greatest(coalesce(p_pax_count, jsonb_array_length(p_allocations)), 1),
    p_appointment_date,
    coalesce(nullif(p_status, ''), 'confirmed'),
    coalesce(p_notes, ''),
    now(),
    p_created_by
  )
  returning id into appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    insert into public.appointments (
      appointment_group_id,
      customer_id,
      therapist_id,
      room_id,
      service_id,
      appointment_date,
      start_time,
      end_time,
      start_at,
      end_at,
      status,
      total_price,
      type,
      service_name,
      service_items,
      item_count,
      notes,
      created_at,
      created_by
    )
    values (
      appointment_group_id,
      p_customer_id,
      v_therapist_id,
      v_room_id,
      v_service_id,
      p_appointment_date,
      v_start,
      v_end,
      public.csp_start_at(p_appointment_date, v_start),
      public.csp_end_at(p_appointment_date, v_start, v_end),
      'confirmed',
      coalesce((v_allocation ->> 'total_price')::numeric, 0),
      coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
      coalesce(v_allocation ->> 'service_name', ''),
      coalesce((v_allocation -> 'service_items'), '[]'::jsonb),
      greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
      coalesce(v_allocation ->> 'notes', ''),
      now(),
      p_created_by
    )
    returning id into v_new_appointment_id;

    appointment_ids := array_append(appointment_ids, v_new_appointment_id);
  end loop;

  success := true;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

create or replace function public.update_appointment_group_with_csp(
  p_appointment_group_id uuid,
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_type text default 'appointment',
  p_status text default 'confirmed',
  p_notes text default '',
  p_updated_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allocation jsonb;
  v_new_appointment_id uuid;
  v_check record;
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_start time;
  v_end time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_group_conflicts integer;
  v_group_room_slots integer;
begin
  appointment_ids := array[]::uuid[];
  appointment_group_id := p_appointment_group_id;

  if not exists (
    select 1 from public.appointment_groups g where g.id = p_appointment_group_id
  ) then
    success := false;
    error_code := 'NOT_FOUND';
    error_message := 'Appointment group was not found.';
    return next;
    return;
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) = 0 then
    success := false;
    error_code := 'INVALID_ALLOCATIONS';
    error_message := 'Group booking requires at least one pax allocation.';
    return next;
    return;
  end if;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    if v_start is null or v_end is null or v_end = v_start then
      success := false;
      error_code := 'INVALID_DURATION';
      error_message := 'One pax allocation has an invalid time range.';
      return next;
      return;
    end if;

    v_start_at := public.csp_start_at(p_appointment_date, v_start);
    v_end_at := public.csp_end_at(p_appointment_date, v_start, v_end);

    select *
    into v_check
    from public.check_booking_availability(
      p_appointment_date,
      v_start,
      v_end,
      v_therapist_id,
      v_room_id,
      null,
      p_appointment_group_id
    );

    if not coalesce(v_check.therapist_available, false) then
      success := false;
      error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'One pax allocation has a staff conflict.';
      return next;
      return;
    end if;

    select count(*)
    into v_group_conflicts
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'therapist_id')::uuid = v_therapist_id
      and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if v_group_conflicts > 1 then
      success := false;
      error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'The same staff cannot serve overlapping pax in one group.';
      return next;
      return;
    end if;

    select count(*)
    into v_group_room_slots
    from jsonb_array_elements(p_allocations) other
    where (other.value ->> 'room_id')::uuid = v_room_id
      and public.csp_start_at(p_appointment_date, (other.value ->> 'start_time')::time) < v_end_at
      and public.csp_end_at(
        p_appointment_date,
        (other.value ->> 'start_time')::time,
        (other.value ->> 'end_time')::time
      ) > v_start_at;

    if coalesce(v_check.room_booked_slots, 0) + v_group_room_slots > coalesce(v_check.room_total_slots, 1) then
      success := false;
      error_code := 'ROOM_FULL';
      error_message := 'A room or zone does not have enough slots for this group.';
      return next;
      return;
    end if;
  end loop;

  update public.appointment_groups
  set customer_id = p_customer_id,
      group_name = coalesce(p_group_name, ''),
      pax_count = greatest(coalesce(p_pax_count, jsonb_array_length(p_allocations)), 1),
      appointment_date = p_appointment_date,
      status = coalesce(nullif(p_status, ''), 'confirmed'),
      notes = coalesce(p_notes, '')
  where id = p_appointment_group_id;

  delete from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;

  for v_allocation in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_allocation ->> 'therapist_id')::uuid;
    v_room_id := (v_allocation ->> 'room_id')::uuid;
    v_service_id := (v_allocation ->> 'service_id')::uuid;
    v_start := (v_allocation ->> 'start_time')::time;
    v_end := (v_allocation ->> 'end_time')::time;

    insert into public.appointments (
      appointment_group_id,
      customer_id,
      therapist_id,
      room_id,
      service_id,
      appointment_date,
      start_time,
      end_time,
      start_at,
      end_at,
      status,
      total_price,
      type,
      service_name,
      service_items,
      item_count,
      notes,
      created_at,
      created_by
    )
    values (
      p_appointment_group_id,
      p_customer_id,
      v_therapist_id,
      v_room_id,
      v_service_id,
      p_appointment_date,
      v_start,
      v_end,
      public.csp_start_at(p_appointment_date, v_start),
      public.csp_end_at(p_appointment_date, v_start, v_end),
      'confirmed',
      coalesce((v_allocation ->> 'total_price')::numeric, 0),
      coalesce(nullif(p_type, ''), 'appointment')::public.appointment_type,
      coalesce(v_allocation ->> 'service_name', ''),
      coalesce((v_allocation -> 'service_items'), '[]'::jsonb),
      greatest(coalesce((v_allocation ->> 'item_count')::integer, 1), 1),
      coalesce(v_allocation ->> 'notes', ''),
      now(),
      p_updated_by
    )
    returning id into v_new_appointment_id;

    appointment_ids := array_append(appointment_ids, v_new_appointment_id);
  end loop;

  success := true;
  error_code := null;
  error_message := null;
  return next;
end;
$$;

create or replace function public.check_walkin_availability(
  p_today date,
  p_now_time time,
  p_duration integer,
  p_room_id uuid
)
returns table (
  therapists jsonb,
  zone_available_now boolean,
  zone_free_slots integer,
  can_start_now boolean,
  next_available_time time
)
language plpgsql
stable
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => p_duration);
  v_room_total integer := 1;
  v_room_booked integer := 0;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  select count(*)
  into v_room_booked
  from public.appointments a
  where a.appointment_date::date between p_today - 1 and p_today + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_end_at(a) > v_start_at;

  zone_free_slots := greatest(v_room_total - v_room_booked, 0);
  zone_available_now := zone_free_slots > 0;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'therapist_id', t.id,
      'name', t.name,
      'status', case when busy.free_at is null then 'free_now' else 'busy' end,
      'free_at', busy.free_at::time,
      'free_in_minutes', case
        when busy.free_at is null then 0
        else greatest(floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer, 0)
      end
    )
    order by case when busy.free_at is null then 0 else 1 end, busy.free_at nulls first, t.name
  ), '[]'::jsonb)
  into therapists
  from public.therapists t
  left join lateral (
    select max(public.csp_appointment_end_at(a)) as free_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.therapist_id = t.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_end_at(a) > v_start_at
  ) busy on true
  where coalesce(t.is_active, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist';

  select min((item ->> 'free_at')::time)
  into next_available_time
  from jsonb_array_elements(therapists) item
  where item ->> 'free_at' is not null;

  can_start_now := zone_available_now
    and exists (
      select 1
      from jsonb_array_elements(therapists) item
      where item ->> 'status' = 'free_now'
    );

  return next;
end;
$$;

grant execute on function public.check_booking_availability(date, time, time, uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.get_available_slots(date, uuid, uuid, integer, uuid) to authenticated;
grant execute on function public.create_appointment_with_csp(uuid, uuid, uuid, uuid, date, time, time, numeric, text, uuid, text, jsonb, integer, text, uuid) to authenticated;
grant execute on function public.update_appointment_with_csp(uuid, uuid, uuid, date, time, time) to authenticated;
grant execute on function public.create_appointment_group_with_csp(uuid, text, integer, date, jsonb, text, text, text, uuid) to authenticated;
grant execute on function public.update_appointment_group_with_csp(uuid, uuid, text, integer, date, jsonb, text, text, text, uuid) to authenticated;
grant execute on function public.check_walkin_availability(date, time, integer, uuid) to authenticated;
