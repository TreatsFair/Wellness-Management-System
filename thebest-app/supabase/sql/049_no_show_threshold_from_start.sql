-- No-show threshold is a late-arrival rule: mark a booking no-show after
-- booked start + threshold if nobody checked in.

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
      a.start_at,
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
