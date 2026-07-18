-- Staff-created walk-in holds and therapist commission ownership.

alter table public.booking_holds
  add column if not exists hold_kind text not null default 'online_payment',
  add column if not exists draft_session_id text,
  add column if not exists pax_index integer;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'booking_holds_hold_kind_check'
      and conrelid = 'public.booking_holds'::regclass
  ) then
    alter table public.booking_holds
      add constraint booking_holds_hold_kind_check
      check (hold_kind in ('online_payment', 'staff_walkin_draft'));
  end if;
end $$;

create unique index if not exists booking_holds_staff_draft_pax_idx
  on public.booking_holds (draft_session_id, pax_index)
  where hold_kind = 'staff_walkin_draft'
    and status = 'pending_payment';

create index if not exists booking_holds_staff_resource_idx
  on public.booking_holds (outlet_id, assigned_therapist_id, start_at, end_at)
  where status = 'pending_payment';

create table if not exists public.appointment_therapist_segments (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  therapist_id uuid not null references public.therapists(id) on delete restrict,
  started_at timestamptz not null,
  ended_at timestamptz,
  change_type text not null default 'initial'
    check (change_type in ('initial', 'pre_start_replacement', 'early_replacement', 'mid_service_switch')),
  reason text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  check (ended_at is null or ended_at >= started_at)
);

create unique index if not exists appointment_therapist_segments_one_open_idx
  on public.appointment_therapist_segments (appointment_id)
  where ended_at is null;
create index if not exists appointment_therapist_segments_appointment_idx
  on public.appointment_therapist_segments (appointment_id, started_at);
create index if not exists appointment_therapist_segments_therapist_idx
  on public.appointment_therapist_segments (therapist_id, started_at, ended_at);

create table if not exists public.appointment_therapist_allocations (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  therapist_id uuid not null references public.therapists(id) on delete restrict,
  commission_share numeric(7,6) not null check (commission_share >= 0 and commission_share <= 1),
  commission_amount numeric(12,2) not null default 0 check (commission_amount >= 0),
  allocation_method text not null default 'full'
    check (allocation_method in ('full', 'early_replacement', 'service_time', 'half', 'manual')),
  reason text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (appointment_id, therapist_id)
);

create index if not exists appointment_therapist_allocations_appointment_idx
  on public.appointment_therapist_allocations (appointment_id);
create index if not exists appointment_therapist_allocations_therapist_idx
  on public.appointment_therapist_allocations (therapist_id, appointment_id);

alter table public.appointment_therapist_segments enable row level security;
alter table public.appointment_therapist_allocations enable row level security;

grant select on public.appointment_therapist_segments to authenticated;
grant select on public.appointment_therapist_allocations to authenticated;

drop policy if exists "appointment_therapist_segments_staff_select" on public.appointment_therapist_segments;
create policy "appointment_therapist_segments_staff_select"
on public.appointment_therapist_segments for select to authenticated
using ((select public.is_staff_or_admin()));

drop policy if exists "appointment_therapist_allocations_staff_select" on public.appointment_therapist_allocations;
create policy "appointment_therapist_allocations_staff_select"
on public.appointment_therapist_allocations for select to authenticated
using ((select public.is_staff_or_admin()));

drop trigger if exists appointment_therapist_segments_set_audit_fields on public.appointment_therapist_segments;
create trigger appointment_therapist_segments_set_audit_fields
before insert or update on public.appointment_therapist_segments
for each row execute function public.set_audit_fields();

drop trigger if exists appointment_therapist_segments_write_audit_log on public.appointment_therapist_segments;
create trigger appointment_therapist_segments_write_audit_log
after insert or update or delete on public.appointment_therapist_segments
for each row execute function public.write_audit_log();

drop trigger if exists appointment_therapist_allocations_set_audit_fields on public.appointment_therapist_allocations;
create trigger appointment_therapist_allocations_set_audit_fields
before insert or update on public.appointment_therapist_allocations
for each row execute function public.set_audit_fields();

drop trigger if exists appointment_therapist_allocations_write_audit_log on public.appointment_therapist_allocations;
create trigger appointment_therapist_allocations_write_audit_log
after insert or update or delete on public.appointment_therapist_allocations
for each row execute function public.write_audit_log();

