-- Allow an authenticated staff member to choose a corrected recipient for one
-- intentional Production resend. STAGING still redirects network delivery to
-- its configured test recipient in the Edge Function.

drop function if exists public.request_manual_booking_email(uuid);

create or replace function public.request_manual_booking_email(
  p_payment_attempt_id uuid,
  p_recipient_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.booking_payment_attempts%rowtype;
  v_email text;
  v_requested_email text;
  v_delivery_id uuid;
  v_idempotency_key uuid;
begin
  if (select auth.uid()) is null or not (select public.is_staff_or_admin()) then
    raise exception 'Staff access is required' using errcode = '42501';
  end if;

  select * into v_attempt
  from public.booking_payment_attempts a
  where a.id = p_payment_attempt_id
    and a.gateway = 'fiuu'
  for update;
  if not found then
    raise exception 'Payment attempt was not found' using errcode = 'P0002';
  end if;
  if v_attempt.status <> 'confirmed' then
    raise exception 'A confirmation email is available only for a confirmed booking'
      using errcode = '22023';
  end if;
  if not (select private.has_outlet_access(v_attempt.outlet_id)) then
    raise exception 'Staff access to this outlet is required' using errcode = '42501';
  end if;

  select h.customer_email into v_email
  from public.booking_holds h
  where h.public_token = v_attempt.hold_token
     or h.booking_group_token = v_attempt.hold_token
  order by h.guest_index nulls first, h.created_at
  limit 1;
  if not found then
    raise exception 'Confirmed booking details were not found' using errcode = 'P0002';
  end if;

  v_requested_email := nullif(btrim(coalesce(p_recipient_email, '')), '');
  if v_requested_email is not null and (
    length(v_requested_email) > 320
    or v_requested_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ) then
    raise exception 'Recipient email is invalid' using errcode = '22023';
  end if;
  v_email := coalesce(v_requested_email, nullif(btrim(coalesce(v_email, '')), ''));
  if v_email is null then
    raise exception 'Confirmed booking does not have a recipient email'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.booking_email_delivery_attempts d
    where d.payment_attempt_id = v_attempt.id
      and d.created_at >= now() - interval '60 seconds'
  ) then
    raise exception 'A confirmation email resend was just requested. Try again shortly.'
      using errcode = '55P03';
  end if;

  insert into public.booking_email_delivery_attempts (
    payment_attempt_id,
    hold_token,
    intended_recipient_email,
    initiated_by
  ) values (
    v_attempt.id,
    v_attempt.hold_token,
    left(v_email, 320),
    (select auth.uid())
  )
  returning id, idempotency_key into v_delivery_id, v_idempotency_key;

  update public.booking_email_outbox
  set manual_resend_count = manual_resend_count + 1,
      updated_at = now()
  where payment_attempt_id = v_attempt.id
    and email_type = 'BOOKING_CONFIRMATION';

  return jsonb_build_object(
    'delivery_id', v_delivery_id,
    'payment_attempt_id', v_attempt.id,
    'idempotency_key', v_idempotency_key
  );
end;
$$;

revoke all on function public.request_manual_booking_email(uuid, text)
  from public, anon;
grant execute on function public.request_manual_booking_email(uuid, text)
  to authenticated;
