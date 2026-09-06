-- Keep the narrow promotion metadata RPC service-role-only at the function ACL.
-- The Edge Function uses Supabase's trusted secret-key path; that path does
-- not reliably populate request.jwt.claim.role, so an extra claim check would
-- reject the trusted caller even though its EXECUTE grant is correct.

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
