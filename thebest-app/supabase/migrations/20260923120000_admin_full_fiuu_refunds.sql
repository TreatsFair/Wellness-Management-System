-- Admin-initiated full Fiuu refunds. This migration is deliberately NOT
-- applied by a local build; apply to a named project only after approval.
-- A queued/requested refund retains the appointment's capacity. Only a
-- confirmed Fiuu refund releases the slot.

alter table public.booking_payment_refunds
  add column refund_kind text not null default 'late_reversal'
    check (refund_kind in ('late_reversal', 'admin_full')),
  add column merchant_ref_id text unique,
  add column initiated_by uuid references public.profiles(id),
  add column initiated_at timestamptz,
  add column initiation_reason text,
  add column cancellation_error text;

alter table public.appointments
  add column refund_pending boolean not null default false;

create function public.prevent_service_start_while_refunding()
returns trigger language plpgsql set search_path = '' as $function$
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
create trigger prevent_service_start_while_refunding
before update of status, actual_started_at, checked_in_at, refund_pending
on public.appointments for each row
execute function public.prevent_service_start_while_refunding();

create function public.request_admin_fiuu_full_refund(
  p_attempt_id uuid, p_reason text
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_attempt public.booking_payment_attempts%rowtype;
  v_hold public.booking_holds%rowtype;
  v_appointment public.appointments%rowtype;
  v_channel text;
  v_refund_id uuid;
  v_count integer := 0;
begin
  if (select auth.uid()) is null or not (select public.is_admin()) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 8 and 500 then
    raise exception 'Enter a refund reason (8-500 characters)';
  end if;

  select * into v_attempt from public.booking_payment_attempts
  where id = p_attempt_id for update;
  if not found or v_attempt.status <> 'confirmed'
     or v_attempt.gateway_transaction_id !~ '^[0-9]{1,20}$'
     or not (select private.has_outlet_access(v_attempt.outlet_id)) then
    raise exception 'Confirmed Fiuu payment in an accessible outlet required';
  end if;
  if exists (select 1 from public.booking_payment_refunds
             where attempt_id = v_attempt.id) then
    raise exception 'A refund already exists for this payment';
  end if;
  if v_attempt.resolved_at is null
     or v_attempt.resolved_at < now() - interval '180 days' then
    raise exception 'Payment is outside the supported refund window';
  end if;
  select e.channel into v_channel from public.booking_payment_events e
  where e.attempt_id = v_attempt.id and e.outcome = 'confirmed'
  order by e.received_at desc, e.id desc limit 1;
  -- Online-banking channels require beneficiary details. Do not request an
  -- unfulfillable refund or collect bank data in this first release.
  if v_channel is distinct from 'TNG-EWALLET' then
    raise exception 'This payment channel needs manual Fiuu refund review';
  end if;
  if not exists (
    select 1 from public.transactions t
    where t.receipt_number = 'FIUU-' || upper(v_attempt.order_id)
      and t.payment_status::text = 'paid'
  ) then
    raise exception 'The paid booking receipt could not be verified';
  end if;

  for v_hold in
    select h.* from public.booking_holds h
    where h.public_token = v_attempt.hold_token
       or h.booking_group_token = v_attempt.hold_token
    order by h.id for update
  loop
    v_count := v_count + 1;
    if v_hold.status <> 'confirmed' or v_hold.appointment_id is null then
      raise exception 'Only future confirmed bookings can be refunded here';
    end if;
    select * into v_appointment from public.appointments a
    where a.id = v_hold.appointment_id for update;
    if not found or (v_appointment.start_at at time zone 'Asia/Kuala_Lumpur') <= now()
       or v_appointment.status::text not in ('confirmed', 'pending')
       or v_appointment.actual_started_at is not null
       or v_appointment.refund_pending then
      raise exception 'The booking has started, changed, or is already refunding';
    end if;
  end loop;
  if v_count = 0 then
    raise exception 'No confirmed appointment is linked to this payment';
  end if;

  insert into public.booking_payment_refunds (
    attempt_id, gateway_transaction_id, amount, status, refund_kind,
    merchant_ref_id, initiated_by, initiated_at, initiation_reason,
    requested_at, next_action_at
  ) values (
    v_attempt.id, v_attempt.gateway_transaction_id, v_attempt.amount,
    'queued', 'admin_full', 'TBWR' || replace(gen_random_uuid()::text, '-', ''),
    (select auth.uid()), now(), btrim(p_reason), now(), now()
  ) returning id into v_refund_id;

  update public.appointments a set refund_pending = true, updated_at = now()
  from public.booking_holds h
  where a.id = h.appointment_id
    and (h.public_token = v_attempt.hold_token
         or h.booking_group_token = v_attempt.hold_token);
  return v_refund_id;
end;
$function$;

revoke all on function public.request_admin_fiuu_full_refund(uuid, text)
  from public, anon, authenticated;
grant execute on function public.request_admin_fiuu_full_refund(uuid, text)
  to authenticated;

-- The provider's advanced-refund inquiry is separate from its signed direct
-- payment requery. Only the service-role worker may complete this claim.
create function public.complete_admin_fiuu_refund_inquiry(
  p_claim_token uuid, p_result text, p_gateway_refund_id text
) returns text
language plpgsql security definer set search_path = ''
as $function$
declare
  v_refund public.booking_payment_refunds%rowtype;
  v_attempt public.booking_payment_attempts%rowtype;
  v_hold public.booking_holds%rowtype;
  v_appointment public.appointments%rowtype;
  v_cancellation_error text;
begin
  select * into v_refund from public.booking_payment_refunds
  where claim_token = p_claim_token and status = 'checking'
    and refund_kind = 'admin_full' for update;
  if not found then raise exception 'Refund status claim is no longer current'; end if;
  if p_gateway_refund_id is distinct from v_refund.gateway_refund_id
     or p_result not in ('pending', 'processing', 'rejected', 'success') then
    raise exception 'Refund inquiry identity or result is invalid';
  end if;
  select * into v_attempt from public.booking_payment_attempts
  where id = v_refund.attempt_id for update;

  if p_result = 'success' then
    for v_hold in
      select h.* from public.booking_holds h
      where h.public_token = v_attempt.hold_token
         or h.booking_group_token = v_attempt.hold_token
      order by h.id for update
    loop
      select * into v_appointment from public.appointments a
      where a.id = v_hold.appointment_id for update;
      if not found or v_appointment.actual_started_at is not null
         or v_appointment.status::text in ('in_progress', 'completed') then
        v_cancellation_error := 'Refund succeeded but booking requires manual cancellation review';
      end if;
    end loop;

    -- Release the ledger guard in this same transaction only after the
    -- provider's matching success result has been accepted.
    update public.booking_payment_refunds set status = 'succeeded'
    where id = v_refund.id;

    update public.booking_payment_attempts
      set status = 'refunded', resolved_at = now(), updated_at = now()
      where id = v_attempt.id and status = 'confirmed';
    update public.transactions t
      set payment_status = 'refunded'
      where t.receipt_number = 'FIUU-' || upper(v_attempt.order_id)
        and t.payment_status::text = 'paid';
    update public.appointments a set payment_status = 'refunded',
        refund_pending = false, updated_at = now()
    from public.booking_holds h where a.id = h.appointment_id
      and (h.public_token = v_attempt.hold_token
           or h.booking_group_token = v_attempt.hold_token);
    if v_cancellation_error is null then
      update public.appointments a
        set status = 'cancelled', refund_pending = false,
            cancelled_at = now(), cancellation_reason = 'Full Fiuu refund',
            updated_at = now()
      from public.booking_holds h
      where a.id = h.appointment_id
        and (h.public_token = v_attempt.hold_token
             or h.booking_group_token = v_attempt.hold_token);
      update public.appointment_groups g set status = 'cancelled'
      where g.id in (
        select h.appointment_group_id from public.booking_holds h
        where h.public_token = v_attempt.hold_token
           or h.booking_group_token = v_attempt.hold_token
      );
      update public.booking_holds h set status = 'cancelled', updated_at = now()
      where h.public_token = v_attempt.hold_token
         or h.booking_group_token = v_attempt.hold_token;
    end if;
  elsif p_result = 'rejected' then
    update public.booking_payment_refunds set status = 'needs_review'
    where id = v_refund.id;
    update public.appointments a set refund_pending = false, updated_at = now()
    from public.booking_holds h where a.id = h.appointment_id
      and (h.public_token = v_attempt.hold_token
           or h.booking_group_token = v_attempt.hold_token);
  end if;

  update public.booking_payment_refunds
    set status = case when p_result = 'success' then 'succeeded'
                      when p_result = 'rejected' then 'needs_review'
                      else 'requested' end,
        gateway_status = p_result,
        cancellation_error = v_cancellation_error,
        last_error = case when p_result = 'rejected'
                          then 'Fiuu rejected the refund'
                          when v_cancellation_error is not null
                          then v_cancellation_error
                          else last_error end,
        completed_at = case when p_result = 'success' then now() else completed_at end,
        next_action_at = case when p_result in ('pending', 'processing')
                              then now() + interval '30 minutes'
                              else next_action_at end,
        claim_token = null, claim_expires_at = null, updated_at = now()
    where id = v_refund.id;
  return case when p_result = 'success' then 'succeeded'
              when p_result = 'rejected' then 'needs_review'
              else 'requested' end;
end;
$function$;

revoke all on function public.complete_admin_fiuu_refund_inquiry(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.complete_admin_fiuu_refund_inquiry(uuid, text, text)
  to service_role;
