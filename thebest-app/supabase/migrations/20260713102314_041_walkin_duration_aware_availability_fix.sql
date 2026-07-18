create or replace function public.get_walkin_therapist_availability(
  p_today date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid,
  name text,
  status text,
  free_at time,
  free_in_minutes integer
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_start_at timestamp := public.csp_start_at(p_today, p_now_time);
  v_end_at timestamp := v_start_at + make_interval(mins => greatest(p_duration, 1));
begin
  return query
  select
    t.id,
    t.name,
    case when busy.free_at is null then 'free_now' else 'busy' end,
    busy.free_at::time,
    case
      when busy.free_at is null then 0
      else greatest(floor(extract(epoch from (busy.free_at - v_start_at)) / 60)::integer, 0)
    end
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
  where coalesce(t.availability_status, true) = true
    and lower(coalesce(t.role, 'therapist')) = 'therapist'
  order by case when busy.free_at is null then 0 else 1 end, busy.free_at nulls first, t.name;
end;
$$;

grant execute on function public.get_walkin_therapist_availability(date, time, integer) to authenticated;
revoke execute on function public.get_walkin_therapist_availability(date, time, integer) from public, anon;
;
