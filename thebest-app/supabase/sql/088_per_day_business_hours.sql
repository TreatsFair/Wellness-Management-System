-- 088: Per-day business hours.
--
-- business_settings held a single open_time/close_time for the whole week, so an
-- outlet that closes at 23:00 on weekdays and 23:30 at weekends could not be
-- expressed. therapist_working_hours has always been per-day (day_of_week), and
-- the staff profile already offers an inherit-vs-custom choice via is_custom --
-- only the business side was missing the day dimension.
--
-- This migration:
--   1. adds public.business_hours (one row per outlet per weekday, + is_closed)
--   2. seeds it from the current flat business_settings values
--   3. sets the real Taman Wahyu hours (was a corrupt 11:00-11:30, which left
--      online booking with zero bookable slots for 50/60-minute services)
--   4. moves staff-hour propagation from business_settings to business_hours,
--      preserving the "unless is_custom" override semantics
--   5. keeps business_settings.open_time/close_time as a DERIVED envelope so the
--      existing consumers (timetable, dashboard, and the least() gate in
--      get_public_booking_slots_v2) keep working untouched.
--
-- Postgres dow convention throughout: 0=Sunday, 1=Monday ... 6=Saturday.

create table if not exists public.business_hours (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  day_of_week integer not null check (day_of_week between 0 and 6),
  open_time time not null,
  close_time time not null,
  is_closed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (outlet_id, day_of_week)
);

create index if not exists business_hours_outlet_day_idx
  on public.business_hours(outlet_id, day_of_week);

alter table public.business_hours enable row level security;

grant select, insert, update on table public.business_hours to authenticated;
revoke delete on table public.business_hours from authenticated;

drop policy if exists business_hours_select on public.business_hours;
create policy business_hours_select on public.business_hours
  for select using (public.is_staff_or_admin());

drop policy if exists business_hours_write on public.business_hours;
create policy business_hours_write on public.business_hours
  for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.touch_business_hours_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function public.touch_business_hours_updated_at() from public;

drop trigger if exists business_hours_touch_updated_at on public.business_hours;
create trigger business_hours_touch_updated_at
before update on public.business_hours
for each row execute function public.touch_business_hours_updated_at();

-- 2. Seed seven days per outlet from whatever the outlet currently has.
insert into public.business_hours (outlet_id, day_of_week, open_time, close_time)
select bs.outlet_id,
       day_number,
       coalesce(bs.open_time, '09:00'::time),
       coalesce(bs.close_time, '21:00'::time)
from public.business_settings bs
cross join generate_series(0, 6) day_number
on conflict (outlet_id, day_of_week) do nothing;

-- 3. Set the owner-confirmed schedules explicitly. Do not depend on whatever
--    stale flat values happened to be in business_settings when this runs.
update public.business_hours
set open_time  = case
                   when outlet_id = '00000000-0000-0000-0000-000000000128'
                     then time '10:30'
                   else time '11:00'
                 end,
    close_time = case
                   when outlet_id = '00000000-0000-0000-0000-000000000128'
                     then time '23:30'
                   when day_of_week between 1 and 4 then time '23:00'
                   else time '23:30'
                 end,
    is_closed  = false,
    updated_at = now()
where outlet_id in (
  '00000000-0000-0000-0000-000000000128',
  '00000000-0000-0000-0000-000000000002'
);

