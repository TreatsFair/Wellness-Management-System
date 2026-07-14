-- Mark missed scheduled bookings as no-show without touching payment state.
--
-- Operational status and payment status stay separate:
--   status = no_show means the customer never checked in / service never began.
--   payment_status remains unpaid/paid/refunded/voided exactly as-is.
--
-- This function is safe to run repeatedly. It only affects scheduled
-- appointments that are still pending/confirmed, have no actual start time,
-- and whose booked service window has already ended.

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
      a.booked_end_at,
      a.end_at,
      public.csp_end_at(
        a.appointment_date::date,
        a.start_time::time,
        a.end_time::time
      ) at time zone 'Asia/Kuala_Lumpur'
    ) < now();

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.mark_past_appointments_no_show(uuid)
  from public, anon;
grant execute on function public.mark_past_appointments_no_show(uuid)
  to authenticated, service_role;

select public.mark_past_appointments_no_show(null);
