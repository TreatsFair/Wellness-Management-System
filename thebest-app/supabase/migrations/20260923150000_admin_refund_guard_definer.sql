-- The appointment trigger must see the protected refund ledger even when a
-- staff session updates an appointment. Its fixed query and empty search path
-- keep this narrow SECURITY DEFINER boundary safe.
create or replace function public.prevent_service_start_while_refunding()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if ((old.refund_pending and not new.refund_pending)
      or new.actual_started_at is distinct from old.actual_started_at
      or new.checked_in_at is distinct from old.checked_in_at
      or (new.status::text in ('in_progress', 'completed', 'cancelled', 'canceled')
          and old.status::text is distinct from new.status::text))
     and exists (
       select 1 from public.booking_holds h
       join public.booking_payment_attempts a
         on a.hold_token = h.public_token
         or a.hold_token = h.booking_group_token
       join public.booking_payment_refunds r on r.attempt_id = a.id
       where h.appointment_id = old.id and r.refund_kind = 'admin_full'
         and r.status in ('queued', 'submitting', 'requested', 'checking')
     ) then
    raise exception 'Service cannot start while a refund is pending';
  end if;
  return new;
end;
$function$;

revoke all on function public.prevent_service_start_while_refunding()
  from public, anon, authenticated;
