-- 090: Make per-day business hours deterministic and safe after the first
-- production deployment of 088/089.
--
-- Owner-confirmed schedules:
--   PV128       every day 10:30-23:30
--   Taman Wahyu Mon-Thu   11:00-23:00
--                Fri-Sun  11:00-23:30
--
-- A closed business day is an outlet-wide rule. Inherited schedules are
-- removed; custom overrides are archived and restored exactly when the day is
-- reopened. The guard below prevents a new staff schedule from being created
-- while the outlet is closed.

begin;

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

create table if not exists public.business_hours_staff_override_archive (
  id uuid primary key,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  therapist_id uuid not null references public.therapists(id) on delete cascade,
  day_of_week integer not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now(),
  unique (therapist_id, day_of_week, start_time)
);

alter table public.business_hours_staff_override_archive enable row level security;
revoke all on table public.business_hours_staff_override_archive
  from public, anon, authenticated;

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

-- Remove both names created by 026 before the derived envelope is updated.
drop trigger if exists business_settings_sync_staff_hours
  on public.business_settings;
drop trigger if exists business_settings_seed_staff_hours
  on public.business_settings;

-- Seed any missing outlet/day rows first, then deterministically repair the two
-- known outlet schedules. The upsert also repairs a partial 088 deployment.
insert into public.business_hours (
  outlet_id, day_of_week, open_time, close_time, is_closed
)
select bs.outlet_id,
       day_number,
       coalesce(bs.open_time, time '09:00'),
       coalesce(bs.close_time, time '21:00'),
       false
from public.business_settings bs
cross join generate_series(0, 6) day_number
on conflict (outlet_id, day_of_week) do nothing;

insert into public.business_hours (
  outlet_id, day_of_week, open_time, close_time, is_closed, updated_at
)
select outlet_id,
       day_number,
       open_time,
       case
         when outlet_id = '00000000-0000-0000-0000-000000000002'
              and day_number between 1 and 4 then time '23:00'
         else close_time
       end,
       false,
       now()
from (
  values
    ('00000000-0000-0000-0000-000000000128'::uuid, time '10:30', time '23:30'),
    ('00000000-0000-0000-0000-000000000002'::uuid, time '11:00', time '23:30')
) configured(outlet_id, open_time, close_time)
cross join generate_series(0, 6) day_number
on conflict (outlet_id, day_of_week) do update
set open_time = excluded.open_time,
    close_time = excluded.close_time,
    is_closed = excluded.is_closed,
    updated_at = now();

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
  where outlet_id = p_outlet
    and not is_closed;

  if v_open is null then
    return;
  end if;

  update public.business_settings
  set open_time = v_open,
      close_time = (
        time '00:00' + make_interval(mins => v_close_minutes % 1440)
      )::time
  where outlet_id = p_outlet;
end;
$$;

revoke all on function public.sync_business_settings_envelope(uuid)
  from public, anon, authenticated;

create or replace function public.sync_staff_hours_from_business_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_closed then
    -- Preserve private staff overrides while making every existing scheduling
    -- query see no working shift for the closed weekday.
    insert into public.business_hours_staff_override_archive (
      id, outlet_id, therapist_id, day_of_week, start_time, end_time
    )
    select id, outlet_id, therapist_id, day_of_week, start_time, end_time
    from public.therapist_working_hours
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week
      and is_custom
    on conflict (id) do update
    set start_time = excluded.start_time,
        end_time = excluded.end_time;

    delete from public.therapist_working_hours
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week;
  else
    insert into public.therapist_working_hours (
      id, outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
    )
    select id, outlet_id, therapist_id, day_of_week, start_time, end_time, true
    from public.business_hours_staff_override_archive
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week
    on conflict (therapist_id, day_of_week, start_time) do nothing;

    delete from public.business_hours_staff_override_archive
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week;

    update public.therapist_working_hours
    set start_time = new.open_time,
        end_time = new.close_time
    where outlet_id = new.outlet_id
      and day_of_week = new.day_of_week
      and not is_custom;

    insert into public.therapist_working_hours (
      outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
    )
    select new.outlet_id,
           staff.id,
           new.day_of_week,
           new.open_time,
           new.close_time,
           false
    from public.therapists staff
    where staff.outlet_id = new.outlet_id
      and not exists (
        select 1
        from public.therapist_working_hours hours
        where hours.therapist_id = staff.id
          and hours.day_of_week = new.day_of_week
      );
  end if;

  perform public.sync_business_settings_envelope(new.outlet_id);
  return new;
end;
$$;

revoke all on function public.sync_staff_hours_from_business_hours()
  from public, anon, authenticated;

drop trigger if exists business_hours_sync_staff on public.business_hours;
create trigger business_hours_sync_staff
after insert or update of open_time, close_time, is_closed
on public.business_hours
for each row execute function public.sync_staff_hours_from_business_hours();

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
  select new.outlet_id,
         new.id,
         hours.day_of_week,
         hours.open_time,
         hours.close_time,
         false
  from public.business_hours hours
  where hours.outlet_id = new.outlet_id
    and not hours.is_closed
  on conflict (therapist_id, day_of_week, start_time) do nothing;

  return new;
end;
$$;

revoke all on function public.seed_default_therapist_working_hours()
  from public, anon, authenticated;

-- Repair existing inherited schedules and enforce closed days now.
do $$
declare
  v_row public.business_hours%rowtype;
