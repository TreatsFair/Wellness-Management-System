-- Bug: mark_past_appointments_no_show never fired for staff-created appointments.
--
-- Those rows have booked_start_at = NULL (booked_* is only stamped at checkout),
-- so the function fell back to the raw naive `a.start_at`. In the coalesce the
-- result type is timestamptz (booked_start_at is timestamptz), which forces the
-- naive `start_at` to be coerced using the session timezone (UTC) -- treating a
-- 15:30 Kuala_Lumpur wall-clock time as 15:30 UTC, i.e. 8 hours in the future.
-- The no-show cutoff (scheduled_start + threshold) then landed 8 hours late, so
-- a customer 130+ minutes overdue still showed as "Late", never "No Show".
--
-- Fix: convert the naive start_at fallback with `at time zone
-- 'Asia/Kuala_Lumpur'`, exactly like the csp_start_at branch already does, so
-- all three coalesce branches are true KL-anchored timestamptz values.

create or replace function public.mark_past_appointments_no_show(
  p_outlet_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  update public.appointments a
  set status = 'no_show'::public.appointment_status,
      updated_at = now()
  where lower(a.status::text) in ('pending', 'confirmed')
    and coalesce(a.type::text, 'appointment') = 'appointment'
    and a.actual_started_at is null
    and (p_outlet_id is null or a.outlet_id = p_outlet_id)
    and coalesce(
      a.booked_start_at,
      a.start_at at time zone 'Asia/Kuala_Lumpur',
      public.csp_start_at(a.appointment_date::date, a.start_time::time)
        at time zone 'Asia/Kuala_Lumpur'
    ) + make_interval(
      mins => greatest(coalesce((
        select bs.no_show_threshold_minutes
        from public.business_settings bs
        where bs.outlet_id = a.outlet_id
        limit 1
      ), 30), 0)
    ) < now();

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.mark_past_appointments_no_show(uuid)
  from public, anon;
grant execute on function public.mark_past_appointments_no_show(uuid)
  to authenticated, service_role;
