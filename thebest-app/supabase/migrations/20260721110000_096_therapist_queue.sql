-- Rotating daily therapist queue + assignment provenance metadata.
--
-- Model: a therapist's queue turn is consumed only when their service
-- actually starts (096 hooks this into start_appointment_service), never at
-- booking or check-in. Future appointments are booked with a *provisional*
-- therapist (is_provisional = true) that 096's refresh job keeps in sync
-- with the live queue right up until check-in/start; a specific customer
-- request or a manual counter override (via switch_appointment_therapist)
-- locks the assignment and stops the auto-refresh from touching it.

alter table public.appointments
  add column if not exists assignment_source text not null default 'queue',
  add column if not exists requested_therapist_id uuid references public.therapists(id),
  add column if not exists requested_gender text,
  add column if not exists is_provisional boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'appointments_assignment_source_check'
      and conrelid = 'public.appointments'::regclass
  ) then
    alter table public.appointments
      add constraint appointments_assignment_source_check
      check (assignment_source in (
        'queue', 'gender_preference', 'specific_customer_request', 'manual_override'
      ));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'appointments_requested_gender_check'
      and conrelid = 'public.appointments'::regclass
  ) then
    alter table public.appointments
      add constraint appointments_requested_gender_check
      check (requested_gender is null or requested_gender in ('Male', 'Female'));
  end if;
end $$;

create index if not exists appointments_provisional_idx
  on public.appointments (outlet_id, appointment_date)
  where is_provisional;

-- 1. Rotating queue state, one row per (outlet, day, therapist).
create table if not exists public.therapist_queue (
  outlet_id uuid not null references public.outlets(id),
  queue_date date not null,
  therapist_id uuid not null references public.therapists(id) on delete cascade,
  queue_position integer not null,
  turn_consumed_at timestamptz,
  protected_turn_owed boolean not null default false,
  protected_turn_reason text,
  created_at timestamptz not null default now(),
  primary key (outlet_id, queue_date, therapist_id)
);

create index if not exists therapist_queue_order_idx
  on public.therapist_queue (
    outlet_id, queue_date, protected_turn_owed, turn_consumed_at, queue_position
  );

alter table public.therapist_queue enable row level security;
grant select on public.therapist_queue to authenticated;

drop policy if exists "therapist_queue_staff_select" on public.therapist_queue;
create policy "therapist_queue_staff_select"
on public.therapist_queue for select to authenticated
using (public.is_staff_or_admin());

-- Writes only happen through the SECURITY DEFINER functions below (owned by
-- the migration role, which bypasses RLS as table owner) -- no direct
-- insert/update/delete policy for authenticated, matching the convention
-- used for appointment_therapist_segments/allocations.

