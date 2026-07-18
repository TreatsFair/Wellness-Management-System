create or replace function public.csp_start_at(p_date date, p_start_time time)
returns timestamp
language sql
immutable
set search_path = public
as $$
  select p_date + p_start_time;
$$;

create or replace function public.csp_end_at(
  p_date date,
  p_start_time time,
  p_end_time time
)
returns timestamp
language sql
immutable
set search_path = public
as $$
  select p_date
    + p_end_time
    + case when p_end_time <= p_start_time then interval '1 day' else interval '0' end;
$$;

create or replace function public.csp_blocks_schedule(p_status text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select lower(coalesce(p_status, '')) in ('confirmed', 'in_progress');
$$;

create or replace function public.csp_appointment_start_at(a public.appointments)
returns timestamp
language sql
stable
set search_path = public
as $$
  select coalesce(a.start_at, public.csp_start_at(a.appointment_date::date, a.start_time::time));
$$;

create or replace function public.csp_appointment_end_at(a public.appointments)
returns timestamp
language sql
stable
set search_path = public
as $$
  select coalesce(a.end_at, public.csp_end_at(a.appointment_date::date, a.start_time::time, a.end_time::time));
$$;

create or replace function public.csp_appointment_block_end_at(
  a public.appointments
)
returns timestamp
language sql
stable
set search_path = public
as $$
  select public.csp_appointment_end_at(a)
    + make_interval(mins => greatest(coalesce(a.buffer_after_minutes, 0), 0));
$$;

create or replace function public.set_appointment_schedule_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.start_at := public.csp_start_at(new.appointment_date::date, new.start_time::time);
  new.end_at := public.csp_end_at(new.appointment_date::date, new.start_time::time, new.end_time::time);
  return new;
end;
$$;

create or replace function public.get_available_slots(
  p_date date,
  p_therapist_id uuid,
  p_room_id uuid,
  p_duration integer,
  p_exclude_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  classification text,
  score integer,
  reason text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_start_at timestamp;
  v_end_at timestamp;
  v_close_at timestamp;
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
begin
  if p_duration is null or p_duration <= 0 then
    return;
  end if;

  select coalesce(open_time, '09:00'::time), coalesce(close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings
  where id = 1;

  v_start_at := p_date + v_open;
  v_close_at := p_date
    + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  while v_start_at + make_interval(mins => p_duration) <= v_close_at loop
    v_end_at := v_start_at + make_interval(mins => p_duration);

    select *
    into v_check
    from public.check_booking_availability(
      p_date,
      v_start_at::time,
      v_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    if not coalesce(v_check.therapist_available, false) then
      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
    elsif coalesce(v_check.room_full, false) then
      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
    else
      v_score := 0;
      v_reason := 'standard_slot';

      if exists (
        select 1
        from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and public.csp_blocks_schedule(a.status::text)
          and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
          and public.csp_appointment_block_end_at(a) = v_start_at
          and (p_exclude_id is null or a.id <> p_exclude_id)
      ) then
        v_score := v_score + 2;
        v_reason := 'minimizes_gap';
      end if;

      if exists (
        select 1
        from public.appointments a
        where a.appointment_date::date between p_date - 1 and p_date + 1
          and public.csp_blocks_schedule(a.status::text)
          and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
          and public.csp_appointment_start_at(a) = v_end_at
          and (p_exclude_id is null or a.id <> p_exclude_id)
      ) then
        v_score := v_score + 1;
        if v_reason = 'standard_slot' then
          v_reason := 'minimizes_gap';
        end if;
      end if;

      if v_average_count > 0 and v_therapist_count < v_average_count then
        v_score := v_score + 1;
        if v_reason = 'standard_slot' then
          v_reason := 'balances_workload';
        end if;
      end if;

      start_time := v_start_at::time;
      end_time := v_end_at::time;
      classification := case when v_score > 0 then 'recommended' else 'standard' end;
      score := v_score;
      reason := v_reason;
      return next;
    end if;

    v_start_at := v_start_at + interval '30 minutes';
  end loop;
end;
$$;

create or replace function public.check_walkin_availability(
  p_today date,
  p_now_time time,
  p_duration integer,
  p_room_id uuid
)
returns table (
  therapists jsonb,
  zone_available_now boolean,
  zone_free_slots integer,
  can_start_now boolean,
  next_available_time time
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => p_duration);
  v_room_total integer := 1;
  v_room_booked integer := 0;
begin
  select greatest(coalesce(r.total_slots, 1), 1)
  into v_room_total
  from public.rooms r
  where r.id = p_room_id;

  v_room_total := coalesce(v_room_total, 1);

  select count(*)
  into v_room_booked
  from public.appointments a
  where a.appointment_date::date between p_today - 1 and p_today + 1
    and a.room_id = p_room_id
    and public.csp_blocks_schedule(a.status::text)
    and public.csp_appointment_start_at(a) < v_end_at
    and public.csp_appointment_block_end_at(a) > v_start_at;

  zone_free_slots := greatest(v_room_total - v_room_booked, 0);
  zone_available_now := zone_free_slots > 0;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'therapist_id', t.id,
      'name', t.name,
      'status', case when busy.free_at is null then 'free_now' else 'busy' end,
      'free_at', busy.free_at::time,
      'free_in_minutes', case
        when busy.free_at is null then 0
        else greatest(floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer, 0)
      end
    )
    order by case when busy.free_at is null then 0 else 1 end, busy.free_at nulls first, t.name
  ), '[]'::jsonb)
  into therapists
  from public.therapists t
  left join lateral (
    select max(public.csp_appointment_block_end_at(a)) as free_at
    from public.appointments a
    where a.appointment_date::date between p_today - 1 and p_today + 1
      and a.therapist_id = t.id
      and public.csp_blocks_schedule(a.status::text)
      and public.csp_appointment_start_at(a) < v_end_at
      and public.csp_appointment_block_end_at(a) > v_start_at
  ) busy on true
  where coalesce(t.is_active, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist';

  select min((item ->> 'free_at')::time)
  into next_available_time
  from jsonb_array_elements(therapists) item
  where item ->> 'free_at' is not null;

  can_start_now := zone_available_now
    and exists (
      select 1
      from jsonb_array_elements(therapists) item
      where item ->> 'status' = 'free_now'
    );

  return next;
end;
$$;;
