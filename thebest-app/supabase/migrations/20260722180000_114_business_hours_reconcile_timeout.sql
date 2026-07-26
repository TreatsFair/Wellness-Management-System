-- Keep outlet-hours updates below the statement timeout. The business-hours
-- propagation trigger updates several inherited therapist_working_hours rows;
-- migration 112's row trigger previously reconciled appointments once per
-- changed staff row. Suppress that nested fan-out, mark affected appointments
-- once, and let the existing two-minute recovery reconciler process them.

create or replace function public.reconcile_appointments_for_resource_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb := coalesce(to_jsonb(new), to_jsonb(old));
  v_therapist_id uuid;
  v_room_id uuid;
  v_service_id uuid;
  v_appointment record;
begin
  if tg_table_name = 'therapist_working_hours'
     and current_setting('app.business_hours_sync', true) = '1' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_table_name = 'therapists' then
    v_therapist_id := nullif(v_row ->> 'id', '')::uuid;
  elsif tg_table_name in ('therapist_working_hours', 'therapist_unavailability') then
    v_therapist_id := nullif(v_row ->> 'therapist_id', '')::uuid;
  elsif tg_table_name = 'rooms' then
    v_room_id := nullif(v_row ->> 'id', '')::uuid;
  elsif tg_table_name = 'services' then
    v_service_id := nullif(v_row ->> 'id', '')::uuid;
  end if;

  for v_appointment in
    select appointment.id
    from public.appointments appointment
    where appointment.actual_started_at is null
      and appointment.status::text in ('pending', 'confirmed')
      and public.csp_appointment_start_at(appointment)
            >= (now() at time zone 'Asia/Kuala_Lumpur')
      and (
        (v_therapist_id is not null
          and appointment.therapist_id = v_therapist_id)
        or (v_room_id is not null and appointment.room_id = v_room_id)
        or (v_service_id is not null and appointment.service_id = v_service_id)
      )
    order by appointment.appointment_date, appointment.start_time, appointment.id
  loop
    perform public.reconcile_appointment_resources(v_appointment.id, false);
  end loop;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.begin_business_hours_staff_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.business_hours_sync', '1', true);
  return new;
end;
$$;

revoke all on function public.begin_business_hours_staff_sync()
  from public, anon, authenticated;

create or replace function public.queue_business_hours_assignment_reconcile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_include_following_day boolean := new.close_time <= new.open_time;
begin
  if tg_op = 'UPDATE' then
    v_include_following_day := v_include_following_day
      or old.close_time <= old.open_time;
  end if;

  update public.appointments appointment
  set assignment_error_code = coalesce(
        appointment.assignment_error_code,
        'BUSINESS_HOURS_CHANGED'
      ),
      assignment_error_message = coalesce(
        appointment.assignment_error_message,
        'Outlet hours changed; the protected resources will be revalidated.'
      ),
      assignment_last_attempted_at = null,
      updated_at = now()
  where appointment.outlet_id = new.outlet_id
    and appointment.type::text = 'appointment'
    and appointment.actual_started_at is null
    and appointment.status::text in ('pending', 'confirmed')
    and public.csp_appointment_start_at(appointment)
          >= (now() at time zone 'Asia/Kuala_Lumpur')
    and (
      extract(dow from appointment.appointment_date)::integer = new.day_of_week
      or (
        v_include_following_day
        and extract(dow from appointment.appointment_date)::integer
              = ((new.day_of_week + 1) % 7)
      )
    );
  return new;
end;
$$;

revoke all on function public.queue_business_hours_assignment_reconcile()
  from public, anon, authenticated;

drop trigger if exists business_hours_sync_staff on public.business_hours;
drop trigger if exists business_hours_sync_staff_insert on public.business_hours;
drop trigger if exists business_hours_sync_staff_update on public.business_hours;
drop trigger if exists business_hours_begin_staff_sync_insert on public.business_hours;
drop trigger if exists business_hours_begin_staff_sync_update on public.business_hours;
drop trigger if exists business_hours_queue_reconcile_insert on public.business_hours;
drop trigger if exists business_hours_queue_reconcile_update on public.business_hours;

create trigger business_hours_begin_staff_sync_insert
before insert on public.business_hours
for each row execute function public.begin_business_hours_staff_sync();

create trigger business_hours_begin_staff_sync_update
before update of open_time, close_time, is_closed on public.business_hours
for each row
when (
  old.open_time is distinct from new.open_time
  or old.close_time is distinct from new.close_time
  or old.is_closed is distinct from new.is_closed
)
execute function public.begin_business_hours_staff_sync();

create trigger business_hours_sync_staff_insert
after insert on public.business_hours
for each row execute function public.sync_staff_hours_from_business_hours();

create trigger business_hours_sync_staff_update
after update of open_time, close_time, is_closed on public.business_hours
for each row
when (
  old.open_time is distinct from new.open_time
  or old.close_time is distinct from new.close_time
  or old.is_closed is distinct from new.is_closed
)
execute function public.sync_staff_hours_from_business_hours();

create trigger business_hours_queue_reconcile_insert
after insert on public.business_hours
for each row execute function public.queue_business_hours_assignment_reconcile();

create trigger business_hours_queue_reconcile_update
after update of open_time, close_time, is_closed on public.business_hours
for each row
when (
  old.open_time is distinct from new.open_time
  or old.close_time is distinct from new.close_time
  or old.is_closed is distinct from new.is_closed
)
execute function public.queue_business_hours_assignment_reconcile();

comment on function public.begin_business_hours_staff_sync() is
  'Suppresses repeated appointment reconciliation during inherited-hours propagation.';
comment on function public.queue_business_hours_assignment_reconcile() is
  'Queues affected future appointments once after an outlet-hours change.';