create or replace function public.recalculate_appointment_therapist_commission(
  p_appointment_id uuid
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_transaction public.transactions%rowtype;
  v_allocation record;
  v_amount numeric;
  v_total numeric := 0;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    return 0;
  end if;

  select * into v_transaction
  from public.transactions
  where appointment_id = p_appointment_id
     or appointment_group_id = v_appointment.appointment_group_id
  order by created_at desc
  limit 1;

  if not found or v_transaction.payment_status <> 'paid' then
    return 0;
  end if;

  if not exists (
    select 1 from public.appointment_therapist_allocations
    where appointment_id = p_appointment_id
  ) then
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    ) values (
      p_appointment_id, v_appointment.therapist_id, 1, 'full', auth.uid()
    );
  end if;

  for v_allocation in
    select *
    from public.appointment_therapist_allocations
    where appointment_id = p_appointment_id
  loop
    v_amount := case
      when v_transaction.source = 'online_booking'
        and v_appointment.status <> 'completed' then 0
      else round(
        public.csp_commission_for_items(
          coalesce(v_appointment.service_items, '[]'::jsonb),
          v_allocation.therapist_id,
          'Therapist'
        ) * v_allocation.commission_share,
        2
      )
    end;

    update public.appointment_therapist_allocations
    set commission_amount = v_amount
    where id = v_allocation.id;
  end loop;

  select coalesce(sum(ata.commission_amount), 0)
  into v_total
  from public.appointment_therapist_allocations ata
  join public.appointments a on a.id = ata.appointment_id
  where a.id = v_transaction.appointment_id
     or (
       v_transaction.appointment_group_id is not null
       and a.appointment_group_id = v_transaction.appointment_group_id
     );

  update public.transactions
  set therapist_commission_amount = v_total,
      updated_at = now()
  where id = v_transaction.id;

  return v_total;
end;
$$;