-- 2. Seed today's queue rows for an outlet from therapists.display_order the
--    first time they're needed. Idempotent -- safe to call on every read.
create or replace function public.seed_therapist_queue(
  p_outlet_id uuid,
  p_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.therapist_queue (outlet_id, queue_date, therapist_id, queue_position)
  select
    p_outlet_id,
    p_date,
    t.id,
    row_number() over (order by t.display_order, t.name)
  from public.therapists t
  where t.outlet_id = p_outlet_id
    and coalesce(t.availability_status, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
  on conflict (outlet_id, queue_date, therapist_id) do nothing;
end;
$$;

revoke all on function public.seed_therapist_queue(uuid, date) from public, anon, authenticated;

-- 3. Live queue order joined with duration-aware availability. Ordering is a
--    round-robin: therapists who haven't consumed a turn today (nulls) sort
--    first by seed position; once consumed, turn_consumed_at pushes them to
--    the back in consumption order. protected_turn_owed always wins the tie
--    so a therapist skipped while busy on a specific request resurfaces at
--    the front the moment they're free again.
create or replace function public.get_therapist_queue(
  p_outlet_id uuid,
  p_date date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid,
  name text,
  gender text,
  queue_position integer,
  status text,
  free_at time,
  free_in_minutes integer,
  protected_turn_owed boolean,
  is_recommended boolean,
  rotation_rank bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_date, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
begin
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  return query
  with ordered as (
    select
      tq.therapist_id,
      t.name,
      t.gender,
      tq.queue_position,
      case when busy.free_at is null then 'free_now' else 'busy' end as status,
      busy.free_at::time as free_at,
      case
        when busy.free_at is null then 0
        else greatest(
          floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer,
          0
        )
      end as free_in_minutes,
      tq.protected_turn_owed,
      row_number() over (
        order by
          tq.protected_turn_owed desc,
          tq.turn_consumed_at nulls first,
          tq.queue_position
      ) as rotation_rank
    from public.therapist_queue tq
    join public.therapists t on t.id = tq.therapist_id
    left join lateral (
      select max(public.csp_appointment_block_end_at(a)) as free_at
      from public.appointments a
      where a.appointment_date::date between p_date - 1 and p_date + 1
        and a.therapist_id = tq.therapist_id
        and public.csp_blocks_schedule(a.status::text)
        and public.csp_appointment_start_at(a) < v_end_at
        and public.csp_appointment_block_end_at(a) > v_start_at
    ) busy on true
    where tq.outlet_id = p_outlet_id
      and tq.queue_date = p_date
  )
  select
    o.therapist_id,
    o.name,
    o.gender,
    o.queue_position,
    o.status,
    o.free_at,
    o.free_in_minutes,
    o.protected_turn_owed,
    o.rotation_rank = (
      select min(o2.rotation_rank) from ordered o2 where o2.status = 'free_now'
    ) as is_recommended,
    o.rotation_rank
  from ordered o
  order by o.rotation_rank;
end;
$$;

revoke all on function public.get_therapist_queue(uuid, date, time, integer)
  from public, anon;
grant execute on function public.get_therapist_queue(uuid, date, time, integer)
  to authenticated;

-- 4. Lightweight metadata stamp used by callers that don't go through
--    switch_appointment_therapist (e.g. tagging a walk-in with the reason a
--    non-recommended therapist was picked). Never touches therapist_id/room_id.
create or replace function public.set_appointment_assignment_metadata(
  p_appointment_id uuid,
  p_assignment_source text,
  p_requested_therapist_id uuid default null,
  p_requested_gender text default null,
  p_is_provisional boolean default null
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_assignment_source not in (
    'queue', 'gender_preference', 'specific_customer_request', 'manual_override'
  ) then
    raise exception 'Invalid assignment_source: %', p_assignment_source;
  end if;

  update public.appointments
  set assignment_source = p_assignment_source,
      requested_therapist_id = p_requested_therapist_id,
      requested_gender = p_requested_gender,
      is_provisional = coalesce(p_is_provisional, is_provisional),
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  return v_updated;
end;
$$;

revoke all on function public.set_appointment_assignment_metadata(
  uuid, text, uuid, text, boolean
) from public, anon;
grant execute on function public.set_appointment_assignment_metadata(
  uuid, text, uuid, text, boolean
) to authenticated;

-- 5. Extend switch_appointment_therapist with assignment provenance. Default
--    behaviour (p_keep_provisional = false) locks the assignment, matching
--    every existing staff-initiated call site (therapist-switch dialog,
--    check-in confirmation). Only 096's automatic refresh job passes
--    p_keep_provisional = true so an untouched auto-pick stays provisional.
-- The parameter list grows here, so the old 4-arg overload must be dropped
-- first -- otherwise Postgres keeps both and PostgREST calls become
-- ambiguous whenever only the original 4 named args are supplied.
drop function if exists public.switch_appointment_therapist(uuid, uuid, text, text);

create or replace function public.switch_appointment_therapist(
  p_appointment_id uuid,
  p_new_therapist_id uuid,
  p_split_method text default 'service_time',
  p_reason text default '',
  p_assignment_source text default null,
  p_requested_gender text default null,
  p_keep_provisional boolean default false
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
  if p_assignment_source is not null and p_assignment_source not in (
    'queue', 'gender_preference', 'specific_customer_request', 'manual_override'
  ) then
    success := false; commission_method := null; error_code := 'INVALID_ASSIGNMENT_SOURCE';
    error_message := 'Invalid assignment_source.'; return next; return;
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
      assignment_source = coalesce(p_assignment_source, assignment_source),
      requested_therapist_id = case
        when p_assignment_source = 'specific_customer_request' then p_new_therapist_id
        when p_assignment_source is not null then null
        else requested_therapist_id
      end,
      requested_gender = case
        when p_assignment_source is not null then p_requested_gender
        else requested_gender
      end,
      is_provisional = case when p_keep_provisional then is_provisional else false end,
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

revoke all on function public.switch_appointment_therapist(
  uuid, uuid, text, text, text, text, boolean
) from public, anon;
grant execute on function public.switch_appointment_therapist(
  uuid, uuid, text, text, text, text, boolean
) to authenticated;
