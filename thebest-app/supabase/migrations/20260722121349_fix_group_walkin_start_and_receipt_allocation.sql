-- Keep actual service state and paid group receipt allocation consistent.
--
-- Immediate group walk-ins were created with an in-progress group, but the
-- per-pax rows remained confirmed because create_appointment_group_with_csp
-- hard-codes their initial status. The payment RPC then set
-- actual_started_at, leaving the timetable with a contradictory "ready to
-- start" row. Treat the first actual start as the authoritative transition.

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

  if new.status::text in ('pending', 'confirmed') then
    new.status := 'in_progress';
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

-- A group transaction is one receipt for several appointment rows. Rebuild
-- its line snapshots from those canonical rows and persist appointmentId on
-- every line, so the UI can allocate the paid amount to each pax without
-- guessing from service names or array order.
create or replace function public.attach_group_appointment_ids_to_transaction()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_items jsonb;
begin
  if new.appointment_group_id is null
     or new.source::text is distinct from 'walkin' then
    return new;
  end if;

  select coalesce(
    jsonb_agg(
      service_item.item
        || jsonb_build_object('appointmentId', appointment.id::text)
      order by appointment.created_at, appointment.id, service_item.ordinality
    ),
    '[]'::jsonb
  )
  into v_items
  from public.appointments appointment
  cross join lateral jsonb_array_elements(
    coalesce(appointment.service_items, '[]'::jsonb)
  ) with ordinality as service_item(item, ordinality)
  where appointment.appointment_group_id = new.appointment_group_id;

  if jsonb_array_length(v_items) > 0 then
    new.service_items := v_items;
    new.item_count := jsonb_array_length(v_items);
  end if;

  return new;
end;
$$;

drop trigger if exists transactions_attach_group_appointment_ids
  on public.transactions;
create trigger transactions_attach_group_appointment_ids
before insert or update of appointment_group_id, service_items
on public.transactions
for each row
execute function public.attach_group_appointment_ids_to_transaction();

-- Repair only the contradictory active walk-ins and group receipts. The paid
-- totals themselves are correct and are intentionally left unchanged.
update public.appointments
set status = 'in_progress',
    updated_at = now()
where type::text = 'walkin'
  and status::text = 'confirmed'
  and actual_started_at is not null
  and actual_completed_at is null
  and appointment_date <= (now() at time zone 'Asia/Kuala_Lumpur')::date;

update public.transactions
set service_items = service_items,
    updated_at = now()
where source::text = 'walkin'
  and appointment_group_id is not null
  and exists (
    select 1
    from public.appointments appointment
    where appointment.appointment_group_id = transactions.appointment_group_id
      and jsonb_array_length(
        coalesce(appointment.service_items, '[]'::jsonb)
      ) > 0
  )
  and not exists (
    select 1
    from jsonb_array_elements(
      coalesce(transactions.service_items, '[]'::jsonb)
    ) service_item
    where coalesce(
      service_item ->> 'appointmentId',
      service_item ->> 'appointment_id',
      ''
    ) <> ''
  );

revoke all on function public.attach_group_appointment_ids_to_transaction()
  from public, anon, authenticated;