-- Staff walk-ins may intentionally start at the previous treatment end. The
-- setting is transaction-local and is enabled only by the staff walk-in RPCs.
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
security invoker
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_date, p_start_time);
  v_end_at timestamp := public.csp_end_at(p_date, p_start_time, p_end_time);
  v_ignore_cleanup boolean := coalesce(current_setting('app.ignore_cleanup_buffer', true), '') = 'on';
  v_therapist_conflicts integer := 0;
  v_room_conflicts integer := 0;
  v_therapist_hold_conflicts integer := 0;
  v_room_hold_conflicts integer := 0;
  v_room_total integer := 1;
  v_therapist_busy_until time;
  v_room_busy_until time;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total from public.rooms r where r.id = p_room_id;
  v_room_total := coalesce(v_room_total, 1);

  select count(*), max((case when v_ignore_cleanup
    then public.csp_appointment_end_at(a)
    else public.csp_appointment_block_end_at(a) end)::time)
  into v_therapist_conflicts, v_therapist_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and (case when v_ignore_cleanup
      then public.csp_appointment_end_at(a)
      else public.csp_appointment_block_end_at(a) end) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id);

  select count(*), max((case when v_ignore_cleanup
    then public.csp_appointment_end_at(a)
    else public.csp_appointment_block_end_at(a) end)::time)
  into v_room_conflicts, v_room_busy_until
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and (case when v_ignore_cleanup
      then public.csp_appointment_end_at(a)
      else public.csp_appointment_block_end_at(a) end) > v_start_at
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (p_exclude_appointment_group_id is null
      or a.appointment_group_id is distinct from p_exclude_appointment_group_id);

  select count(*) into v_therapist_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_therapist_id = p_therapist_id
    and hold.status = 'pending_payment' and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((case when v_ignore_cleanup then hold.end_at else
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)) end)
      at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  select count(*) into v_room_hold_conflicts
  from public.booking_holds hold
  where hold.assigned_room_id = p_room_id
    and hold.status = 'pending_payment' and hold.expires_at > now()
    and (hold.start_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
    and ((case when v_ignore_cleanup then hold.end_at else
      hold.end_at + make_interval(mins => greatest(coalesce(hold.buffer_after_minutes, 0), 0)) end)
      at time zone 'Asia/Kuala_Lumpur') > v_start_at;

  v_therapist_conflicts := v_therapist_conflicts + coalesce(v_therapist_hold_conflicts, 0);
  v_room_conflicts := v_room_conflicts + coalesce(v_room_hold_conflicts, 0);
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

create or replace function public.get_walkin_therapist_availability(
  p_today date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid, name text, status text, free_at time, free_in_minutes integer
)
language plpgsql stable set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
begin
  return query
  select t.id, t.name,
    case when busy.free_at is null then 'free_now' else 'busy' end,
    busy.free_at::time,
    case when busy.free_at is null then 0 else greatest(
      floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer, 0
    ) end
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
  where coalesce(t.availability_status, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
  order by case when busy.free_at is null then 0 else 1 end,
    busy.free_at nulls first, t.name;
end;
$$;

create or replace function public.get_walkin_room_availability(
  p_today date,
  p_now_time time,
  p_duration integer,
  p_room_id uuid
)
returns table (available_now boolean, free_slots integer, total_slots integer, free_at time)
language plpgsql stable set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
  v_room_total integer := 1;
  v_room_booked integer := 0;
  v_free_at timestamp;
begin
  select greatest(coalesce(r.total_slots, 1), 1) into v_room_total
  from public.rooms r where r.id = p_room_id;
  v_room_total := coalesce(v_room_total, 1);
  select count(*), max(public.csp_appointment_end_at(a))
  into v_room_booked, v_free_at
  from public.appointments a
  where a.appointment_date::date between p_today - 1 and p_today + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_end_at(a) > v_start_at;
  free_slots := greatest(v_room_total - v_room_booked, 0);
  total_slots := v_room_total;
  available_now := free_slots > 0;
  free_at := v_free_at::time;
  return next;
end;
$$;

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
  p_total_amount numeric
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

  update public.booking_holds
  set status = 'expired', updated_at = now()
  where hold_kind = 'staff_walkin_draft'
    and status = 'pending_payment'
    and expires_at <= now();

  update public.booking_holds
  set status = 'cancelled', updated_at = now()
  where hold_kind = 'staff_walkin_draft'
    and draft_session_id = p_draft_session_id
    and pax_index = p_pax_index
    and status = 'pending_payment';

  select * into v_check
  from public.check_booking_availability(
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

  insert into public.booking_holds (
    outlet_id, customer_id, customer_name, customer_phone, customer_email,
    assigned_therapist_id, assigned_room_id, service_items,
    start_at, end_at, total_amount, status, expires_at, notes,
    hold_kind, draft_session_id, pax_index
  ) values (
    p_outlet_id, p_customer_id, coalesce(p_customer_name, 'Guest'), coalesce(p_customer_phone, ''), '',
    p_therapist_id, p_room_id, coalesce(p_service_items, '[]'::jsonb),
    v_start_at, v_end_at, greatest(coalesce(p_total_amount, 0), 0),
    'pending_payment', now() + interval '10 minutes', 'Staff walk-in draft',
    'staff_walkin_draft', p_draft_session_id, p_pax_index
  )
  returning id, booking_holds.expires_at into hold_id, expires_at;

  success := true; error_code := null; error_message := null;
  return next;
end;
$$;

create or replace function public.release_staff_walkin_draft(
  p_draft_session_id text,
  p_pax_index integer default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  update public.booking_holds
  set status = 'cancelled', updated_at = now()
  where hold_kind = 'staff_walkin_draft'
    and draft_session_id = p_draft_session_id
    and status = 'pending_payment'
    and (p_pax_index is null or pax_index = p_pax_index);
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

create or replace function public.initialize_appointment_therapist_allocation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_started_at timestamptz;
begin
  if new.therapist_id is null then return new; end if;

  if new.therapist_id is distinct from old.therapist_id
    and coalesce(current_setting('app.therapist_switch_rpc', true), '') <> '1'
    and new.actual_started_at is null then
    delete from public.appointment_therapist_allocations where appointment_id = new.id;
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    ) values (new.id, new.therapist_id, 1, 'full', auth.uid());
  end if;

  if new.actual_started_at is not null and old.actual_started_at is null then
    v_started_at := new.actual_started_at;
    insert into public.appointment_therapist_segments (
      appointment_id, therapist_id, started_at, change_type, created_by
    ) values (new.id, new.therapist_id, v_started_at, 'initial', auth.uid())
    on conflict do nothing;

    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    ) values (new.id, new.therapist_id, 1, 'full', auth.uid())
    on conflict (appointment_id, therapist_id) do update
      set commission_share = 1, allocation_method = 'full', updated_at = now();
  end if;

  if new.status = 'completed' and old.status is distinct from 'completed' then
    update public.appointment_therapist_segments
    set ended_at = coalesce(new.actual_completed_at, now())
    where appointment_id = new.id and ended_at is null;
    perform public.recalculate_appointment_therapist_commission(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_initialize_therapist_allocation on public.appointments;
create trigger appointments_initialize_therapist_allocation
after update of therapist_id, actual_started_at, status on public.appointments
for each row execute function public.initialize_appointment_therapist_allocation();

create or replace function public.initialize_transaction_therapist_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  if new.payment_status <> 'paid' then return new; end if;
  if new.appointment_id is not null then
    perform public.recalculate_appointment_therapist_commission(new.appointment_id);
  elsif new.appointment_group_id is not null then
    for v_appointment_id in
      select id from public.appointments
      where appointment_group_id = new.appointment_group_id
    loop
      perform public.recalculate_appointment_therapist_commission(v_appointment_id);
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists transactions_initialize_therapist_commission on public.transactions;
create trigger transactions_initialize_therapist_commission
after insert on public.transactions
for each row execute function public.initialize_transaction_therapist_commission();

create or replace function public.create_staff_walkin_with_payment(
  p_customer_id uuid,
  p_therapist_id uuid,
  p_room_id uuid,
  p_service_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_service_price numeric,
  p_service_name text,
  p_service_items jsonb,
  p_item_count integer,
  p_notes text,
  p_customer_name text,
  p_customer_phone text,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default '',
  p_transaction_notes text default '',
  p_start_immediately boolean default true,
  p_draft_session_id text default null,
  p_created_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_id uuid,
  transaction_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing record;
  v_create record;
  v_outlet_id uuid;
  v_therapist_name text;
  v_room_name text;
  v_therapist_commission numeric;
  v_counter_commission numeric;
  v_transaction_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_therapist_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('room:' || p_room_id::text, 0));

  if p_draft_session_id is not null then
    update public.booking_holds
    set status = 'cancelled', updated_at = now()
    where hold_kind = 'staff_walkin_draft'
      and draft_session_id = p_draft_session_id
      and status = 'pending_payment';
  end if;

  if p_start_immediately then
    select * into v_existing
    from public.create_walkin_appointment_with_payment(
      p_customer_id, p_therapist_id, p_room_id, p_service_id, p_date,
      p_start_time, p_end_time, p_service_price, p_service_name,
      p_service_items, p_item_count, p_notes, p_customer_name, p_customer_phone,
      p_counter_staff_id, p_counter_staff_name, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes, p_created_by
    );
    success := v_existing.success;
    appointment_id := v_existing.appointment_id;
    transaction_id := v_existing.transaction_id;
    error_code := v_existing.error_code;
    error_message := v_existing.error_message;
    return next; return;
  end if;

  perform set_config('app.ignore_cleanup_buffer', 'on', true);
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  select * into v_create
  from public.create_appointment_with_csp(
    p_customer_id => p_customer_id,
    p_therapist_id => p_therapist_id,
    p_room_id => p_room_id,
    p_service_id => p_service_id,
    p_date => p_date,
    p_start_time => p_start_time,
    p_end_time => p_end_time,
    p_total_price => p_service_price,
    p_type => 'walkin',
    p_created_by => p_created_by,
    p_service_name => p_service_name,
    p_service_items => p_service_items,
    p_item_count => p_item_count,
    p_notes => p_notes
  );
  if not coalesce(v_create.success, false) then
    success := false; appointment_id := null; transaction_id := null;
    error_code := v_create.error_code; error_message := v_create.error_message;
    return next; return;
  end if;

  select outlet_id into v_outlet_id from public.appointments where id = v_create.appointment_id;
  select name into v_therapist_name from public.therapists where id = p_therapist_id;
  select name into v_room_name from public.rooms where id = p_room_id;
  v_therapist_commission := public.csp_commission_for_items(p_service_items, p_therapist_id, 'Therapist');
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(p_service_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_outlet_id, v_create.appointment_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    p_service_id, coalesce(p_service_name, ''), coalesce(p_service_items, '[]'::jsonb), greatest(coalesce(p_item_count, 1), 1),
    p_therapist_id, coalesce(v_therapist_name, ''), p_counter_staff_id, p_counter_staff_name,
    p_room_id, coalesce(v_room_name, ''), coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number, coalesce(p_transaction_notes, '')
  ) returning id into v_transaction_id;

  insert into public.appointment_therapist_allocations (
    appointment_id, therapist_id, commission_share, allocation_method, created_by
  ) values (v_create.appointment_id, p_therapist_id, 1, 'full', p_created_by)
  on conflict (appointment_id, therapist_id) do update
    set commission_share = 1, allocation_method = 'full', updated_at = now();

  perform public.recalculate_appointment_therapist_commission(v_create.appointment_id);
  success := true; appointment_id := v_create.appointment_id; transaction_id := v_transaction_id;
  error_code := null; error_message := null; return next;
end;
$$;

create or replace function public.create_staff_walkin_group_with_payment(
  p_customer_id uuid,
  p_group_name text,
  p_pax_count integer,
  p_appointment_date date,
  p_allocations jsonb,
  p_notes text,
  p_customer_name text,
  p_customer_phone text,
  p_counter_staff_id uuid default null,
  p_counter_staff_name text default null,
  p_service_price numeric default 0,
  p_sst_amount numeric default 0,
  p_total_amount numeric default 0,
  p_payment_method text default 'cash',
  p_receipt_number text default '',
  p_transaction_notes text default '',
  p_start_immediately boolean default true,
  p_draft_session_id text default null,
  p_created_by uuid default auth.uid()
)
returns table (
  success boolean,
  appointment_group_id uuid,
  appointment_ids uuid[],
  transaction_id uuid,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing record;
  v_create record;
  v_alloc jsonb;
  v_therapist_text text;
  v_all_items jsonb := '[]'::jsonb;
  v_item_count integer := 0;
  v_therapist_commission numeric := 0;
  v_counter_commission numeric;
  v_outlet_id uuid;
  v_first_therapist_id uuid;
  v_first_therapist_name text;
  v_first_room_id uuid;
  v_first_room_name text;
  v_first_service_id uuid;
  v_first_service_name text;
  v_transaction_id uuid;
  v_idx integer := 0;
  v_appointment_id uuid;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  for v_therapist_text in
    select distinct value ->> 'therapist_id'
    from jsonb_array_elements(p_allocations)
    order by value ->> 'therapist_id'
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_therapist_text, 0));
  end loop;
  for v_therapist_text in
    select distinct 'room:' || (value ->> 'room_id')
    from jsonb_array_elements(p_allocations)
    order by 'room:' || (value ->> 'room_id')
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_therapist_text, 0));
  end loop;

  if p_draft_session_id is not null then
    update public.booking_holds
    set status = 'cancelled', updated_at = now()
    where hold_kind = 'staff_walkin_draft'
      and draft_session_id = p_draft_session_id
      and status = 'pending_payment';
  end if;

  if p_start_immediately then
    select * into v_existing
    from public.create_walkin_appointment_group_with_payment(
      p_customer_id, p_group_name, p_pax_count, p_appointment_date, p_allocations,
      p_notes, p_customer_name, p_customer_phone, p_counter_staff_id,
      p_counter_staff_name, p_service_price, p_sst_amount, p_total_amount,
      p_payment_method, p_receipt_number, p_transaction_notes, p_created_by
    );
    success := v_existing.success; appointment_group_id := v_existing.appointment_group_id;
    appointment_ids := v_existing.appointment_ids; transaction_id := v_existing.transaction_id;
    error_code := v_existing.error_code; error_message := v_existing.error_message;
    return next; return;
  end if;

  perform set_config('app.ignore_cleanup_buffer', 'on', true);
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  select * into v_create
  from public.create_appointment_group_with_csp(
    p_customer_id => p_customer_id,
    p_group_name => p_group_name,
    p_pax_count => p_pax_count,
    p_appointment_date => p_appointment_date,
    p_allocations => p_allocations,
    p_type => 'walkin',
    p_status => 'confirmed',
    p_notes => p_notes,
    p_created_by => p_created_by
  );
  if not coalesce(v_create.success, false) then
    success := false; appointment_group_id := null; appointment_ids := null; transaction_id := null;
    error_code := v_create.error_code; error_message := v_create.error_message;
    return next; return;
  end if;

  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    v_idx := v_idx + 1;
    v_all_items := v_all_items || coalesce(v_alloc -> 'service_items', '[]'::jsonb);
    v_item_count := v_item_count + jsonb_array_length(coalesce(v_alloc -> 'service_items', '[]'::jsonb));
    v_therapist_commission := v_therapist_commission + public.csp_commission_for_items(
      v_alloc -> 'service_items', nullif(v_alloc ->> 'therapist_id', '')::uuid, 'Therapist'
    );
    if v_idx = 1 then
      v_first_therapist_id := nullif(v_alloc ->> 'therapist_id', '')::uuid;
      v_first_room_id := nullif(v_alloc ->> 'room_id', '')::uuid;
      v_first_service_id := nullif(v_alloc ->> 'service_id', '')::uuid;
      v_first_service_name := v_alloc ->> 'service_name';
    end if;
  end loop;

  select name into v_first_therapist_name from public.therapists where id = v_first_therapist_id;
  select name into v_first_room_name from public.rooms where id = v_first_room_id;
  select outlet_id into v_outlet_id from public.appointments
  where appointment_group_id = v_create.appointment_group_id limit 1;
  v_counter_commission := case when p_counter_staff_id is null then 0
    else public.csp_commission_for_items(v_all_items, p_counter_staff_id, 'Counter') end;

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, counter_staff_id, counter_staff_name,
    room_id, room_name, service_price, sst_amount, total_amount,
    therapist_commission_amount, counter_commission_amount,
    source, payment_method, payment_status, receipt_number, notes
  ) values (
    v_outlet_id, v_create.appointment_group_id, p_customer_id, coalesce(p_customer_name, ''), coalesce(p_customer_phone, ''),
    v_first_service_id, coalesce(v_first_service_name, ''), v_all_items, greatest(v_item_count, 1),
    v_first_therapist_id, coalesce(v_first_therapist_name, ''), p_counter_staff_id, p_counter_staff_name,
    v_first_room_id, coalesce(v_first_room_name, ''), coalesce(p_service_price, 0), coalesce(p_sst_amount, 0), coalesce(p_total_amount, 0),
    v_therapist_commission, v_counter_commission,
    'walkin', coalesce(nullif(p_payment_method, ''), 'cash')::public.payment_method,
    'paid'::public.payment_status, p_receipt_number, coalesce(p_transaction_notes, '')
  ) returning id into v_transaction_id;

  foreach v_appointment_id in array v_create.appointment_ids loop
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    )
    select id, therapist_id, 1, 'full', p_created_by
    from public.appointments where id = v_appointment_id
    on conflict (appointment_id, therapist_id) do update
      set commission_share = 1, allocation_method = 'full', updated_at = now();
    perform public.recalculate_appointment_therapist_commission(v_appointment_id);
  end loop;

  success := true; appointment_group_id := v_create.appointment_group_id;
  appointment_ids := v_create.appointment_ids; transaction_id := v_transaction_id;
  error_code := null; error_message := null; return next;
