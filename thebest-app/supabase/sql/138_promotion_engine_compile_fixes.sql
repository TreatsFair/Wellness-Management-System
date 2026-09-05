-- 138_promotion_engine_compile_fixes.sql
-- Qualify relation columns that share names with reservation return fields.
create or replace function public.reserve_public_booking_promotion(
  p_token uuid,
  p_code text,
  p_customer_id uuid default null
)
returns table (
  success boolean,
  error_code text,
  error_message text,
  promotion_id uuid,
  promotion_code_id uuid,
  promotion_code text,
  promotion_name text,
  benefit_type text,
  benefit_value numeric,
  free_addon_service_id uuid,
  free_addon_service_name text,
  subtotal_amount numeric,
  discount_amount numeric,
  final_amount numeric
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_code_row public.promotion_codes%rowtype;
  v_promo public.promotions%rowtype;
  v_first public.booking_holds%rowtype;
  v_existing public.promotion_redemptions%rowtype;
  v_hold public.booking_holds%rowtype;
  v_addon public.services%rowtype;
  v_addon_name text;
  v_is_group boolean;
  v_hold_count integer := 0;
  v_counter integer := 0;
  v_uses bigint := 0;
  v_customer_uses bigint := 0;
  v_customer_id uuid;
  v_email text;
  v_code text := upper(trim(coalesce(p_code, '')));
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_discount_remaining numeric := 0;
  v_line_subtotal numeric := 0;
  v_line_discount numeric := 0;
  v_final numeric := 0;
  v_addon_price numeric := 0;
  v_service_ids uuid[] := '{}'::uuid[];
  v_snapshot jsonb;
begin
  perform public.expire_stale_booking_holds();

  if v_code = '' then
    success := false; error_code := 'PROMOTION_CODE_REQUIRED';
    error_message := 'Enter a promotion code first.';
    return next; return;
  end if;

  v_is_group := exists (
    select 1 from public.booking_holds where booking_group_token = p_token
  );
  if v_is_group then
    for v_hold in
      select * from public.booking_holds
      where booking_group_token = p_token
      order by guest_index nulls first, id
      for update
    loop
      if v_first.id is null then v_first := v_hold; end if;
      v_hold_count := v_hold_count + 1;
    end loop;
  else
    select * into v_first
    from public.booking_holds
    where public_token = p_token
    for update;
    if v_first.id is not null then v_hold_count := 1; end if;
  end if;
  if v_first.id is null then
    success := false; error_code := 'HOLD_NOT_FOUND';
    error_message := 'Booking reference not found.';
    return next; return;
  end if;
  if exists (
    select 1 from public.booking_holds h
    where (
      (v_is_group and h.booking_group_token = p_token)
      or (not v_is_group and h.id = v_first.id)
    )
    and (h.status <> 'pending_payment' or h.expires_at <= now())
  ) then
    update public.booking_holds h
    set status = 'expired', updated_at = now()
    where h.status = 'pending_payment'
      and h.expires_at <= now()
      and ((v_is_group and h.booking_group_token = p_token)
        or (not v_is_group and h.id = v_first.id));
    success := false; error_code := 'HOLD_EXPIRED';
    error_message := 'This booking hold has expired. Please start again.';
    return next; return;
  end if;
  if exists (
    select 1 from public.booking_holds h
    where ((v_is_group and h.booking_group_token = p_token)
        or (not v_is_group and h.id = v_first.id))
      and h.status <> 'pending_payment'
  ) then
    success := false; error_code := 'HOLD_NOT_ACTIVE';
    error_message := 'This booking hold can no longer accept a promotion.';
    return next; return;
  end if;

  select * into v_code_row
  from public.promotion_codes
  where upper(trim(code)) = v_code
  limit 1;
  if not found then
    success := false; error_code := 'PROMOTION_NOT_FOUND';
    error_message := 'We could not find that promotion code.';
    return next; return;
  end if;
  select * into v_promo
  from public.promotions
  where id = v_code_row.promotion_id
  for update;
  select * into v_code_row
  from public.promotion_codes
  where id = v_code_row.id
  for update;

  select * into v_existing
  from public.promotion_redemptions r
  where (
    (v_is_group and r.booking_group_token = p_token)
    or (not v_is_group and r.booking_hold_id = v_first.id)
  )
    and r.status in ('reserved', 'redeemed')
  order by r.reserved_at desc, r.id desc
  limit 1
  for update;
  if v_existing.id is not null and v_existing.status = 'redeemed' then
    success := false; error_code := 'PROMOTION_ALREADY_REDEEMED';
    error_message := 'This booking promotion has already been redeemed.';
    return next; return;
  end if;
  -- Retrying the same request is idempotent, even if a campaign was disabled
  -- after the reservation. The stored snapshot is the price authority.
  if v_existing.id is not null
     and upper(trim(v_existing.promotion_code)) = v_code then
    success := true; error_code := null; error_message := null;
    promotion_id := v_existing.promotion_id;
    promotion_code_id := v_existing.promotion_code_id;
    promotion_code := v_existing.promotion_code;
    promotion_name := v_promo.name;
    benefit_type := v_promo.benefit_type;
    benefit_value := v_promo.benefit_value;
    free_addon_service_id := v_promo.free_addon_service_id;
    select name into free_addon_service_name from public.services where id = v_promo.free_addon_service_id;
    subtotal_amount := v_existing.subtotal_amount;
    discount_amount := v_existing.discount_amount;
    final_amount := v_existing.final_amount;
    return next; return;
  end if;

  if not v_code_row.active then
    success := false; error_code := 'PROMOTION_INACTIVE';
    error_message := 'This promotion code is inactive.';
    return next; return;
  end if;
  if not v_promo.active then
    success := false; error_code := 'PROMOTION_INACTIVE';
    error_message := 'This promotion is not active right now.';
    return next; return;
  end if;
  if v_promo.starts_at > now() or (v_promo.ends_at is not null and v_promo.ends_at <= now()) then
    success := false; error_code := 'PROMOTION_EXPIRED';
    error_message := 'This promotion is outside its valid dates.';
    return next; return;
  end if;
  if not v_promo.online_booking_only then
    success := false; error_code := 'PROMOTION_NOT_ONLINE';
    error_message := 'This promotion is not available for online bookings.';
    return next; return;
  end if;
  if exists (select 1 from public.promotion_outlets po where po.promotion_id = v_promo.id)
     and not exists (
       select 1 from public.promotion_outlets po
       where po.promotion_id = v_promo.id and po.outlet_id = v_first.outlet_id
     ) then
    success := false; error_code := 'PROMOTION_OUTLET';
    error_message := 'This code is not valid for the selected outlet.';
    return next; return;
  end if;

  select coalesce(array_agg(distinct c.service_id), '{}'::uuid[])
  into v_service_ids
  from public.booking_holds h
  join public.online_booking_services c on c.id = h.online_booking_service_id
  where (v_is_group and h.booking_group_token = p_token)
     or (not v_is_group and h.id = v_first.id);
  if exists (select 1 from public.promotion_services ps where ps.promotion_id = v_promo.id)
     and exists (
       select 1 from unnest(v_service_ids) selected(service_id)
       where not exists (
         select 1 from public.promotion_services ps
         where ps.promotion_id = v_promo.id and ps.service_id = selected.service_id
       )
     ) then
    success := false; error_code := 'PROMOTION_SERVICE';
    error_message := 'This code is not valid for the selected service.';
    return next; return;
  end if;

  select round(sum(coalesce(h.subtotal_amount, h.total_amount, 0)), 2)
  into v_subtotal
  from public.booking_holds h
  where (v_is_group and h.booking_group_token = p_token)
     or (not v_is_group and h.id = v_first.id);
  v_subtotal := coalesce(v_subtotal, 0);
  v_email := lower(trim(coalesce(v_first.customer_email, '')));
  v_customer_id := coalesce(v_first.customer_id, p_customer_id);
  if v_subtotal < v_promo.minimum_spend then
    success := false; error_code := 'PROMOTION_MINIMUM_SPEND';
    error_message := 'Spend at least RM ' || to_char(v_promo.minimum_spend, 'FM999999990.00') || ' to use this code.';
    return next; return;
  end if;

  select count(*) into v_uses
  from public.promotion_redemptions r
  where r.promotion_id = v_promo.id
    and r.status in ('reserved', 'redeemed')
    and (v_existing.id is null or r.id <> v_existing.id);
  if v_promo.max_redemptions is not null and v_uses >= v_promo.max_redemptions then
    success := false; error_code := 'PROMOTION_FULLY_REDEEMED';
    error_message := 'This promotion has been fully redeemed.';
    return next; return;
  end if;
  if v_promo.per_customer_limit is not null then
    select count(*) into v_customer_uses
    from public.promotion_redemptions r
    where r.promotion_id = v_promo.id
      and r.status in ('reserved', 'redeemed')
      and (v_existing.id is null or r.id <> v_existing.id)
      and case
        when v_customer_id is not null then r.customer_id = v_customer_id
        else lower(trim(r.customer_email)) = v_email and v_email <> ''
      end;
    if v_customer_uses >= v_promo.per_customer_limit then
      success := false; error_code := 'PROMOTION_CUSTOMER_LIMIT';
      error_message := 'This promotion has reached its limit for this customer.';
      return next; return;
    end if;
  end if;

  if v_promo.benefit_type = 'percentage_discount' then
    v_discount := round(v_subtotal * v_promo.benefit_value / 100, 2);
    if v_promo.maximum_discount is not null then
      v_discount := least(v_discount, v_promo.maximum_discount);
    end if;
  elsif v_promo.benefit_type = 'fixed_discount' then
    v_discount := v_promo.benefit_value;
  else
    select * into v_addon from public.services where id = v_promo.free_addon_service_id;
    if not found then
      success := false; error_code := 'PROMOTION_ADDON_NOT_FOUND';
      error_message := 'The free add-on service is no longer available.';
      return next; return;
    end if;
    v_addon_name := v_addon.name;
    -- Hot Stone and other duration/room services must be added as scheduled
    -- segments. Only an explicitly marked zero-resource service is safe to
    -- price as a free add-on in this booking flow.
    if v_promo.free_addon_scheduling_mode <> 'no_resource'
       or coalesce(v_addon.duration, 0) <> 0
       or lower(coalesce(v_addon.room_type::text, '')) not in ('', 'none') then
      success := false; error_code := 'PROMOTION_ADDON_REQUIRES_SCHEDULED_ADDON';
      error_message := 'This free add-on needs a separate scheduled slot and cannot be added to this online booking yet.';
      return next; return;
    end if;
    select coalesce(obs.display_price, v_addon.price, 0)
    into v_addon_price
    from (select 1) anchor
    left join public.online_booking_services obs
      on obs.service_id = v_addon.id
     and obs.outlet_id = v_first.outlet_id
     and obs.enabled;
    v_discount := coalesce(v_addon_price, 0);
  end if;
  v_discount := least(greatest(round(coalesce(v_discount, 0), 2), 0), v_subtotal);
  v_final := round(v_subtotal - v_discount, 2);
  v_snapshot := jsonb_build_object(
    'subtotal_amount', v_subtotal,
    'discount_amount', v_discount,
    'final_amount', v_final,
    'promotion_id', v_promo.id,
    'promotion_code_id', v_code_row.id,
    'promotion_code', v_code_row.code,
    'promotion_name', v_promo.name,
    'benefit_type', v_promo.benefit_type,
    'benefit_value', v_promo.benefit_value,
    'free_addon_service_id', v_promo.free_addon_service_id,
    'free_addon_service_name', v_addon_name,
    'calculated_at', now()
  );

  if v_existing.id is not null then
    update public.promotion_redemptions
    set status = 'released', released_at = coalesce(released_at, now())
    where id = v_existing.id and status = 'reserved';
  end if;
  insert into public.promotion_redemptions (
    promotion_id, promotion_code_id, promotion_code, booking_hold_id,
    booking_group_token, customer_id, customer_email, status,
    subtotal_amount, discount_amount, final_amount, pricing_snapshot
  ) values (
    v_promo.id, v_code_row.id, v_code_row.code,
    case when v_is_group then null else v_first.id end,
    case when v_is_group then p_token else null end,
    v_customer_id, v_email, 'reserved',
    v_subtotal, v_discount, v_final, v_snapshot
  );

  v_discount_remaining := v_discount;
  for v_hold in
    select * from public.booking_holds h
    where (v_is_group and h.booking_group_token = p_token)
       or (not v_is_group and h.id = v_first.id)
    order by h.guest_index nulls first, h.id
    for update
  loop
    v_counter := v_counter + 1;
    v_line_subtotal := round(coalesce(v_hold.subtotal_amount, v_hold.total_amount, 0), 2);
    if v_counter < v_hold_count and v_subtotal > 0 then
      v_line_discount := least(
        v_line_subtotal,
        round(v_discount * v_line_subtotal / v_subtotal, 2)
      );
    else
      v_line_discount := least(v_line_subtotal, v_discount_remaining);
    end if;
    v_line_discount := greatest(round(v_line_discount, 2), 0);
    v_discount_remaining := greatest(round(v_discount_remaining - v_line_discount, 2), 0);
    update public.booking_holds
    set subtotal_amount = v_line_subtotal,
        discount_amount = v_line_discount,
        total_amount = round(v_line_subtotal - v_line_discount, 2),
        promotion_id = v_promo.id,
        promotion_code_id = v_code_row.id,
        promotion_code = v_code_row.code,
        pricing_snapshot = v_snapshot || jsonb_build_object(
          'line_subtotal_amount', v_line_subtotal,
          'line_discount_amount', v_line_discount,
          'line_final_amount', round(v_line_subtotal - v_line_discount, 2)
        ),
        updated_at = now()
    where id = v_hold.id;
  end loop;

  success := true; error_code := null; error_message := null;
  promotion_id := v_promo.id;
  promotion_code_id := v_code_row.id;
  promotion_code := v_code_row.code;
  promotion_name := v_promo.name;
  benefit_type := v_promo.benefit_type;
  benefit_value := v_promo.benefit_value;
  free_addon_service_id := v_promo.free_addon_service_id;
  free_addon_service_name := v_addon_name;
  subtotal_amount := v_subtotal;
  discount_amount := v_discount;
  final_amount := v_final;
  return next;
end;
$function$;


grant execute on function public.reserve_public_booking_promotion(uuid,text,uuid) to service_role;

