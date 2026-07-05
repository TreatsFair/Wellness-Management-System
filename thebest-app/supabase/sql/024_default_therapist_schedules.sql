-- Give every staff record a seven-day default schedule matching outlet hours.

alter table public.therapist_working_hours
  add column if not exists is_custom boolean not null default false;

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
  select open_time, close_time into v_open, v_close
  from public.business_settings
  where outlet_id = new.outlet_id;

  insert into public.therapist_working_hours (
    outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
  )
  select new.outlet_id, new.id, day_number,
         coalesce(v_open, '09:00'::time), coalesce(v_close, '21:00'::time), false
  from generate_series(0, 6) day_number
  on conflict (therapist_id, day_of_week, start_time) do nothing;
  return new;
end;
$$;in 

drop trigger if exists therapists_seed_default_working_hours on public.therapists;
create trigger therapists_seed_default_working_hours
after insert on public.therapists
for each row execute function public.seed_default_therapist_working_hours();

insert into public.therapist_working_hours (
  outlet_id, therapist_id, day_of_week, start_time, end_time, is_custom
)
select t.outlet_id, t.id, day_number,
       coalesce(bs.open_time, '09:00'::time),
       coalesce(bs.close_time, '21:00'::time),
       false
from public.therapists t
left join public.business_settings bs on bs.outlet_id = t.outlet_id
cross join generate_series(0, 6) day_number
where not exists (
    select 1 from public.therapist_working_hours wh
    where wh.therapist_id = t.id and wh.day_of_week = day_number
  );