begin
  for v_row in select * from public.business_hours loop
    if v_row.is_closed then
      insert into public.business_hours_staff_override_archive (
        id, outlet_id, therapist_id, day_of_week, start_time, end_time
      )
      select id, outlet_id, therapist_id, day_of_week, start_time, end_time
      from public.therapist_working_hours
      where outlet_id = v_row.outlet_id
        and day_of_week = v_row.day_of_week
        and is_custom
      on conflict (id) do update
      set start_time = excluded.start_time,
          end_time = excluded.end_time;

      delete from public.therapist_working_hours
      where outlet_id = v_row.outlet_id
        and day_of_week = v_row.day_of_week;
    else
      insert into public.therapist_working_hours (
        id, outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
      )
      select id, outlet_id, therapist_id, day_of_week, start_time, end_time, true
      from public.business_hours_staff_override_archive
      where outlet_id = v_row.outlet_id
        and day_of_week = v_row.day_of_week
      on conflict (therapist_id, day_of_week, start_time) do nothing;

      delete from public.business_hours_staff_override_archive
      where outlet_id = v_row.outlet_id
        and day_of_week = v_row.day_of_week;

      update public.therapist_working_hours
      set start_time = v_row.open_time,
          end_time = v_row.close_time
      where outlet_id = v_row.outlet_id
        and day_of_week = v_row.day_of_week
        and not is_custom;

      insert into public.therapist_working_hours (
        outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
      )
      select v_row.outlet_id,
             staff.id,
             v_row.day_of_week,
             v_row.open_time,
             v_row.close_time,
             false
      from public.therapists staff
      where staff.outlet_id = v_row.outlet_id
        and not exists (
          select 1
          from public.therapist_working_hours hours
          where hours.therapist_id = staff.id
            and hours.day_of_week = v_row.day_of_week
        );
    end if;
  end loop;

  perform public.sync_business_settings_envelope(outlets.outlet_id)
  from (select distinct outlet_id from public.business_hours) outlets;
end;
$$;

create or replace function public.prevent_staff_hours_on_closed_day()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.business_hours hours
    where hours.outlet_id = new.outlet_id
      and hours.day_of_week = new.day_of_week
      and hours.is_closed
  ) then
    raise exception 'The outlet is closed on this weekday';
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_staff_hours_on_closed_day() from public;

drop trigger if exists therapist_hours_reject_closed_day
  on public.therapist_working_hours;
create trigger therapist_hours_reject_closed_day
before insert or update of outlet_id, day_of_week
on public.therapist_working_hours
for each row execute function public.prevent_staff_hours_on_closed_day();

-- Walk-in availability previously ignored staff schedules. Requiring a shift
-- that fits the complete service window makes a closed day return no available
-- therapist and also respects split shifts and overnight work.
create or replace function public.get_walkin_therapist_availability(
  p_today date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid,
  name text,
  status text,
  free_at time,
  free_in_minutes integer
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at
    + make_interval(mins => greatest(p_duration, 1));
begin
  return query
  select
    staff.id,
    staff.name,
    case when busy.free_at is null then 'free_now' else 'busy' end,
    busy.free_at::time,
    case
      when busy.free_at is null then 0
      else greatest(
        floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer,
        0
      )
    end
  from public.therapists staff
  left join lateral (
    select max(public.csp_appointment_block_end_at(a)) as free_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.therapist_id = staff.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_block_end_at(a) > v_start_at
  ) busy on true
  where coalesce(staff.availability_status, true) = true
    and lower(coalesce(staff.role, 'therapist')) = 'therapist'
    and exists (
      select 1
      from public.therapist_working_hours wh
      join public.business_hours hours
        on hours.outlet_id = staff.outlet_id
       and hours.day_of_week = wh.day_of_week
       and not hours.is_closed
      where wh.therapist_id = staff.id
        and (
          (
            wh.day_of_week = extract(dow from p_today)::integer
            and p_today + wh.start_time <= v_start_at
            and p_today + wh.end_time
              + case
                  when wh.end_time <= wh.start_time then interval '1 day'
                  else interval '0'
                end >= v_end_at
          )
          or (
            wh.end_time <= wh.start_time
            and wh.day_of_week = extract(dow from p_today - 1)::integer
            and (p_today - 1) + wh.start_time <= v_start_at
            and (p_today - 1) + wh.end_time + interval '1 day' >= v_end_at
          )
        )
    )
    and not exists (
      select 1
      from public.therapist_unavailability unavailable
      where unavailable.therapist_id = staff.id
        and (unavailable.starts_at at time zone 'Asia/Kuala_Lumpur') < v_end_at
        and (unavailable.ends_at at time zone 'Asia/Kuala_Lumpur') > v_start_at
    )
  order by
    case when busy.free_at is null then 0 else 1 end,
    busy.free_at nulls first,
    staff.name;
end;
$$;

grant execute on function public.get_walkin_therapist_availability(
  date, time, integer
) to authenticated;
revoke execute on function public.get_walkin_therapist_availability(
  date, time, integer
) from public, anon;

-- Retain the unrelated catalogue spelling repair that was prepared as 087.
update public.online_booking_services
set public_name = 'Body Massage'
where outlet_id = '00000000-0000-0000-0000-000000000002'
  and public_name = 'Body Masssage';

commit;

