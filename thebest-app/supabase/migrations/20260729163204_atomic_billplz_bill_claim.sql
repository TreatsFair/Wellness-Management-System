-- Attach the first Billplz bill through a narrow, race-safe RPC.
-- booking-api intentionally has no direct UPDATE grant on booking_holds.

begin;

create or replace function public.claim_billplz_bill_v2(
  p_token uuid,
  p_bill_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_bill_id text := nullif(trim(p_bill_id), '');
  v_is_group boolean;
  v_existing_bill_id text;
begin
  if v_bill_id is null or length(v_bill_id) > 200 then
    raise exception 'A valid Billplz bill id is required';
  end if;

  select exists (
    select 1
    from public.booking_holds
    where booking_group_token = p_token
  )
  into v_is_group;

  perform 1
  from public.booking_holds hold
  where (
    v_is_group
    and hold.booking_group_token = p_token
  ) or (
    not v_is_group
    and hold.public_token = p_token
  )
  order by hold.guest_index nulls first, hold.id
  for update;

  if not found then
    raise exception 'Booking reference not found';
  end if;

  if exists (
    select 1
    from public.booking_holds hold
    where (
      (
        v_is_group
        and hold.booking_group_token = p_token
      ) or (
        not v_is_group
        and hold.public_token = p_token
      )
    )
    and (
      hold.status <> 'pending_payment'
      or hold.expires_at <= now()
      or hold.appointment_id is not null
      or hold.appointment_group_id is not null
    )
  ) then
    raise exception 'This booking hold can no longer accept payment';
  end if;

  select hold.billplz_bill_id
  into v_existing_bill_id
  from public.booking_holds hold
  where (
    (
      v_is_group
      and hold.booking_group_token = p_token
    ) or (
      not v_is_group
      and hold.public_token = p_token
    )
  )
  and hold.billplz_bill_id is not null
  order by hold.guest_index nulls first, hold.id
  limit 1;

  if v_existing_bill_id is not null then
    return v_existing_bill_id;
  end if;

  if v_is_group then
    update public.booking_holds
    set billplz_bill_id = case
          when guest_index = 1 then v_bill_id
          else null
        end,
        updated_at = now()
    where booking_group_token = p_token;
  else
    update public.booking_holds
    set billplz_bill_id = v_bill_id,
        updated_at = now()
    where public_token = p_token;
  end if;

  return v_bill_id;
end;
$function$;

revoke all on function public.claim_billplz_bill_v2(uuid, text)
  from public, anon, authenticated;
grant execute on function public.claim_billplz_bill_v2(uuid, text)
  to service_role;

commit;