-- 4a. Recompute the business_settings envelope from the per-day rows.
--     close_time < open_time means the day runs past midnight, so closing
--     times are compared in minutes-from-midnight with
--     overnight days pushed past 1440 before taking the latest.
create or replace function public.sync_business_settings_envelope(p_outlet uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open time;
  v_close_minutes integer;
begin
  select min(open_time),
         max(
           (extract(epoch from close_time) / 60)::integer
           + case when close_time <= open_time then 1440 else 0 end
         )
  into v_open, v_close_minutes
  from public.business_hours
  where outlet_id = p_outlet and not is_closed;

  if v_open is null then return; end if;

  update public.business_settings
  set open_time  = v_open,
      close_time = (time '00:00' + make_interval(mins => v_close_minutes % 1440))::time
  where outlet_id = p_outlet;
end;
$$;

-- 4b. Propagate a day's business hours to every staff member who has not
--     overridden that specific day. A closed day removes the inherited rows so
--     no therapist covers it and no slot is offered.
create or replace function public.sync_staff_hours_from_business_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_closed then
    delete from public.therapist_working_hours
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week;
  else
    update public.therapist_working_hours
    set start_time = new.open_time,
        end_time   = new.close_time
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week
      and not is_custom;

    insert into public.therapist_working_hours (
      outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
    )
    select new.outlet_id, staff.id, new.day_of_week,
           new.open_time, new.close_time, false
    from public.therapists staff
    where staff.outlet_id = new.outlet_id
      and not exists (
        select 1 from public.therapist_working_hours hours
        where hours.therapist_id = staff.id
          and hours.day_of_week = new.day_of_week
      );
  end if;

  perform public.sync_business_settings_envelope(new.outlet_id);
  return new;
end;
$$;

drop trigger if exists business_hours_sync_staff on public.business_hours;
create trigger business_hours_sync_staff
after insert or update on public.business_hours
for each row execute function public.sync_staff_hours_from_business_hours();

-- 4c. business_settings.open_time/close_time is now derived, so the old flat
--     propagation trigger from 026 must go -- otherwise it would overwrite every
--     non-custom row with a single week-wide window and undo the per-day values.
drop trigger if exists business_settings_seed_staff_hours on public.business_settings;
drop trigger if exists business_settings_sync_staff_hours on public.business_settings;

-- 4d. New staff inherit the per-day schedule rather than one flat window.
create or replace function public.seed_default_therapist_working_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.therapist_working_hours (
    outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
  )
  select new.outlet_id, new.id, hours.day_of_week,
         hours.open_time, hours.close_time, false
  from public.business_hours hours
  where hours.outlet_id = new.outlet_id
    and not hours.is_closed
  on conflict (therapist_id, day_of_week, start_time) do nothing;

  return new;
end;
$$;

-- 5. Apply the seeded/corrected hours to existing staff and refresh envelopes.
--    Rows already marked is_custom keep their overrides.
do $$
declare
  v_row public.business_hours%rowtype;
begin
  for v_row in select * from public.business_hours loop
    if v_row.is_closed then
      delete from public.therapist_working_hours
      where outlet_id = v_row.outlet_id
        and day_of_week = v_row.day_of_week;
    else
      update public.therapist_working_hours
      set start_time = v_row.open_time,
          end_time   = v_row.close_time
      where outlet_id = v_row.outlet_id
        and day_of_week = v_row.day_of_week
        and not is_custom;

      insert into public.therapist_working_hours (
        outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
      )
      select v_row.outlet_id, staff.id, v_row.day_of_week,
             v_row.open_time, v_row.close_time, false
      from public.therapists staff
      where staff.outlet_id = v_row.outlet_id
        and not exists (
          select 1 from public.therapist_working_hours hours
          where hours.therapist_id = staff.id
            and hours.day_of_week = v_row.day_of_week
        );
    end if;
  end loop;

  perform public.sync_business_settings_envelope(o.outlet_id)
  from (select distinct outlet_id from public.business_hours) o;
end $$;

-- 6. The online booking window must allow the widest day; the per-day staff
--    hours are the real gate from here on.
update public.online_booking_outlet_settings s
set public_open_time  = greatest(s.public_open_time, bs.open_time),
    public_close_time = bs.close_time,
    updated_at = now()
from public.business_settings bs
where bs.outlet_id = s.outlet_id
  and s.outlet_id = '00000000-0000-0000-0000-000000000002';
