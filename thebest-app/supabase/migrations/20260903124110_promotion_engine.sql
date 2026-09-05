-- 137_promotion_engine.sql
-- Generic online promotions with server-side pricing and hold reservations.
--
-- The public booking flow has one booking_holds row per guest. A group
-- promotion is therefore represented by one redemption row keyed by
-- booking_group_token, while a one-guest booking uses booking_hold_id. This
-- prevents a six-guest booking from consuming six campaign redemptions.

create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  description text not null default '',
  benefit_type text not null check (
    benefit_type in ('percentage_discount', 'fixed_discount', 'free_addon')
  ),
  benefit_value numeric(12,2) not null default 0 check (benefit_value >= 0),
  usage_type text not null default 'single_use' check (
    usage_type in ('single_use', 'multi_use')
  ),
  active boolean not null default false,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  max_redemptions integer,
  per_customer_limit integer,
  minimum_spend numeric(12,2) not null default 0 check (minimum_spend >= 0),
  maximum_discount numeric(12,2) check (maximum_discount is null or maximum_discount >= 0),
  online_booking_only boolean not null default true,
  free_addon_service_id uuid references public.services(id) on delete restrict,
  -- no_resource is deliberately explicit. A service with duration or room
  -- capacity must be scheduled as an appointment segment, not silently added
  -- to a public booking.
  free_addon_scheduling_mode text not null default 'unsupported' check (
    free_addon_scheduling_mode in ('unsupported', 'scheduled', 'no_resource')
  ),
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at),
  check (max_redemptions is null or max_redemptions > 0),
  check (per_customer_limit is null or per_customer_limit > 0),
  check (usage_type = 'multi_use' or max_redemptions = 1),
  check (benefit_type <> 'free_addon' or free_addon_service_id is not null)
);