end;
$$;

create or replace function public.switch_appointment_therapist(
  p_appointment_id uuid,
  p_new_therapist_id uuid,
  p_split_method text default 'service_time',
  p_reason text default ''
)
returns table (
  success boolean,
  commission_method text,
  error_code text,
  error_message text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_old_therapist_id uuid;
  v_switch_at timestamptz := now();
  v_expected_end timestamptz;
  v_check record;
  v_early boolean;
  v_total_seconds numeric;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_split_method not in ('service_time', 'half') then
    success := false; commission_method := null; error_code := 'INVALID_SPLIT_METHOD';
    error_message := 'Choose service_time or half.'; return next; return;
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;
  if not found then
    success := false; commission_method := null; error_code := 'NOT_FOUND';
    error_message := 'Appointment was not found.'; return next; return;
  end if;
  if v_appointment.status in ('cancelled', 'no_show') then
    success := false; commission_method := null; error_code := 'INVALID_STATUS';
    error_message := 'Cancelled and no-show appointments cannot change therapist.'; return next; return;
  end if;
  if v_appointment.status = 'completed' then
    success := false; commission_method := null; error_code := 'USE_HISTORY_CORRECTION';
    error_message := 'Use the completed-service commission editor.'; return next; return;
  end if;

  v_old_therapist_id := v_appointment.therapist_id;
  if v_old_therapist_id = p_new_therapist_id then
    success := false; commission_method := null; error_code := 'SAME_THERAPIST';
    error_message := 'This therapist is already assigned.'; return next; return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(least(v_old_therapist_id::text, p_new_therapist_id::text), 0));
  perform pg_advisory_xact_lock(hashtextextended(greatest(v_old_therapist_id::text, p_new_therapist_id::text), 0));

  v_expected_end := coalesce(
    v_appointment.end_at at time zone 'Asia/Kuala_Lumpur',
    (v_appointment.appointment_date + v_appointment.end_time) at time zone 'Asia/Kuala_Lumpur'
  );

  if v_expected_end > v_switch_at then
    select * into v_check
    from public.check_booking_availability(
      v_appointment.appointment_date,
      (greatest(v_switch_at, (v_appointment.appointment_date + v_appointment.start_time) at time zone 'Asia/Kuala_Lumpur')
        at time zone 'Asia/Kuala_Lumpur')::time,
      (v_expected_end at time zone 'Asia/Kuala_Lumpur')::time,
      p_new_therapist_id,
      v_appointment.room_id,
      v_appointment.id
    );
    if not coalesce(v_check.therapist_available, false) then
      success := false; commission_method := null; error_code := 'THERAPIST_UNAVAILABLE';
      error_message := 'Replacement therapist has another overlapping appointment.'; return next; return;
    end if;
  end if;

  v_early := v_appointment.actual_started_at is null
    or v_switch_at <= v_appointment.actual_started_at + interval '15 minutes';

  perform set_config('app.therapist_switch_rpc', '1', true);
  update public.appointments
  set therapist_id = p_new_therapist_id,
      service_items = coalesce((
        select jsonb_agg(
          item || jsonb_build_object(
            'assignedTherapistId', p_new_therapist_id,
            'assignedTherapistName', coalesce(t.name, '')
          )
        )
        from jsonb_array_elements(coalesce(v_appointment.service_items, '[]'::jsonb)) item
        cross join public.therapists t
        where t.id = p_new_therapist_id
      ), v_appointment.service_items),
      updated_at = now()
  where id = p_appointment_id;

  if v_appointment.actual_started_at is null then
    delete from public.appointment_therapist_allocations where appointment_id = p_appointment_id;
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
    ) values (p_appointment_id, p_new_therapist_id, 1, 'early_replacement', p_reason, auth.uid());
    commission_method := 'early_replacement';
  else
    update public.appointment_therapist_segments
    set ended_at = v_switch_at
    where appointment_id = p_appointment_id and ended_at is null;
    insert into public.appointment_therapist_segments (
      appointment_id, therapist_id, started_at, change_type, reason, created_by
    ) values (
      p_appointment_id, p_new_therapist_id, v_switch_at,
      case when v_early then 'early_replacement' else 'mid_service_switch' end,
      p_reason, auth.uid()
    );

    delete from public.appointment_therapist_allocations where appointment_id = p_appointment_id;
    if v_early then
      insert into public.appointment_therapist_allocations (
        appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
      ) values (p_appointment_id, p_new_therapist_id, 1, 'early_replacement', p_reason, auth.uid());
      commission_method := 'early_replacement';
    elsif p_split_method = 'half' then
      if (
        select count(distinct therapist_id)
        from public.appointment_therapist_segments
        where appointment_id = p_appointment_id
      ) > 2 then
        raise exception '50/50 is only available when two therapists participated; use service-time split.';
      end if;
      insert into public.appointment_therapist_allocations (
        appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
      ) values
        (p_appointment_id, v_old_therapist_id, 0.5, 'half', p_reason, auth.uid()),
        (p_appointment_id, p_new_therapist_id, 0.5, 'half', p_reason, auth.uid());
      commission_method := 'half';
    else
      select greatest(extract(epoch from (v_expected_end - v_appointment.actual_started_at)), 1)
      into v_total_seconds;
      insert into public.appointment_therapist_allocations (
        appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
      )
      select
        p_appointment_id,
        s.therapist_id,
        least(1, greatest(0, sum(extract(epoch from (coalesce(s.ended_at, v_expected_end) - s.started_at))) / v_total_seconds)),
        'service_time',
        p_reason,
        auth.uid()
      from public.appointment_therapist_segments s
      where s.appointment_id = p_appointment_id
      group by s.therapist_id;
      commission_method := 'service_time';
    end if;
  end if;

  update public.transactions t
  set therapist_id = p_new_therapist_id,
      therapist_name = (select name from public.therapists where id = p_new_therapist_id),
      updated_at = now()
  where t.appointment_id = p_appointment_id;

  perform public.recalculate_appointment_therapist_commission(p_appointment_id);
  success := true; error_code := null; error_message := null;
  return next;
