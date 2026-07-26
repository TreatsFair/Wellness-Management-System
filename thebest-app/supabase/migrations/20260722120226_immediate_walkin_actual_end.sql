-- Immediate paid walk-ins can start a few seconds after their scheduled minute.
-- Preserve the booked window and project the operational end from the actual
-- start before downstream segment/queue triggers run.

create or replace function public.project_appointment_end_on_actual_start()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_booked_date date;
  v_booked_start_time time;
  v_booked_end_time time;
  v_booked_start_local timestamp;
  v_booked_end_local timestamp;
  v_duration interval;
  v_current_end timestamptz;
begin
  if new.actual_started_at is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.actual_started_at is not null then
    return new;
  end if;

  v_current_end := case
    when new.end_at is null then null
    else new.end_at at time zone 'Asia/Kuala_Lumpur'
  end;

  -- start_appointment_service already writes a complete booked snapshot and
  -- an explicit valid expected end. Do not replace an operator-approved end.
  if new.booked_start_at is not null
     and new.booked_end_at is not null
     and v_current_end > new.actual_started_at then
    return new;
  end if;

  v_booked_date := coalesce(new.booked_date, new.appointment_date);
  v_booked_start_time := coalesce(new.booked_start_time, new.start_time);
  v_booked_end_time := coalesce(new.booked_end_time, new.end_time);
  v_booked_start_local := public.csp_start_at(
    v_booked_date,
    v_booked_start_time
  );
  v_booked_end_local := public.csp_end_at(
    v_booked_date,
    v_booked_start_time,
    v_booked_end_time
  );
  v_duration := v_booked_end_local - v_booked_start_local;

  if v_duration <= interval '0 seconds' then
    raise exception using
      errcode = '22023',
      message = 'Service duration must be greater than zero.';
  end if;

  new.booked_date := v_booked_date;
  new.booked_start_time := v_booked_start_time;
  new.booked_end_time := v_booked_end_time;
  new.booked_start_at := coalesce(
    new.booked_start_at,
    v_booked_start_local at time zone 'Asia/Kuala_Lumpur'
  );
  new.booked_end_at := coalesce(
    new.booked_end_at,
    v_booked_end_local at time zone 'Asia/Kuala_Lumpur'
  );
  new.end_at := (
    new.actual_started_at + v_duration
  ) at time zone 'Asia/Kuala_Lumpur';

  return new;
end;
$$;

revoke all on function public.project_appointment_end_on_actual_start()
  from public, anon, authenticated;

drop trigger if exists appointments_project_end_on_actual_start
  on public.appointments;
create trigger appointments_project_end_on_actual_start
before insert or update of actual_started_at on public.appointments
for each row execute function public.project_appointment_end_on_actual_start();

-- Repair the live legacy shape that exposed the dashboard failure. This is
-- intentionally predicate-based so the migration remains idempotent and does
-- not touch valid manual expected-end adjustments.
with invalid_start as (
  select
    appointment.id,
    coalesce(appointment.booked_date, appointment.appointment_date)
      as booked_date,
    coalesce(appointment.booked_start_time, appointment.start_time)
      as booked_start_time,
    coalesce(appointment.booked_end_time, appointment.end_time)
      as booked_end_time,
    public.csp_start_at(
      coalesce(appointment.booked_date, appointment.appointment_date),
      coalesce(appointment.booked_start_time, appointment.start_time)
    ) as booked_start_local,
    public.csp_end_at(
      coalesce(appointment.booked_date, appointment.appointment_date),
      coalesce(appointment.booked_start_time, appointment.start_time),
      coalesce(appointment.booked_end_time, appointment.end_time)
    ) as booked_end_local
  from public.appointments appointment
  where appointment.status::text = 'in_progress'
    and appointment.actual_started_at is not null
    and (
      appointment.end_at is null
      or appointment.end_at at time zone 'Asia/Kuala_Lumpur'
           <= appointment.actual_started_at
    )
)
update public.appointments appointment
set booked_date = invalid.booked_date,
    booked_start_time = invalid.booked_start_time,
    booked_end_time = invalid.booked_end_time,
    booked_start_at = coalesce(
      appointment.booked_start_at,
      invalid.booked_start_local at time zone 'Asia/Kuala_Lumpur'
    ),
    booked_end_at = coalesce(
      appointment.booked_end_at,
      invalid.booked_end_local at time zone 'Asia/Kuala_Lumpur'
    ),
    end_at = (
      appointment.actual_started_at
        + (invalid.booked_end_local - invalid.booked_start_local)
    ) at time zone 'Asia/Kuala_Lumpur',
    updated_at = now()
