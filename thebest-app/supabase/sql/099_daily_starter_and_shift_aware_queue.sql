-- Daily starting-therapist rotation + shift-aware live queue.
--
-- Two problems this fixes in the 096/097 queue:
--   1. The queue was seeded purely from therapists.display_order and ignored
--      who is actually scheduled today, so off-shift / not-working therapists
--      showed as "free now" and could be "Recommended".
--   2. There was no notion of a rotating *daily starter*. Requirement: for
--      each outlet, today's starting therapist is the next scheduled+active
--      therapist AFTER the previous operating day's recorded starter, wrapping
--      by display_order. The daily starter is recorded separately from the
--      live queue; the live queue only advances when services start.

-- 1. Recorded daily starter, one row per outlet per operating day. This is the
--    persistent pointer the next day advances from -- distinct from the live
--    therapist_queue (whose turn_consumed_at only moves at service start).
create table if not exists public.therapist_queue_day (
  outlet_id uuid not null references public.outlets(id),
  queue_date date not null,
  starter_therapist_id uuid not null references public.therapists(id),
  created_at timestamptz not null default now(),
  primary key (outlet_id, queue_date)
);

alter table public.therapist_queue_day enable row level security;
grant select on public.therapist_queue_day to authenticated;

drop policy if exists "therapist_queue_day_staff_select" on public.therapist_queue_day;
create policy "therapist_queue_day_staff_select"
on public.therapist_queue_day for select to authenticated
using (public.is_staff_or_admin());

-- 2. Reseed helper. "Eligible today" = active, role therapist, and scheduled
--    to work today (a therapist_working_hours row for today's DOW while the
--    outlet is open) -- the same shift gate get_walkin_therapist_availability
--    uses, so the queue and the live status agree. Guarded by the presence of
--    a therapist_queue_day row, so the whole computation runs once per outlet
--    per day and is a cheap no-op on every later read.
create or replace function public.seed_therapist_queue(
  p_outlet_id uuid,
  p_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dow integer := extract(dow from p_date)::integer;
  v_prev_order integer;
  v_starter_id uuid;
  v_starter_order integer;
begin
  if exists (
    select 1 from public.therapist_queue_day
    where outlet_id = p_outlet_id and queue_date = p_date
  ) then
    return;
  end if;

  -- Display-order of the previous operating day's recorded starter (-1 when
  -- this is the first ever operating day for the outlet, so the search below
  -- lands on the lowest-display-order eligible therapist).
  select coalesce(th.display_order, -1) into v_prev_order
  from public.therapist_queue_day d
  left join public.therapists th on th.id = d.starter_therapist_id
  where d.outlet_id = p_outlet_id and d.queue_date < p_date
  order by d.queue_date desc
  limit 1;
  if not found then
    v_prev_order := -1;
  end if;

  -- Today's starter: first eligible therapist AFTER the previous starter by
  -- display_order; wrap to the lowest eligible if none is higher.
  select t.id into v_starter_id
  from public.therapists t
  where t.outlet_id = p_outlet_id
    and coalesce(t.availability_status, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
    and t.display_order > v_prev_order
    and exists (
      select 1 from public.therapist_working_hours wh
      join public.business_hours bh
        on bh.outlet_id = t.outlet_id
       and bh.day_of_week = wh.day_of_week
       and not coalesce(bh.is_closed, false)
      where wh.therapist_id = t.id and wh.day_of_week = v_dow
    )
  order by t.display_order, t.name
  limit 1;

  if v_starter_id is null then
    select t.id into v_starter_id
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true) = true
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
      and exists (
        select 1 from public.therapist_working_hours wh
        join public.business_hours bh
          on bh.outlet_id = t.outlet_id
         and bh.day_of_week = wh.day_of_week
         and not coalesce(bh.is_closed, false)
        where wh.therapist_id = t.id and wh.day_of_week = v_dow
      )
    order by t.display_order, t.name
    limit 1;
  end if;

  -- Nobody scheduled today (outlet closed / no shifts): leave unseeded so a
  -- later read on a day that does have shifts still gets a chance to seed.
  if v_starter_id is null then
    return;
  end if;

  select display_order into v_starter_order
  from public.therapists where id = v_starter_id;

  insert into public.therapist_queue_day (outlet_id, queue_date, starter_therapist_id)
  values (p_outlet_id, p_date, v_starter_id)
  on conflict (outlet_id, queue_date) do nothing;

  -- Live queue positions: eligible therapists ordered starting at the starter,
  -- following display_order and wrapping. Position 1 is always the starter.
  insert into public.therapist_queue (outlet_id, queue_date, therapist_id, queue_position)
  select
    p_outlet_id,
    p_date,
    e.id,
    row_number() over (
      order by
        case when e.display_order >= v_starter_order then 0 else 1 end,
        e.display_order,
        e.name
    )
  from public.therapists e
  where e.outlet_id = p_outlet_id
    and coalesce(e.availability_status, true) = true
    and lower(coalesce(e.role, 'therapist')) = 'therapist'
    and exists (
      select 1 from public.therapist_working_hours wh
      join public.business_hours bh
        on bh.outlet_id = e.outlet_id
       and bh.day_of_week = wh.day_of_week
       and not coalesce(bh.is_closed, false)
      where wh.therapist_id = e.id and wh.day_of_week = v_dow
    )
  on conflict (outlet_id, queue_date, therapist_id) do nothing;
end;
$$;

revoke all on function public.seed_therapist_queue(uuid, date) from public, anon, authenticated;

-- 3. Shift-aware live queue. Inner-joins get_walkin_therapist_availability so
--    only therapists actually on shift for the [now, now+duration] window
--    appear, with correct free/busy status and free_at -- an off-shift or
--    on-leave therapist can no longer surface as "free now" or Recommended.
--    Rotation order is unchanged: protected turns first, then not-yet-consumed
--    by queue_position, then consumed (pushed to the back in consumption
--    order via turn_consumed_at). Recommended = first free-now in that order.
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
begin
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  return query
  with avail as (
    select a.therapist_id, a.status, a.free_at, a.free_in_minutes
    from public.get_walkin_therapist_availability(p_date, p_now_time, p_duration) a
  ),
  ordered as (
    select
      tq.therapist_id,
      t.name,
      t.gender,
      tq.queue_position,
      av.status,
      av.free_at,
      av.free_in_minutes,
      tq.protected_turn_owed,
      row_number() over (
        order by
          tq.protected_turn_owed desc,
          tq.turn_consumed_at nulls first,
          tq.queue_position
      ) as rotation_rank
    from public.therapist_queue tq
    join public.therapists t on t.id = tq.therapist_id
    join avail av on av.therapist_id = tq.therapist_id
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

-- 4. Clear the stale display-order-only seed rows that 096 created for today
--    (and any future date) so the new starter-relative, shift-aware seed
--    recomputes them on next read. Safe: the feature was only just deployed
--    and the queue table is derived state that reseeds automatically. Past
--    days and any row whose turn was already consumed are left untouched.
delete from public.therapist_queue
where queue_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date
  and turn_consumed_at is null
  and not exists (
    select 1 from public.therapist_queue_day d
    where d.outlet_id = therapist_queue.outlet_id
      and d.queue_date = therapist_queue.queue_date
  );