end;
$$;

create or replace function public.set_completed_therapist_allocations(
  p_appointment_id uuid,
  p_allocations jsonb,
  p_reason text
)
returns table (success boolean, error_code text, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total numeric;
  v_item jsonb;
  v_therapist_id uuid;
  v_share numeric;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin permission required';
  end if;
  if not exists (
    select 1 from public.appointments where id = p_appointment_id and status = 'completed'
  ) then
    success := false; error_code := 'NOT_COMPLETED';
    error_message := 'Only completed services can be corrected in history.'; return next; return;
  end if;
  if coalesce(trim(p_reason), '') = '' then
    success := false; error_code := 'REASON_REQUIRED';
    error_message := 'A correction reason is required.'; return next; return;
  end if;
  if jsonb_typeof(p_allocations) is distinct from 'array' or jsonb_array_length(p_allocations) = 0 then
    success := false; error_code := 'INVALID_ALLOCATIONS';
    error_message := 'At least one therapist allocation is required.'; return next; return;
  end if;

  select coalesce(sum((value ->> 'commission_share')::numeric), 0)
  into v_total from jsonb_array_elements(p_allocations);
  if abs(v_total - 1) > 0.0001 then
    success := false; error_code := 'INVALID_TOTAL';
    error_message := 'Commission shares must total 100%.'; return next; return;
  end if;
  if (
    select count(*) <> count(distinct value ->> 'therapist_id')
    from jsonb_array_elements(p_allocations)
  ) then
    success := false; error_code := 'DUPLICATE_THERAPIST';
    error_message := 'Each therapist can appear only once.'; return next; return;
  end if;

  delete from public.appointment_therapist_allocations where appointment_id = p_appointment_id;
  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_therapist_id := (v_item ->> 'therapist_id')::uuid;
    v_share := (v_item ->> 'commission_share')::numeric;
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, reason, created_by
    ) values (p_appointment_id, v_therapist_id, v_share, 'manual', p_reason, auth.uid());
  end loop;

  perform public.recalculate_appointment_therapist_commission(p_appointment_id);
  success := true; error_code := null; error_message := null;
  return next;
