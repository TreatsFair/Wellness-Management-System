create or replace function public.enforce_no_future_service_progress()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status in ('in_progress', 'completed')
     and new.appointment_date > (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using
      errcode = '23514',
      message = 'Cannot start or complete a service before its appointment date.';
  end if;
  return new;
end;
$$;

create or replace function public.start_appointment_service(
  p_appointment_id uuid,
  p_started_at timestamptz default now()
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_duration interval;
  v_expected_end timestamptz;
  v_updated public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  if v_appointment.appointment_date <> (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service can only be started on its appointment date.';
  end if;
  if v_appointment.status not in ('pending', 'confirmed') then
    raise exception 'Only a pending or confirmed service can be started.';
  end if;
  if v_appointment.payment_status <> 'paid' then
    raise exception 'Payment must be confirmed before starting this service.';
  end if;
  if v_appointment.actual_started_at is not null then
    raise exception 'This service has already started.';
  end if;

  v_duration := coalesce(
    v_appointment.booked_end_at - v_appointment.booked_start_at,
    public.csp_end_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time),
      coalesce(v_appointment.booked_end_time, v_appointment.end_time)
    ) - public.csp_start_at(
      coalesce(v_appointment.booked_date, v_appointment.appointment_date),
      coalesce(v_appointment.booked_start_time, v_appointment.start_time)
    ),
    v_appointment.end_at - v_appointment.start_at
  );
  if v_duration is null or v_duration <= interval '0 seconds' then
    raise exception 'Service duration must be greater than zero.';
  end if;

  v_expected_end := p_started_at + v_duration;
  perform set_config('app.allow_late_extension_overlap', 'on', true);

  update public.appointments
  set booked_date = coalesce(booked_date, appointment_date),
      booked_start_time = coalesce(booked_start_time, start_time),
      booked_end_time = coalesce(booked_end_time, end_time),
      booked_start_at = coalesce(
        booked_start_at,
        public.csp_start_at(appointment_date, start_time) at time zone 'Asia/Kuala_Lumpur'
      ),
      booked_end_at = coalesce(
        booked_end_at,
        public.csp_end_at(appointment_date, start_time, end_time) at time zone 'Asia/Kuala_Lumpur'
      ),
      status = 'in_progress',
      actual_started_at = p_started_at,
      end_at = v_expected_end at time zone 'Asia/Kuala_Lumpur',
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  return v_updated;
end;
$$;

create or replace function public.adjust_appointment_service_end(
  p_appointment_id uuid,
  p_expected_end_at timestamptz
)
returns public.appointments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_updated public.appointments%rowtype;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception 'Appointment was not found.';
  end if;
  if v_appointment.status <> 'in_progress' or v_appointment.actual_started_at is null then
    raise exception 'Only an in-progress service can change its expected end time.';
  end if;
  if v_appointment.appointment_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception 'Service time can only be adjusted on its appointment date.';
  end if;
  if p_expected_end_at <= v_appointment.actual_started_at then
    raise exception 'Expected end time must be after the actual start time.';
  end if;

  perform set_config('app.allow_late_extension_overlap', 'on', true);
  update public.appointments
  set end_at = p_expected_end_at at time zone 'Asia/Kuala_Lumpur',
      updated_at = now()
  where id = p_appointment_id
  returning * into v_updated;

  return v_updated;
end;
$$;

-- Existing active services predate end_at becoming the authoritative live end.
-- Preserve their full booked duration before switching completion to that field.
update public.appointments a
set end_at = (
  a.actual_started_at + coalesce(
    a.booked_end_at - a.booked_start_at,
    public.csp_end_at(
      coalesce(a.booked_date, a.appointment_date),
      coalesce(a.booked_start_time, a.start_time),
      coalesce(a.booked_end_time, a.end_time)
    ) - public.csp_start_at(
      coalesce(a.booked_date, a.appointment_date),
      coalesce(a.booked_start_time, a.start_time)
    ),
    a.end_at - a.start_at
  )
) at time zone 'Asia/Kuala_Lumpur',
updated_at = now()
where a.status = 'in_progress'
  and a.actual_started_at is not null;

create or replace function public.complete_due_appointments(p_outlet_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_expected_end timestamptz;
  v_updated integer := 0;
  v_transaction record;
  v_commission numeric;
begin
  for v_row in
    select a.*
    from public.appointments a
    where a.status = 'in_progress'
      and a.payment_status = 'paid'
      and a.actual_started_at is not null
      and (p_outlet_id is null or a.outlet_id = p_outlet_id)
    for update of a skip locked
  loop
    v_expected_end := coalesce(
      v_row.end_at at time zone 'Asia/Kuala_Lumpur',
      v_row.actual_started_at + (
        coalesce(
          v_row.booked_end_at,
          public.csp_end_at(
            coalesce(v_row.booked_date, v_row.appointment_date),
            coalesce(v_row.booked_start_time, v_row.start_time),
            coalesce(v_row.booked_end_time, v_row.end_time)
          ) at time zone 'Asia/Kuala_Lumpur'
        ) - coalesce(
          v_row.booked_start_at,
          public.csp_start_at(
            coalesce(v_row.booked_date, v_row.appointment_date),
            coalesce(v_row.booked_start_time, v_row.start_time)
          ) at time zone 'Asia/Kuala_Lumpur'
        )
      )
    );

    if v_expected_end >= now() then
      continue;
    end if;

    update public.appointments
    set status = 'completed',
        actual_completed_at = v_expected_end,
        updated_at = now()
    where id = v_row.id;
    v_updated := v_updated + 1;
  end loop;

  for v_transaction in
    select t.id, t.appointment_id, t.appointment_group_id
    from public.transactions t
    where t.source = 'online_booking'
      and t.payment_status = 'paid'
      and coalesce(t.therapist_commission_amount, 0) = 0
      and (p_outlet_id is null or t.outlet_id = p_outlet_id)
  loop
    v_commission := 0;
    if v_transaction.appointment_id is not null then
      select public.csp_commission_for_items(
        coalesce(a.service_items, '[]'::jsonb), a.therapist_id, 'Therapist'
      ) into v_commission
      from public.appointments a
      where a.id = v_transaction.appointment_id
        and a.status = 'completed'
        and a.actual_completed_at is not null;
    elsif v_transaction.appointment_group_id is not null
      and not exists (
        select 1 from public.appointments pending
        where pending.appointment_group_id = v_transaction.appointment_group_id
          and pending.status not in ('completed', 'cancelled', 'no_show')
      ) then
      select coalesce(sum(public.csp_commission_for_items(
        coalesce(a.service_items, '[]'::jsonb), a.therapist_id, 'Therapist'
      )), 0) into v_commission
      from public.appointments a
      where a.appointment_group_id = v_transaction.appointment_group_id
        and a.status = 'completed'
        and a.actual_completed_at is not null;
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

revoke all on function public.start_appointment_service(uuid, timestamptz) from public;
revoke all on function public.adjust_appointment_service_end(uuid, timestamptz) from public;
grant execute on function public.start_appointment_service(uuid, timestamptz) to authenticated;
grant execute on function public.adjust_appointment_service_end(uuid, timestamptz) to authenticated;