from invalid_start invalid
where appointment.id = invalid.id
  and invalid.booked_end_local > invalid.booked_start_local;

-- Dashboard/timetable/history loads call this maintenance RPC. Keep valid
-- manually adjusted end_at values, but recover safely if an older row still
-- contains an end at or before its actual start.
create or replace function public.complete_due_appointments(
  p_outlet_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_expected_end timestamptz;
  v_duration interval;
  v_updated integer := 0;
  v_transaction record;
  v_commission numeric;
begin
  for v_row in
    select appointment.*
    from public.appointments appointment
    where appointment.status::text = 'in_progress'
      and appointment.payment_status::text = 'paid'
      and appointment.actual_started_at is not null
      and (p_outlet_id is null or appointment.outlet_id = p_outlet_id)
    for update of appointment skip locked
  loop
    v_duration := coalesce(
      v_row.booked_end_at - v_row.booked_start_at,
      public.csp_end_at(
        coalesce(v_row.booked_date, v_row.appointment_date),
        coalesce(v_row.booked_start_time, v_row.start_time),
        coalesce(v_row.booked_end_time, v_row.end_time)
      ) - public.csp_start_at(
        coalesce(v_row.booked_date, v_row.appointment_date),
        coalesce(v_row.booked_start_time, v_row.start_time)
      ),
      v_row.end_at - v_row.start_at
    );

    v_expected_end := case
      when v_row.end_at is null then null
      else v_row.end_at at time zone 'Asia/Kuala_Lumpur'
    end;

    if v_expected_end is null
       or v_expected_end <= v_row.actual_started_at then
      if v_duration is null or v_duration <= interval '0 seconds' then
        continue;
      end if;
      v_expected_end := v_row.actual_started_at + v_duration;
    end if;

    if v_expected_end >= now() then
      continue;
    end if;

    update public.appointments
    set status = 'completed',
        actual_completed_at = v_expected_end,
        end_at = v_expected_end at time zone 'Asia/Kuala_Lumpur',
        updated_at = now()
    where id = v_row.id;
    v_updated := v_updated + 1;
  end loop;

  for v_transaction in
    select transaction.id,
           transaction.appointment_id,
           transaction.appointment_group_id
    from public.transactions transaction
    where transaction.source = 'online_booking'
      and transaction.payment_status::text = 'paid'
      and coalesce(transaction.therapist_commission_amount, 0) = 0
      and (p_outlet_id is null or transaction.outlet_id = p_outlet_id)
  loop
    v_commission := 0;
    if v_transaction.appointment_id is not null then
      select public.csp_commission_for_items(
        coalesce(appointment.service_items, '[]'::jsonb),
        appointment.therapist_id,
        'Therapist'
      )
      into v_commission
      from public.appointments appointment
      where appointment.id = v_transaction.appointment_id
        and appointment.status::text = 'completed'
        and appointment.actual_completed_at is not null;
    elsif v_transaction.appointment_group_id is not null
      and not exists (
        select 1
        from public.appointments pending
        where pending.appointment_group_id = v_transaction.appointment_group_id
          and pending.status::text not in (
            'completed', 'cancelled', 'no_show'
          )
      ) then
      select coalesce(sum(public.csp_commission_for_items(
        coalesce(appointment.service_items, '[]'::jsonb),
        appointment.therapist_id,
        'Therapist'
      )), 0)
      into v_commission
      from public.appointments appointment
      where appointment.appointment_group_id
              = v_transaction.appointment_group_id
        and appointment.status::text = 'completed'
        and appointment.actual_completed_at is not null;
    end if;

    if coalesce(v_commission, 0) > 0 then
      update public.transactions
      set therapist_commission_amount = v_commission,
          updated_at = now()
      where id = v_transaction.id
        and therapist_commission_amount = 0;
    end if;
  end loop;

  return v_updated;
end;
$$;

revoke all on function public.complete_due_appointments(uuid)
  from public, anon;
grant execute on function public.complete_due_appointments(uuid)
  to authenticated, service_role;
