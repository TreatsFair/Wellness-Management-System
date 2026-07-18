-- Keep temporary payment reservations short and make no-show resource release
-- consistent across pax rows, parent groups, therapists, and rooms.

alter table public.booking_holds
  alter column expires_at set default (now() + interval '10 minutes');

create or replace function public.clamp_booking_hold_expiry()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.status = 'pending_payment' then
    new.expires_at := least(
      coalesce(new.expires_at, now() + interval '10 minutes'),
      now() + interval '10 minutes'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists clamp_booking_hold_expiry_trigger
  on public.booking_holds;
create trigger clamp_booking_hold_expiry_trigger
before insert on public.booking_holds
for each row execute function public.clamp_booking_hold_expiry();

revoke all on function public.clamp_booking_hold_expiry()
  from public, anon, authenticated;

-- Shorten holds already created under the old 15-minute rule without ever
-- extending a hold that already has an earlier expiry.
update public.booking_holds
set expires_at = least(expires_at, created_at + interval '10 minutes'),
    updated_at = now()
where status = 'pending_payment'
  and expires_at > created_at + interval '10 minutes';

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

  update public.booking_holds h
  set status = 'expired',
      expires_at = least(h.expires_at, now()),
      updated_at = now()
  where h.status = 'pending_payment'
    and (
      exists (
        select 1
        from public.appointments a
        where a.id = h.appointment_id
          and a.status = 'no_show'
      )
      or exists (
        select 1
        from public.appointments a
        where a.appointment_group_id = h.appointment_group_id
        group by a.appointment_group_id
        having bool_or(a.status = 'no_show')
          and bool_and(a.status in ('completed', 'cancelled', 'no_show'))
      )
    );

  update public.appointment_groups g
  set status = 'no_show'
  where (p_outlet_id is null or g.outlet_id = p_outlet_id)
    and exists (
      select 1
      from public.appointments a
      where a.appointment_group_id = g.id
      group by a.appointment_group_id
      having bool_or(a.status = 'no_show')
        and bool_and(a.status in ('completed', 'cancelled', 'no_show'))
    )
    and lower(coalesce(g.status, '')) <> 'no_show';

  return v_updated;
end;
$$;

revoke all on function public.mark_past_appointments_no_show(uuid)
  from public, anon;
grant execute on function public.mark_past_appointments_no_show(uuid)
  to authenticated, service_role;

select public.mark_past_appointments_no_show(null);