end;
$$;

revoke all on function public.recalculate_appointment_therapist_commission(uuid) from public, anon, authenticated;
revoke all on function public.initialize_appointment_therapist_allocation() from public, anon, authenticated;
revoke all on function public.initialize_transaction_therapist_commission() from public, anon, authenticated;
revoke all on function public.reserve_staff_walkin_allocation(text, integer, uuid, uuid, text, text, uuid, uuid, jsonb, date, time, time, numeric) from public, anon;
grant execute on function public.reserve_staff_walkin_allocation(text, integer, uuid, uuid, text, text, uuid, uuid, jsonb, date, time, time, numeric) to authenticated;
revoke all on function public.release_staff_walkin_draft(text, integer) from public, anon;
grant execute on function public.release_staff_walkin_draft(text, integer) to authenticated;
revoke all on function public.create_staff_walkin_with_payment(uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer, text, text, text, uuid, text, numeric, numeric, text, text, text, boolean, text, uuid) from public, anon;
grant execute on function public.create_staff_walkin_with_payment(uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb, integer, text, text, text, uuid, text, numeric, numeric, text, text, text, boolean, text, uuid) to authenticated;
revoke all on function public.create_staff_walkin_group_with_payment(uuid, text, integer, date, jsonb, text, text, text, uuid, text, numeric, numeric, numeric, text, text, text, boolean, text, uuid) from public, anon;
grant execute on function public.create_staff_walkin_group_with_payment(uuid, text, integer, date, jsonb, text, text, text, uuid, text, numeric, numeric, numeric, text, text, text, boolean, text, uuid) to authenticated;
revoke all on function public.switch_appointment_therapist(uuid, uuid, text, text) from public, anon;
grant execute on function public.switch_appointment_therapist(uuid, uuid, text, text) to authenticated;
revoke all on function public.set_completed_therapist_allocations(uuid, jsonb, text) from public, anon;
grant execute on function public.set_completed_therapist_allocations(uuid, jsonb, text) to authenticated;

