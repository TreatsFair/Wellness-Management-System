-- Expose only the promotion metadata the trusted booking Edge Function needs.
-- Keep the promotion tables staff-only; this RPC is the narrow server-side
-- interface for the public booking pricing/error boundary.

create or replace function public.get_booking_promotion_metadata(
  p_promotion_id uuid default null,
  p_code text default null
)
returns table (
  usage_type text,
  maximum_discount numeric
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  -- The function is granted only to the trusted Edge Function role. Keep a
  -- claim check as defense in depth if execute privileges are ever changed.
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception using
      errcode = '42501',
      message = 'Promotion metadata access is restricted.';
  end if;

  if p_promotion_id is null
     and nullif(trim(coalesce(p_code, '')), '') is null then
    return;
  end if;

  return query
  select p.usage_type, p.maximum_discount
  from public.promotions p
  left join public.promotion_codes pc
    on pc.promotion_id = p.id
  where (p_promotion_id is not null and p.id = p_promotion_id)
     or (
       p_promotion_id is null
       and upper(trim(pc.code)) = upper(trim(p_code))
     )
  order by pc.created_at nulls last, pc.id nulls last
  limit 1;
end;
$function$;

revoke all on function public.get_booking_promotion_metadata(uuid, text)
  from public, anon, authenticated;
grant execute on function public.get_booking_promotion_metadata(uuid, text)
  to service_role;
