-- Make the check-in decision authoritative. The previous function always
-- extended to actual start + booked duration and always bypassed overlap
-- enforcement, even after staff chose "Start without extending".

drop function if exists public.start_appointment_service(uuid, timestamptz);

create or replace function public.start_appointment_service(
  p_appointment_id uuid,
  p_started_at timestamptz default now(),
  p_expected_end_at timestamptz default null,
  p_allow_late_extension_overlap boolean default false
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

  if not found then raise exception 'Appointment was not found.'; end if;
  if v_appointment.appointment_date <>
      (p_started_at at time zone 'Asia/Kuala_Lumpur')::date then
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

  v_expected_end := coalesce(p_expected_end_at, p_started_at + v_duration);
  if v_expected_end <= p_started_at then
    raise exception 'Expected end time must be after the actual start time.';
  end if;
  perform set_config(
    'app.allow_late_extension_overlap',
    case when p_allow_late_extension_overlap then 'on' else 'off' end,
    true
  );

  update public.appointments
  set booked_date = coalesce(booked_date, appointment_date),
      booked_start_time = coalesce(booked_start_time, start_time),
      booked_end_time = coalesce(booked_end_time, end_time),
      booked_start_at = coalesce(
        booked_start_at,
        public.csp_start_at(appointment_date, start_time)
          at time zone 'Asia/Kuala_Lumpur'
      ),
      booked_end_at = coalesce(
        booked_end_at,
        public.csp_end_at(appointment_date, start_time, end_time)
          at time zone 'Asia/Kuala_Lumpur'
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

revoke all on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) from public, anon;
grant execute on function public.start_appointment_service(
  uuid, timestamptz, timestamptz, boolean
) to authenticated;

create or replace function public.start_appointment_group_service(
  p_appointment_group_id uuid,
  p_appointment_ids uuid[],
  p_started_at timestamptz default now(),
  p_expected_end_by_appointment jsonb default '{}'::jsonb,
  p_allow_overlap_by_appointment jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_count integer;
  v_expected_end timestamptz;
  v_allow_overlap boolean;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_appointment_ids is null or cardinality(p_appointment_ids) = 0 then
    raise exception 'No appointments were supplied.';
  end if;

  select count(*)::integer into v_count
  from public.appointments a
  where a.appointment_group_id = p_appointment_group_id;
  if cardinality(p_appointment_ids) <> v_count
      or cardinality(p_appointment_ids) <> (
        select count(distinct supplied.id)::integer
        from unnest(p_appointment_ids) supplied(id)
      ) then
    raise exception 'The complete appointment group is required.';
  end if;

  foreach v_id in array p_appointment_ids loop
    if not exists (
      select 1 from public.appointments a
      where a.id = v_id and a.appointment_group_id = p_appointment_group_id
    ) then
      raise exception 'Appointment does not belong to this group: %', v_id;
    end if;
    v_expected_end := nullif(
      p_expected_end_by_appointment ->> v_id::text,
      ''
    )::timestamptz;
    v_allow_overlap := coalesce(
      (p_allow_overlap_by_appointment ->> v_id::text)::boolean,
      false
    );
    perform public.start_appointment_service(
      v_id,
      p_started_at,
      v_expected_end,
      v_allow_overlap
    );
  end loop;
  return cardinality(p_appointment_ids);
end;
$$;

revoke all on function public.start_appointment_group_service(
  uuid, uuid[], timestamptz, jsonb, jsonb
) from public, anon;
grant execute on function public.start_appointment_group_service(
  uuid, uuid[], timestamptz, jsonb, jsonb
) to authenticated;