insert into public.appointment_therapist_allocations (
  appointment_id, therapist_id, commission_share, allocation_method, created_by
)
select a.id, a.therapist_id, 1, 'full', a.created_by
from public.appointments a
where a.therapist_id is not null
on conflict (appointment_id, therapist_id) do nothing;

insert into public.appointment_therapist_segments (
  appointment_id, therapist_id, started_at, ended_at, change_type, created_by
)
select
  a.id,
  a.therapist_id,
  a.actual_started_at,
  case when a.status = 'completed' then coalesce(a.actual_completed_at, a.actual_started_at) else null end,
  'initial',
  a.created_by
from public.appointments a
where a.therapist_id is not null
  and a.actual_started_at is not null
  and a.status in ('in_progress', 'completed')
on conflict do nothing;

update public.appointment_therapist_allocations ata
set commission_amount = round(
  public.csp_commission_for_items(coalesce(a.service_items, '[]'::jsonb), ata.therapist_id, 'Therapist')
    * ata.commission_share,
  2
)
from public.appointments a
where a.id = ata.appointment_id
  and (
    a.status = 'completed'
    or exists (
      select 1 from public.transactions t
      where (t.appointment_id = a.id or t.appointment_group_id = a.appointment_group_id)
        and t.payment_status = 'paid'
        and t.source <> 'online_booking'
    )
  );
;
