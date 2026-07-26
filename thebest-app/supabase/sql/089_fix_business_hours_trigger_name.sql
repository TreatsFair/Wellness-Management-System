-- 089: Repair 088.
--
-- 088 tried to drop the old flat propagation trigger by the name used in the
-- 026 migration file (business_settings_seed_staff_hours), but the trigger
-- actually installed in the database is named business_settings_sync_staff_hours
-- (function sync_inherited_staff_business_hours). The drop was therefore a no-op
-- and the old trigger stayed live.
--
-- That trigger rewrites EVERY therapist_working_hours row for an outlet -- it
-- does not filter by day_of_week -- so when 088 recomputed the
-- business_settings envelope it fired and flattened the per-day values, giving
-- Taman Wahyu a 23:30 close on Mon-Thu instead of 23:00.
--
-- PV128's owner-confirmed schedule is 10:30-23:30 every day. Migration 090
-- reapplies both outlet schedules deterministically for already-deployed 088s.

drop trigger if exists business_settings_sync_staff_hours on public.business_settings;
drop trigger if exists business_settings_seed_staff_hours on public.business_settings;

-- Re-apply every day's business hours to staff who have not overridden that day.
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
    end if;
  end loop;

  perform public.sync_business_settings_envelope(o.outlet_id)
  from (select distinct outlet_id from public.business_hours) o;
end $$;
