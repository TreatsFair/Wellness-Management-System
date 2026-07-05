-- Staff schedules inherit their outlet's business hours unless a day is
-- deliberately edited as a custom override in Dashboard -> Staff.

alter table public.therapist_working_hours
  add column if not exists is_custom boolean not null default false;

-- The old schema could not distinguish seeded rows from overrides. Treat the
-- current rows as inherited once, remove duplicate day rows, and align them to
-- the current outlet hours. New manual edits are marked is_custom = true.
with ranked as (
  select id,
         row_number() over (
           partition by therapist_id, day_of_week
           order by created_at, id
         ) as row_number
  from public.therapist_working_hours
)
delete from public.therapist_working_hours hours
using ranked
where hours.id = ranked.id
  and ranked.row_number > 1;

update public.therapist_working_hours hours
set start_time = settings.open_time,
    end_time = settings.close_time,
    is_custom = false
from public.business_settings settings
where settings.outlet_id = hours.outlet_id;

insert into public.therapist_working_hours (
  outlet_id,
  therapist_id,
  day_of_week,
  start_time,
  end_time,
  is_custom
)
select staff.outlet_id,
       staff.id,
       day_number,
       coalesce(settings.open_time, '09:00'::time),
       coalesce(settings.close_time, '21:00'::time),
       false
from public.therapists staff
left join public.business_settings settings
  on settings.outlet_id = staff.outlet_id
cross join generate_series(0, 6) day_number
where not exists (
  select 1
  from public.therapist_working_hours hours
  where hours.therapist_id = staff.id
    and hours.day_of_week = day_number
);

create or replace function public.seed_default_therapist_working_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open time;
  v_close time;
begin
  select open_time, close_time
  into v_open, v_close
  from public.business_settings
  where outlet_id = new.outlet_id;

  insert into public.therapist_working_hours (
    outlet_id,
    therapist_id,
    day_of_week,
    start_time,
    end_time,
    is_custom
  )
  select new.outlet_id,
         new.id,
         day_number,
         coalesce(v_open, '09:00'::time),
         coalesce(v_close, '21:00'::time),
         false
  from generate_series(0, 6) day_number
  on conflict (therapist_id, day_of_week, start_time) do nothing;

  return new;
end;
$$;

create or replace function public.sync_inherited_staff_business_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.therapist_working_hours
  set start_time = new.open_time,
      end_time = new.close_time
  where outlet_id = new.outlet_id
    and not is_custom;

  insert into public.therapist_working_hours (
    outlet_id,
    therapist_id,
    day_of_week,
    start_time,
    end_time,
    is_custom
  )
  select staff.outlet_id,
         staff.id,
         day_number,
         new.open_time,
         new.close_time,
         false
  from public.therapists staff
  cross join generate_series(0, 6) day_number
  where staff.outlet_id = new.outlet_id
    and not exists (
      select 1
      from public.therapist_working_hours hours
      where hours.therapist_id = staff.id
        and hours.day_of_week = day_number
    );

  return new;
end;
$$;

drop trigger if exists business_settings_seed_staff_hours
  on public.business_settings;
create trigger business_settings_seed_staff_hours
after insert on public.business_settings
for each row execute function public.sync_inherited_staff_business_hours();

drop trigger if exists business_settings_sync_staff_hours
  on public.business_settings;
create trigger business_settings_sync_staff_hours
after update of open_time, close_time on public.business_settings
for each row
when (
  old.open_time is distinct from new.open_time
  or old.close_time is distinct from new.close_time
)
execute function public.sync_inherited_staff_business_hours();

