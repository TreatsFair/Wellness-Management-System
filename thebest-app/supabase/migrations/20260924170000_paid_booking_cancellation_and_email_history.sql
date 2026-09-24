begin;

-- An appointment remains reserved while a Fiuu payment is captured or a
-- refund is pending. The refund completion path changes the payment attempt
-- to refunded before it cancels the appointment in the same transaction.
create function public.prevent_cancellation_of_paid_online_booking()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if new.status::text in ('cancelled', 'canceled')
     and old.status::text is distinct from new.status::text
     and exists (
       select 1
       from public.booking_holds h
       join public.booking_payment_attempts a
         on a.hold_token = h.public_token
         or a.hold_token = h.booking_group_token
       where h.appointment_id = old.id
         and a.gateway = 'fiuu'
         and a.status = 'confirmed'
     ) then
    raise exception 'Refund the confirmed Fiuu payment before cancelling this booking'
      using errcode = '23514';
  end if;
  return new;
end;
$function$;

revoke all on function public.prevent_cancellation_of_paid_online_booking()
  from public, anon, authenticated;

create trigger prevent_cancellation_of_paid_online_booking
before update of status on public.appointments
for each row execute function public.prevent_cancellation_of_paid_online_booking();

-- A narrow admin/staff read model: do not expose provider identifiers, error
-- payloads or raw outbox rows. "sent" means accepted by Resend, not delivered
-- to the customer's inbox.
create function public.list_admin_booking_email_history(p_attempt_id uuid)
returns table (
  delivery_kind text,
  status text,
  intended_recipient_email text,
  actual_delivery_recipient text,
  sent_at timestamptz,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $function$
declare
  v_outlet_id uuid;
begin
  select a.outlet_id into v_outlet_id
  from public.booking_payment_attempts a
  where a.id = p_attempt_id and a.gateway = 'fiuu';

  if (select auth.uid()) is null
     or not (select public.is_staff_or_admin())
     or v_outlet_id is null
     or not (select private.has_outlet_access(v_outlet_id)) then
    raise exception 'Staff access to this booking is required'
      using errcode = '42501';
  end if;

  return query
  select history.delivery_kind, history.status,
         history.intended_recipient_email, history.actual_delivery_recipient,
         history.sent_at, history.created_at
  from (
    select 'automatic'::text as delivery_kind, o.status,
           o.intended_recipient_email, o.actual_delivery_recipient,
           o.sent_at, o.created_at
    from public.booking_email_outbox o
    where o.payment_attempt_id = p_attempt_id
      and o.email_type = 'BOOKING_CONFIRMATION'
    union all
    select 'manual'::text as delivery_kind, d.status,
           d.intended_recipient_email, d.actual_delivery_recipient,
           d.sent_at, d.created_at
    from public.booking_email_delivery_attempts d
    where d.payment_attempt_id = p_attempt_id
      and d.email_type = 'BOOKING_CONFIRMATION'
  ) history
  order by coalesce(history.sent_at, history.created_at) desc,
           history.created_at desc
  limit 10;
end;
$function$;

revoke all on function public.list_admin_booking_email_history(uuid)
  from public, anon;
grant execute on function public.list_admin_booking_email_history(uuid)
  to authenticated;

commit;