create table if not exists public.promotion_codes (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references public.promotions(id) on delete cascade,
  code text not null check (length(trim(code)) between 3 and 64),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.promotion_outlets (
  promotion_id uuid not null references public.promotions(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  primary key (promotion_id, outlet_id)
);

create table if not exists public.promotion_services (
  promotion_id uuid not null references public.promotions(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (promotion_id, service_id)
);

create table if not exists public.promotion_redemptions (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references public.promotions(id) on delete restrict,
  promotion_code_id uuid not null references public.promotion_codes(id) on delete restrict,
  promotion_code text not null,
  booking_hold_id uuid references public.booking_holds(id) on delete restrict,
  booking_group_token uuid,
  customer_id uuid references public.customers(id) on delete set null,
  customer_email text not null default '',
  status text not null default 'reserved' check (
    status in ('reserved', 'redeemed', 'released')
  ),
  subtotal_amount numeric(12,2) not null check (subtotal_amount >= 0),
  discount_amount numeric(12,2) not null check (discount_amount >= 0),
  final_amount numeric(12,2) not null check (final_amount >= 0),
  pricing_snapshot jsonb not null default '{}'::jsonb,
  reserved_at timestamptz not null default now(),
  redeemed_at timestamptz,
  released_at timestamptz,
  check ((booking_hold_id is not null) <> (booking_group_token is not null)),
  check (discount_amount <= subtotal_amount),
  check (status <> 'redeemed' or redeemed_at is not null),
  check (status <> 'released' or released_at is not null)
);

create unique index if not exists promotion_codes_normalized_uidx
  on public.promotion_codes (upper(trim(code)));
create index if not exists promotion_codes_promotion_idx
  on public.promotion_codes (promotion_id, active);
create index if not exists promotion_outlets_outlet_idx
  on public.promotion_outlets (outlet_id, promotion_id);
create index if not exists promotion_services_service_idx
  on public.promotion_services (service_id, promotion_id);
create index if not exists promotion_redemptions_promotion_status_idx
  on public.promotion_redemptions (promotion_id, status);
create index if not exists promotion_redemptions_code_status_idx
  on public.promotion_redemptions (promotion_code_id, status);
create index if not exists promotion_redemptions_hold_idx
  on public.promotion_redemptions (booking_hold_id, status)
  where booking_hold_id is not null;
create index if not exists promotion_redemptions_group_idx
  on public.promotion_redemptions (booking_group_token, status)
  where booking_group_token is not null;
create unique index if not exists promotion_redemptions_active_hold_uidx
  on public.promotion_redemptions (booking_hold_id)
  where booking_hold_id is not null and status in ('reserved', 'redeemed');
create unique index if not exists promotion_redemptions_active_group_uidx
  on public.promotion_redemptions (booking_group_token)
  where booking_group_token is not null and status in ('reserved', 'redeemed');

alter table public.booking_holds
  add column if not exists subtotal_amount numeric(12,2),
  add column if not exists discount_amount numeric(12,2) not null default 0,
  add column if not exists promotion_id uuid references public.promotions(id) on delete set null,
  add column if not exists promotion_code_id uuid references public.promotion_codes(id) on delete set null,
  add column if not exists promotion_code text,
  add column if not exists pricing_snapshot jsonb;

-- Existing holds are base-price holds. Keep their financial history explicit so
-- applying/removing a promotion never has to infer the original amount from a
-- mutable total_amount value.
update public.booking_holds
set subtotal_amount = coalesce(subtotal_amount, round(total_amount, 2)),
    discount_amount = coalesce(discount_amount, 0),
    pricing_snapshot = coalesce(
      pricing_snapshot,
      jsonb_build_object(
        'subtotal_amount', round(total_amount, 2),
        'discount_amount', 0,
        'final_amount', round(total_amount, 2),
        'promotion_id', null,
        'promotion_code', null,
        'calculated_at', coalesce(updated_at, now())
      )
    )
where subtotal_amount is null or pricing_snapshot is null;

create or replace function public.set_booking_hold_base_pricing()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if new.subtotal_amount is null then
    new.subtotal_amount := round(coalesce(new.total_amount, 0), 2);
  end if;
  if new.discount_amount is null then
    new.discount_amount := 0;
  end if;
  if new.pricing_snapshot is null then
    new.pricing_snapshot := jsonb_build_object(
      'subtotal_amount', round(coalesce(new.subtotal_amount, new.total_amount, 0), 2),
      'discount_amount', round(coalesce(new.discount_amount, 0), 2),
      'final_amount', round(coalesce(new.total_amount, 0), 2),
      'promotion_id', new.promotion_id,
      'promotion_code', new.promotion_code,
      'calculated_at', now()
    );
  end if;
  return new;
end;
$function$;

drop trigger if exists booking_holds_base_pricing on public.booking_holds;
create trigger booking_holds_base_pricing
before insert or update of total_amount, subtotal_amount, discount_amount,
  promotion_id, promotion_code_id, promotion_code, pricing_snapshot
on public.booking_holds
for each row execute function public.set_booking_hold_base_pricing();

-- A hold status is the existing expiry/cancellation authority. This trigger
-- attaches voucher release/redeem to that authority so scheduled expiry,
-- customer cancellation, failed payment and paid conversion all remain atomic
-- with the booking-hold state change.
create or replace function public.apply_booking_promotion_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if old.status = 'pending_payment'
     and new.status in ('expired', 'cancelled', 'payment_failed') then
    update public.promotion_redemptions
    set status = 'released',
        released_at = coalesce(released_at, now())
    where status = 'reserved'
      and (
        (new.booking_group_token is not null
          and booking_group_token = new.booking_group_token)
        or (new.booking_group_token is null
          and booking_hold_id = new.id)
      );
  elsif old.status <> 'confirmed' and new.status = 'confirmed' then
    update public.promotion_redemptions
    set status = 'redeemed',
        redeemed_at = coalesce(redeemed_at, now()),
        customer_id = coalesce(customer_id, new.customer_id)
    where status = 'reserved'
      and (
        (new.booking_group_token is not null
          and booking_group_token = new.booking_group_token)
        or (new.booking_group_token is null
          and booking_hold_id = new.id)
      );
  end if;
  return new;
end;
$function$;

drop trigger if exists booking_holds_promotion_lifecycle on public.booking_holds;
create trigger booking_holds_promotion_lifecycle
after update of status on public.booking_holds
for each row execute function public.apply_booking_promotion_lifecycle();

create or replace function public.list_staff_promotions(p_outlet_id uuid default null)
returns setof jsonb
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.is_staff_or_admin() then
    raise exception using errcode = '42501', message = 'Promotion access is restricted to staff.';
  end if;

  return query
  select jsonb_build_object(
    'promotion_id', p.id,
    'name', p.name,
    'description', p.description,
    'benefit_type', p.benefit_type,
    'benefit_value', p.benefit_value,
    'usage_type', p.usage_type,
    'active', p.active,
    'starts_at', p.starts_at,
    'ends_at', p.ends_at,
    'max_redemptions', p.max_redemptions,
    'per_customer_limit', p.per_customer_limit,
    'minimum_spend', p.minimum_spend,
    'maximum_discount', p.maximum_discount,
    'online_booking_only', p.online_booking_only,
    'free_addon_service_id', p.free_addon_service_id,
    'free_addon_service_name', addon.name,
    'free_addon_scheduling_mode', p.free_addon_scheduling_mode,
    'outlet_ids', coalesce((
      select jsonb_agg(po.outlet_id order by po.outlet_id)
      from public.promotion_outlets po
      where po.promotion_id = p.id
    ), '[]'::jsonb),
    'service_ids', coalesce((
      select jsonb_agg(ps.service_id order by ps.service_id)
      from public.promotion_services ps
      where ps.promotion_id = p.id
    ), '[]'::jsonb),
    'codes', coalesce((
      select jsonb_agg(
        jsonb_build_object('id', pc.id, 'code', pc.code, 'active', pc.active)
        order by pc.created_at, pc.id
      )
      from public.promotion_codes pc
      where pc.promotion_id = p.id
    ), '[]'::jsonb),
    'code_count', (select count(*) from public.promotion_codes pc where pc.promotion_id = p.id),
    'reserved_count', (
      select count(*) from public.promotion_redemptions pr
      where pr.promotion_id = p.id and pr.status = 'reserved'
    ),
    'redeemed_count', (
      select count(*) from public.promotion_redemptions pr
      where pr.promotion_id = p.id and pr.status = 'redeemed'
    ),
    'released_count', (
      select count(*) from public.promotion_redemptions pr
      where pr.promotion_id = p.id and pr.status = 'released'
    )
  )
  from public.promotions p
  left join public.services addon on addon.id = p.free_addon_service_id
  where p_outlet_id is null
     or not exists (
       select 1 from public.promotion_outlets po
       where po.promotion_id = p.id
     )
     or exists (
       select 1 from public.promotion_outlets po
       where po.promotion_id = p.id and po.outlet_id = p_outlet_id
     )
  order by p.active desc, p.starts_at desc, p.created_at desc;
end;
$function$;

create or replace function public.generate_staff_promotion_code(p_promotion_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_code text;
  v_attempt integer;
begin
  if not public.is_staff_or_admin() then
    raise exception using errcode = '42501', message = 'Promotion changes are restricted to staff.';
  end if;
  if not exists (select 1 from public.promotions where id = p_promotion_id) then
    raise exception using errcode = 'P0001', message = 'Promotion was not found.', detail = 'PROMOTION_NOT_FOUND';
  end if;

  for v_attempt in 1..12 loop
    v_code := 'TB' || upper(left(replace(gen_random_uuid()::text, '-', ''), 10));
    begin
      insert into public.promotion_codes (promotion_id, code)
      values (p_promotion_id, v_code);
      return v_code;
    exception when unique_violation then
      -- The unique index is the final authority. Retry with a new random code.
    end;
  end loop;

  raise exception using errcode = 'P0001', message = 'Unable to generate a unique promotion code.', detail = 'PROMOTION_CODE_GENERATION_FAILED';
end;
$function$;

create or replace function public.upsert_staff_promotion(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_id uuid;
  v_name text := nullif(trim(v_payload ->> 'name'), '');
  v_description text := left(coalesce(v_payload ->> 'description', ''), 1000);
  v_benefit_type text := lower(trim(coalesce(v_payload ->> 'benefit_type', '')));
  v_benefit_value numeric := coalesce(nullif(v_payload ->> 'benefit_value', ''), '0')::numeric;
  v_usage_type text := lower(trim(coalesce(v_payload ->> 'usage_type', 'single_use')));
  v_active boolean := lower(coalesce(v_payload ->> 'active', 'false')) in ('true', '1', 'yes');
  v_starts_at timestamptz := coalesce(nullif(v_payload ->> 'starts_at', '')::timestamptz, now());
  v_ends_at timestamptz := nullif(v_payload ->> 'ends_at', '')::timestamptz;
  v_max_redemptions integer;
  v_per_customer_limit integer;
  v_minimum_spend numeric := coalesce(nullif(v_payload ->> 'minimum_spend', ''), '0')::numeric;
  v_maximum_discount numeric := nullif(v_payload ->> 'maximum_discount', '')::numeric;
  v_online_only boolean := lower(coalesce(v_payload ->> 'online_booking_only', 'true')) in ('true', '1', 'yes');
  v_free_addon_service_id uuid := nullif(v_payload ->> 'free_addon_service_id', '')::uuid;
  v_free_addon_mode text := lower(trim(coalesce(v_payload ->> 'free_addon_scheduling_mode', 'unsupported')));
  v_outlet_ids uuid[];
  v_service_ids uuid[];
  v_manual_code text := nullif(upper(trim(v_payload ->> 'code')), '');
  v_generate_code boolean := lower(coalesce(v_payload ->> 'generate_one_time_code', 'false')) in ('true', '1', 'yes');
  v_generated_code text;
  v_existing_code_id uuid;
begin
  if not public.is_staff_or_admin() then
    raise exception using errcode = '42501', message = 'Promotion changes are restricted to staff.';
  end if;
  if v_name is null then
    raise exception using errcode = 'P0001', message = 'Promotion name is required.', detail = 'PROMOTION_NAME_REQUIRED';
  end if;
  if v_benefit_type not in ('percentage_discount', 'fixed_discount', 'free_addon') then
    raise exception using errcode = 'P0001', message = 'Choose a supported promotion benefit.', detail = 'PROMOTION_BENEFIT_INVALID';
  end if;
  if v_usage_type not in ('single_use', 'multi_use') then
    raise exception using errcode = 'P0001', message = 'Choose single-use or multi-use.', detail = 'PROMOTION_USAGE_INVALID';
  end if;
  if v_benefit_value < 0 or v_minimum_spend < 0
     or (v_maximum_discount is not null and v_maximum_discount < 0) then
    raise exception using errcode = 'P0001', message = 'Promotion amounts cannot be negative.', detail = 'PROMOTION_AMOUNT_INVALID';
  end if;
  if v_benefit_type = 'percentage_discount' and v_benefit_value > 100 then
    raise exception using errcode = 'P0001', message = 'Percentage discount must be between 0 and 100.', detail = 'PROMOTION_PERCENT_INVALID';
  end if;
  v_max_redemptions := nullif(v_payload ->> 'max_redemptions', '')::integer;
  if v_usage_type = 'single_use' then
    v_max_redemptions := 1;
  elsif v_max_redemptions is not null and v_max_redemptions < 1 then
    raise exception using errcode = 'P0001', message = 'Total redemptions must be at least 1.', detail = 'PROMOTION_LIMIT_INVALID';
  end if;
  v_per_customer_limit := nullif(v_payload ->> 'per_customer_limit', '')::integer;
  if v_per_customer_limit is not null and v_per_customer_limit < 1 then
    raise exception using errcode = 'P0001', message = 'Per-customer limit must be at least 1.', detail = 'PROMOTION_CUSTOMER_LIMIT_INVALID';
  end if;
  if v_ends_at is not null and v_ends_at <= v_starts_at then
    raise exception using errcode = 'P0001', message = 'Promotion end must be after its start.', detail = 'PROMOTION_DATES_INVALID';
  end if;
  if v_benefit_type = 'free_addon' and v_free_addon_service_id is null then
    raise exception using errcode = 'P0001', message = 'Choose the free add-on service.', detail = 'PROMOTION_ADDON_REQUIRED';
  end if;
  if v_free_addon_mode not in ('unsupported', 'scheduled', 'no_resource') then
    raise exception using errcode = 'P0001', message = 'Choose a valid add-on scheduling mode.', detail = 'PROMOTION_ADDON_MODE_INVALID';
  end if;

  select coalesce(array_agg(value::uuid order by value), '{}'::uuid[])
  into v_outlet_ids
  from jsonb_array_elements_text(
    case when jsonb_typeof(v_payload -> 'outlet_ids') = 'array'
      then v_payload -> 'outlet_ids' else '[]'::jsonb end
  ) as item(value);
  select coalesce(array_agg(value::uuid order by value), '{}'::uuid[])
  into v_service_ids
  from jsonb_array_elements_text(
    case when jsonb_typeof(v_payload -> 'service_ids') = 'array'
      then v_payload -> 'service_ids' else '[]'::jsonb end
  ) as item(value);

  if cardinality(v_outlet_ids) > 0
     and (select count(*) from public.outlets where id = any(v_outlet_ids) and is_active)
         <> cardinality(v_outlet_ids) then
    raise exception using errcode = 'P0001', message = 'One or more selected outlets are unavailable.', detail = 'PROMOTION_OUTLET_INVALID';
  end if;
  if cardinality(v_service_ids) > 0
     and (select count(*) from public.services where id = any(v_service_ids))
         <> cardinality(v_service_ids) then
    raise exception using errcode = 'P0001', message = 'One or more selected services were not found.', detail = 'PROMOTION_SERVICE_INVALID';
  end if;
  if v_free_addon_service_id is not null
     and not exists (select 1 from public.services where id = v_free_addon_service_id) then
    raise exception using errcode = 'P0001', message = 'The free add-on service was not found.', detail = 'PROMOTION_ADDON_NOT_FOUND';
  end if;

  if nullif(v_payload ->> 'id', '') is not null then
    v_id := (v_payload ->> 'id')::uuid;
    update public.promotions
    set name = v_name,
        description = v_description,
        benefit_type = v_benefit_type,
        benefit_value = round(v_benefit_value, 2),
        usage_type = v_usage_type,
        active = v_active,
        starts_at = v_starts_at,
        ends_at = v_ends_at,
        max_redemptions = v_max_redemptions,
        per_customer_limit = v_per_customer_limit,
        minimum_spend = round(v_minimum_spend, 2),
        maximum_discount = case when v_maximum_discount is null then null else round(v_maximum_discount, 2) end,
        online_booking_only = v_online_only,
        free_addon_service_id = v_free_addon_service_id,
        free_addon_scheduling_mode = v_free_addon_mode,
        updated_by = auth.uid(),
        updated_at = now()
    where id = v_id;
    if not found then
      raise exception using errcode = 'P0001', message = 'Promotion was not found.', detail = 'PROMOTION_NOT_FOUND';
    end if;
  else
    insert into public.promotions (
      name, description, benefit_type, benefit_value, usage_type, active,
      starts_at, ends_at, max_redemptions, per_customer_limit, minimum_spend,
      maximum_discount, online_booking_only, free_addon_service_id,
      free_addon_scheduling_mode, created_by, updated_by
    ) values (
      v_name, v_description, v_benefit_type, round(v_benefit_value, 2), v_usage_type, v_active,
      v_starts_at, v_ends_at, v_max_redemptions, v_per_customer_limit, round(v_minimum_spend, 2),
      case when v_maximum_discount is null then null else round(v_maximum_discount, 2) end,
      v_online_only, v_free_addon_service_id, v_free_addon_mode, auth.uid(), auth.uid()
    ) returning id into v_id;
  end if;

  delete from public.promotion_outlets where promotion_id = v_id;
  insert into public.promotion_outlets (promotion_id, outlet_id)
  select v_id, unnest(v_outlet_ids);
  delete from public.promotion_services where promotion_id = v_id;
  insert into public.promotion_services (promotion_id, service_id)
  select v_id, unnest(v_service_ids);

  if v_manual_code is not null then
    if v_manual_code !~ '^[A-Z0-9][A-Z0-9_-]{2,63}$' then
      raise exception using errcode = 'P0001', message = 'Use 3–64 letters, numbers, hyphens or underscores for the code.', detail = 'PROMOTION_CODE_INVALID';
    end if;
    if exists (
      select 1 from public.promotion_codes
      where upper(trim(code)) = v_manual_code and promotion_id <> v_id
    ) then
      raise exception using errcode = 'P0001', message = 'That promotion code is already in use.', detail = 'PROMOTION_CODE_TAKEN';
    end if;
    select id into v_existing_code_id
    from public.promotion_codes
    where promotion_id = v_id and upper(trim(code)) = v_manual_code
    limit 1 for update;
    if v_existing_code_id is null then
      insert into public.promotion_codes (promotion_id, code)
      values (v_id, v_manual_code);
    else
      update public.promotion_codes set active = true, updated_at = now()
      where id = v_existing_code_id;
    end if;
  end if;

  if v_generate_code then
    v_generated_code := public.generate_staff_promotion_code(v_id);
  end if;

  return jsonb_build_object(
    'promotion_id', v_id,
    'generated_code', v_generated_code,
    'code', coalesce(v_generated_code, v_manual_code)
  );
end;
$function$;

create or replace function public.set_staff_promotion_active(
  p_promotion_id uuid,
  p_active boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not public.is_staff_or_admin() then
    raise exception using errcode = '42501', message = 'Promotion changes are restricted to staff.';
  end if;
  update public.promotions
  set active = coalesce(p_active, false), updated_by = auth.uid(), updated_at = now()
  where id = p_promotion_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'Promotion was not found.', detail = 'PROMOTION_NOT_FOUND';
  end if;
  return true;
end;
$function$;

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
  if exists (select 1 from public.promotion_outlets where promotion_id = v_promo.id)
     and not exists (
       select 1 from public.promotion_outlets
       where promotion_id = v_promo.id and outlet_id = v_first.outlet_id
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
  if exists (select 1 from public.promotion_services where promotion_id = v_promo.id)
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

create or replace function public.remove_public_booking_promotion(p_token uuid)
returns table (
  success boolean,
  error_code text,
  error_message text,
  subtotal_amount numeric,
  discount_amount numeric,
  final_amount numeric
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_first public.booking_holds%rowtype;
  v_hold public.booking_holds%rowtype;
  v_existing public.promotion_redemptions%rowtype;
  v_is_group boolean;
  v_subtotal numeric := 0;
  v_count integer := 0;
begin
  perform public.expire_stale_booking_holds();
  v_is_group := exists (select 1 from public.booking_holds where booking_group_token = p_token);
  if v_is_group then
    for v_hold in
      select * from public.booking_holds where booking_group_token = p_token
      order by guest_index nulls first, id for update
    loop
      if v_first.id is null then v_first := v_hold; end if;
      v_count := v_count + 1;
    end loop;
  else
    select * into v_first from public.booking_holds where public_token = p_token for update;
    if v_first.id is not null then v_count := 1; end if;
  end if;
  if v_first.id is null then
    success := false; error_code := 'HOLD_NOT_FOUND'; error_message := 'Booking reference not found.';
    return next; return;
  end if;
  if exists (
    select 1 from public.booking_holds h
    where ((v_is_group and h.booking_group_token = p_token)
       or (not v_is_group and h.id = v_first.id))
      and (h.status <> 'pending_payment' or h.expires_at <= now())
  ) then
    success := false; error_code := 'HOLD_NOT_ACTIVE'; error_message := 'This booking hold can no longer be changed.';
    return next; return;
  end if;
  select * into v_existing
  from public.promotion_redemptions r
  where ((v_is_group and r.booking_group_token = p_token)
     or (not v_is_group and r.booking_hold_id = v_first.id))
    and r.status in ('reserved', 'redeemed')
  order by r.reserved_at desc, r.id desc
  limit 1 for update;
  if v_existing.id is not null and v_existing.status = 'redeemed' then
    success := false; error_code := 'PROMOTION_ALREADY_REDEEMED'; error_message := 'This promotion has already been redeemed.';
    return next; return;
  end if;
  if v_existing.id is not null then
    update public.promotion_redemptions
    set status = 'released', released_at = coalesce(released_at, now())
    where id = v_existing.id and status = 'reserved';
  end if;

  for v_hold in
    select * from public.booking_holds h
    where (v_is_group and h.booking_group_token = p_token)
       or (not v_is_group and h.id = v_first.id)
    order by h.guest_index nulls first, h.id for update
  loop
    update public.booking_holds
    set discount_amount = 0,
        total_amount = round(coalesce(v_hold.subtotal_amount, v_hold.total_amount, 0), 2),
        promotion_id = null,
        promotion_code_id = null,
        promotion_code = null,
        pricing_snapshot = jsonb_build_object(
          'subtotal_amount', round(coalesce(v_hold.subtotal_amount, v_hold.total_amount, 0), 2),
          'discount_amount', 0,
          'final_amount', round(coalesce(v_hold.subtotal_amount, v_hold.total_amount, 0), 2),
          'promotion_id', null,
          'promotion_code', null,
          'calculated_at', now()
        ),
        updated_at = now()
    where id = v_hold.id;
  end loop;
  select round(sum(coalesce(h.subtotal_amount, h.total_amount, 0)), 2)
  into v_subtotal
  from public.booking_holds h
  where (v_is_group and h.booking_group_token = p_token)
     or (not v_is_group and h.id = v_first.id);
  success := true; error_code := null; error_message := null;
  subtotal_amount := coalesce(v_subtotal, 0); discount_amount := 0; final_amount := coalesce(v_subtotal, 0);
  return next;
end;
$function$;

create or replace function public.get_public_booking_pricing(p_token uuid)
returns table (
  subtotal_amount numeric,
  discount_amount numeric,
  final_amount numeric,
  promotion_id uuid,
  promotion_code_id uuid,
  promotion_code text,
  promotion_name text,
  benefit_type text,
  benefit_value numeric,
  free_addon_service_id uuid,
  free_addon_service_name text,
  pricing_snapshot jsonb,
  status text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_first public.booking_holds%rowtype;
  v_redemption public.promotion_redemptions%rowtype;
  v_promo public.promotions%rowtype;
  v_addon_name text;
  v_is_group boolean;
begin
  v_is_group := exists (select 1 from public.booking_holds where booking_group_token = p_token);
  if v_is_group then
    select * into v_first from public.booking_holds
    where booking_group_token = p_token order by guest_index nulls first, id limit 1;
  else
    select * into v_first from public.booking_holds where public_token = p_token;
  end if;
  if v_first.id is null then return; end if;

  if v_is_group then
    select round(sum(coalesce(h.subtotal_amount, h.total_amount, 0)), 2),
           round(sum(coalesce(h.discount_amount, 0)), 2),
           round(sum(coalesce(h.total_amount, 0)), 2),
           min(h.expires_at),
           case when bool_and(h.status = 'pending_payment') then 'pending_payment'
                when bool_and(h.status = 'confirmed') then 'confirmed'
                else 'mixed' end
    into subtotal_amount, discount_amount, final_amount, expires_at, status
    from public.booking_holds h where h.booking_group_token = p_token;
    select * into v_redemption from public.promotion_redemptions r
    where r.booking_group_token = p_token and r.status in ('reserved', 'redeemed')
    order by r.reserved_at desc, r.id desc limit 1;
  else
    subtotal_amount := round(coalesce(v_first.subtotal_amount, v_first.total_amount, 0), 2);
    discount_amount := round(coalesce(v_first.discount_amount, 0), 2);
    final_amount := round(coalesce(v_first.total_amount, 0), 2);
    expires_at := v_first.expires_at;
    status := v_first.status;
    select * into v_redemption from public.promotion_redemptions r
    where r.booking_hold_id = v_first.id and r.status in ('reserved', 'redeemed')
    order by r.reserved_at desc, r.id desc limit 1;
  end if;
  promotion_id := coalesce(v_redemption.promotion_id, v_first.promotion_id);
  promotion_code_id := coalesce(v_redemption.promotion_code_id, v_first.promotion_code_id);
  promotion_code := coalesce(v_redemption.promotion_code, v_first.promotion_code);
  pricing_snapshot := coalesce(v_redemption.pricing_snapshot, v_first.pricing_snapshot);
  if promotion_id is not null then
    select * into v_promo from public.promotions where id = promotion_id;
    promotion_name := v_promo.name;
    benefit_type := v_promo.benefit_type;
    benefit_value := v_promo.benefit_value;
    free_addon_service_id := v_promo.free_addon_service_id;
    if free_addon_service_id is not null then
      select name into v_addon_name from public.services where id = free_addon_service_id;
      free_addon_service_name := v_addon_name;
    end if;
  end if;
  return next;
end;
$function$;

-- Public hold creation wrappers keep the existing resource allocation function
-- untouched and add the promotion reservation in the same PostgreSQL call.
create or replace function public.create_public_booking_group_hold_with_promotion_v1(
  p_allocations jsonb,
  p_start_at timestamptz,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_notes text default '',
  p_request_fingerprint text default '',
  p_promotion_code text default null
)
returns table (
  group_token uuid,
  hold_expires_at timestamptz,
  total_price numeric,
  guest_count integer
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_group record;
  v_promotion record;
begin
  select * into v_group
  from public.create_public_booking_group_hold_v1(
    p_allocations, p_start_at, p_customer_name, p_customer_phone,
    p_customer_email, p_notes, p_request_fingerprint
  );
  if nullif(trim(coalesce(p_promotion_code, '')), '') is not null then
    select * into v_promotion
    from public.reserve_public_booking_promotion(v_group.group_token, p_promotion_code, null);
    if not coalesce(v_promotion.success, false) then
      raise exception using
        errcode = 'P0001',
        message = coalesce(v_promotion.error_message, 'Promotion could not be applied.'),
        detail = coalesce(v_promotion.error_code, 'PROMOTION_INVALID');
    end if;
  end if;
  group_token := v_group.group_token;
  hold_expires_at := v_group.hold_expires_at;
  total_price := v_group.total_price;
  guest_count := v_group.guest_count;
  return next;
end;
$function$;

create or replace function public.create_public_booking_hold_with_promotion_v1(
  p_catalogue_id uuid,
  p_start_at timestamptz,
  p_therapist_preference text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_therapist_request text default '',
  p_notes text default '',
  p_request_fingerprint text default '',
  p_promotion_code text default null
)
returns table (
  hold_id uuid,
  hold_token uuid,
  hold_expires_at timestamptz,
  total_price numeric,
  deposit_due numeric,
  duration_minutes integer
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_hold record;
  v_promotion record;
begin
  select * into v_hold
  from public.create_public_booking_hold_v2(
    p_catalogue_id, p_start_at, p_therapist_preference,
    p_customer_name, p_customer_phone, p_customer_email,
    p_therapist_request, p_notes, p_request_fingerprint
  );
  if nullif(trim(coalesce(p_promotion_code, '')), '') is not null then
    select * into v_promotion
    from public.reserve_public_booking_promotion(v_hold.hold_token, p_promotion_code, null);
    if not coalesce(v_promotion.success, false) then
      raise exception using
        errcode = 'P0001',
        message = coalesce(v_promotion.error_message, 'Promotion could not be applied.'),
        detail = coalesce(v_promotion.error_code, 'PROMOTION_INVALID');
    end if;
  end if;
  hold_id := v_hold.hold_id;
  hold_token := v_hold.hold_token;
  hold_expires_at := v_hold.hold_expires_at;
  total_price := v_hold.total_price;
  deposit_due := v_hold.deposit_due;
  duration_minutes := v_hold.duration_minutes;
  return next;
end;
$function$;

create or replace function public.redeem_public_booking_promotion(p_token uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_is_group boolean := exists (select 1 from public.booking_holds where booking_group_token = p_token);
  v_first public.booking_holds%rowtype;
begin
  if v_is_group then
    select * into v_first from public.booking_holds
    where booking_group_token = p_token order by guest_index nulls first, id limit 1 for update;
    update public.promotion_redemptions
    set status = 'redeemed', redeemed_at = coalesce(redeemed_at, now()), customer_id = coalesce(customer_id, v_first.customer_id)
    where booking_group_token = p_token and status = 'reserved';
  else
    select * into v_first from public.booking_holds where public_token = p_token for update;
    update public.promotion_redemptions
    set status = 'redeemed', redeemed_at = coalesce(redeemed_at, now()), customer_id = coalesce(customer_id, v_first.customer_id)
    where booking_hold_id = v_first.id and status = 'reserved';
  end if;
  return true;
end;
$function$;

-- Public booking functions are called by the server-side Edge Function with
-- the service role. Staff can only use the explicit management RPCs, and no
-- client role receives table write grants.
do $$
declare
  v_function text;
begin
  foreach v_function in array array[
    'set_booking_hold_base_pricing()',
    'apply_booking_promotion_lifecycle()',
    'list_staff_promotions(uuid)',
    'generate_staff_promotion_code(uuid)',
    'upsert_staff_promotion(jsonb)',
    'set_staff_promotion_active(uuid,boolean)',
    'reserve_public_booking_promotion(uuid,text,uuid)',
    'remove_public_booking_promotion(uuid)',
    'get_public_booking_pricing(uuid)',
    'create_public_booking_group_hold_with_promotion_v1(jsonb,timestamptz,text,text,text,text,text,text)',
    'create_public_booking_hold_with_promotion_v1(uuid,timestamptz,text,text,text,text,text,text,text,text)',
    'redeem_public_booking_promotion(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', v_function);
  end loop;
  revoke all on table public.promotions, public.promotion_codes,
    public.promotion_outlets, public.promotion_services,
    public.promotion_redemptions from public, anon, authenticated;
  grant select on table public.promotions, public.promotion_codes,
    public.promotion_outlets, public.promotion_services to authenticated;
  grant select on table public.promotion_redemptions to authenticated;
end $$;

alter table public.promotions enable row level security;
alter table public.promotion_codes enable row level security;
alter table public.promotion_outlets enable row level security;
alter table public.promotion_services enable row level security;
alter table public.promotion_redemptions enable row level security;

drop policy if exists promotions_staff_select on public.promotions;
create policy promotions_staff_select on public.promotions
for select to authenticated using (public.is_staff_or_admin());
drop policy if exists promotion_codes_staff_select on public.promotion_codes;
create policy promotion_codes_staff_select on public.promotion_codes
for select to authenticated using (public.is_staff_or_admin());
drop policy if exists promotion_outlets_staff_select on public.promotion_outlets;
create policy promotion_outlets_staff_select on public.promotion_outlets
for select to authenticated using (public.is_staff_or_admin());
drop policy if exists promotion_services_staff_select on public.promotion_services;
create policy promotion_services_staff_select on public.promotion_services
for select to authenticated using (public.is_staff_or_admin());
drop policy if exists promotion_redemptions_admin_select on public.promotion_redemptions;
create policy promotion_redemptions_admin_select on public.promotion_redemptions
for select to authenticated using (public.is_admin());

grant execute on function public.list_staff_promotions(uuid) to authenticated;
grant execute on function public.generate_staff_promotion_code(uuid) to authenticated;
grant execute on function public.upsert_staff_promotion(jsonb) to authenticated;
grant execute on function public.set_staff_promotion_active(uuid,boolean) to authenticated;
grant execute on function public.create_public_booking_group_hold_with_promotion_v1(
  jsonb,timestamptz,text,text,text,text,text,text
) to service_role;
grant execute on function public.create_public_booking_hold_with_promotion_v1(
  uuid,timestamptz,text,text,text,text,text,text,text,text
) to service_role;
grant execute on function public.reserve_public_booking_promotion(uuid,text,uuid) to service_role;
grant execute on function public.remove_public_booking_promotion(uuid) to service_role;
grant execute on function public.get_public_booking_pricing(uuid) to service_role;
grant execute on function public.redeem_public_booking_promotion(uuid) to service_role;

comment on table public.promotions is 'Generic promotion definitions. Public pricing is calculated by reserve_public_booking_promotion.';
comment on table public.promotion_redemptions is 'One reservation per single booking or booking group; reserved uses are released by booking-hold lifecycle triggers.';
comment on column public.promotions.free_addon_scheduling_mode is 'Only no_resource + zero-duration services may be priced as a free add-on without creating a scheduled segment.';



