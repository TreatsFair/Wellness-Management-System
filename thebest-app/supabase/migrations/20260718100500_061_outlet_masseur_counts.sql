-- Expose how many active masseurs of each gender an outlet employs, so the
-- booking website can warn a group at the guest step ("only 1 female masseur
-- works here — at most 1 guest can choose Female") instead of letting them
-- discover an empty date list later. Counts only — no names or details leak.
--
-- Added as a _v2 function (create-only) so the original
-- list_public_booking_outlets keeps its signature; the booking-api Edge
-- Function switches to the v2.

create or replace function public.list_public_booking_outlets_v2()
returns table (
  code text, name text, address text, phone text,
  customer_therapist_selection_allowed boolean,
  female_masseurs integer, male_masseurs integer, total_masseurs integer
)
language sql security definer set search_path = public stable as $$
  select o.code, o.name, o.address, o.phone, s.customer_therapist_selection_allowed,
    (select count(*) from public.therapists t
     where t.outlet_id = o.id and coalesce(t.availability_status, true)
       and lower(coalesce(t.role, 'therapist')) = 'therapist'
       and lower(coalesce(t.gender, '')) = 'female')::integer,
    (select count(*) from public.therapists t
     where t.outlet_id = o.id and coalesce(t.availability_status, true)
       and lower(coalesce(t.role, 'therapist')) = 'therapist'
       and lower(coalesce(t.gender, '')) = 'male')::integer,
    (select count(*) from public.therapists t
     where t.outlet_id = o.id and coalesce(t.availability_status, true)
       and lower(coalesce(t.role, 'therapist')) = 'therapist')::integer
  from public.outlets o
  join public.online_booking_outlet_settings s on s.outlet_id = o.id
  where o.is_active and s.online_booking_enabled
  order by o.name;
$$;

revoke all on function public.list_public_booking_outlets_v2() from public, anon, authenticated;
grant execute on function public.list_public_booking_outlets_v2() to service_role;
