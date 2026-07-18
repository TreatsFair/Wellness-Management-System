-- Staff slot generation must use the selected resources' outlet hours. The
-- previous function always read business_settings.id = 1, causing every outlet
-- to inherit outlet 1's closing time.
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
  v_outlet_id uuid;
  v_start_at timestamp;
  v_end_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_check record;
  v_score integer;
  v_reason text;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
begin
  if p_duration is null or p_duration <= 0 then
    return;
  end if;

  select t.outlet_id
  into v_outlet_id
  from public.therapists t
  join public.rooms r
    on r.id = p_room_id
   and r.outlet_id = t.outlet_id
  where t.id = p_therapist_id;

  -- A therapist and room from different outlets is never a valid allocation.
  if v_outlet_id is null then
    return;
  end if;

  select
    coalesce(bs.open_time, '09:00'::time),
    coalesce(bs.close_time, '21:00'::time)
  into v_open, v_close
  from public.business_settings bs
  where bs.outlet_id = v_outlet_id
  limit 1;

  -- Preserve safe defaults for an outlet that has not created settings yet.
  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);

  v_start_at := p_date + v_open;
  v_close_at := p_date
    + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.outlet_id = v_outlet_id
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and a.outlet_id = v_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  while v_start_at + make_interval(mins => p_duration) <= v_close_at loop
    v_end_at := v_start_at + make_interval(mins => p_duration);

    if v_start_at <= v_now_local then
      v_start_at := v_start_at + interval '30 minutes';
      continue;
    end if;

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
          and a.outlet_id = v_outlet_id
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
          and a.outlet_id = v_outlet_id
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

;
