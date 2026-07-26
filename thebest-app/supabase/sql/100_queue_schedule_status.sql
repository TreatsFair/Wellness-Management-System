-- Diagnostic counts so the therapist picker can tell an empty queue apart:
--   * nobody scheduled today (a genuine day off), versus
--   * schedules not set up (active therapists exist but have no working hours).
--
-- Returns, for an outlet/date:
--   active_count             - active therapist-role staff in the outlet
--   scheduled_count          - of those, how many are scheduled to work today
--                              (a working-hours row for today's DOW while the
--                              outlet is open) -- matches the queue's shift gate
--   unscheduled_active_count - active staff with NO working-hours rows at all
--                              (the "setup is missing" signal)
create or replace function public.get_queue_schedule_status(
  p_outlet_id uuid,
  p_date date
)
returns table (
  active_count integer,
  scheduled_count integer,
  unscheduled_active_count integer
)
language sql
security definer
set search_path = public
stable
as $$
  with active_t as (
    select t.id
    from public.therapists t
    where t.outlet_id = p_outlet_id
      and coalesce(t.availability_status, true) = true
      and lower(coalesce(t.role, 'therapist')) = 'therapist'
  ),
  scheduled as (
    select a.id
    from active_t a
    where exists (
      select 1 from public.therapist_working_hours wh
      join public.business_hours bh
        on bh.outlet_id = p_outlet_id
       and bh.day_of_week = wh.day_of_week
       and not coalesce(bh.is_closed, false)
      where wh.therapist_id = a.id
        and wh.day_of_week = extract(dow from p_date)::integer
    )
  ),
  has_any_hours as (
    select a.id
    from active_t a
    where exists (
      select 1 from public.therapist_working_hours wh
      where wh.therapist_id = a.id
    )
  )
  select
    (select count(*) from active_t)::integer,
    (select count(*) from scheduled)::integer,
    ((select count(*) from active_t) - (select count(*) from has_any_hours))::integer;
$$;

revoke all on function public.get_queue_schedule_status(uuid, date) from public, anon;
grant execute on function public.get_queue_schedule_status(uuid, date) to authenticated;
