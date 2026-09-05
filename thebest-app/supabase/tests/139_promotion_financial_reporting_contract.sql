-- Rollback-only STAGING contract for promotion financial reporting.

begin;

do $contract$
declare
  v_outlet_id uuid;
  v_service_id uuid;
  v_therapist_id uuid;
  v_promotion_id uuid := gen_random_uuid();
  v_code_id uuid := gen_random_uuid();
  v_discounted_id uuid := gen_random_uuid();
  v_plain_id uuid := gen_random_uuid();
  v_percentage_id uuid := gen_random_uuid();
  v_commission_gross numeric;
  v_commission_discounted numeric;
  v_gross numeric;
  v_discount numeric;
  v_collected numeric;
  v_discounted_count integer;
  v_body text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'transactions'
      and column_name = 'gross_amount'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'transactions'
      and column_name = 'discount_amount'
  ) then
    raise exception 'Transaction promotion financial columns are missing';
  end if;

  select id into v_outlet_id from public.outlets where is_active order by id limit 1;
  select id into v_service_id from public.services where is_active order by id limit 1;
  select id into v_therapist_id from public.therapists order by id limit 1;
  if v_outlet_id is null or v_service_id is null or v_therapist_id is null then
    raise exception 'STAGING requires an outlet, service and therapist fixture';
  end if;

  insert into public.promotions (
    id, name, benefit_type, benefit_value, usage_type, active,
    max_redemptions, starts_at
  ) values (
    v_promotion_id, 'Financial contract promotion', 'fixed_discount', 10,
    'multi_use', true, 10, now() - interval '1 day'
  );
  insert into public.promotion_codes (id, promotion_id, code)
  values (v_code_id, v_promotion_id, 'FINANCIALCONTRACT10');

  insert into public.transactions (
    id, outlet_id, receipt_number, service_name, service_items,
    service_price, sst_amount, total_amount, gross_amount, discount_amount,
    promotion_id, promotion_code_id, promotion_code,
    promotion_pricing_snapshot, payment_method, payment_status, source
  ) values
  (
    v_discounted_id, v_outlet_id, 'FIN-CONTRACT-DISCOUNT', 'Contract Service',
    jsonb_build_array(jsonb_build_object('id', v_service_id, 'name', 'Contract Service', 'price', 39)),
    39, 0, 29, 39, 10, v_promotion_id, v_code_id, 'FINANCIALCONTRACT10',
    jsonb_build_object('subtotal_amount', 39, 'discount_amount', 10, 'final_amount', 29),
    'cash', 'paid', 'online_booking'
  ),
  (
    v_plain_id, v_outlet_id, 'FIN-CONTRACT-PLAIN', 'Contract Service',
    jsonb_build_array(jsonb_build_object('id', v_service_id, 'name', 'Contract Service', 'price', 50)),
    50, 0, 50, 50, 0, null, null, null, '{}'::jsonb,
    'cash', 'paid', 'walkin'
  ),
  (
    v_percentage_id, v_outlet_id, 'FIN-CONTRACT-PERCENT', 'Contract Service',
    jsonb_build_array(jsonb_build_object('id', v_service_id, 'name', 'Contract Service', 'price', 39)),
    39, 0, 35.10, 39, round(39 * 10 / 100.0, 2), null, null, 'PERCENT10',
    jsonb_build_object('benefit_type', 'percentage_discount', 'benefit_value', 10,
      'subtotal_amount', 39, 'discount_amount', round(39 * 10 / 100.0, 2), 'final_amount', 35.10),
    'cash', 'paid', 'online_booking'
  );

  if (select gross_amount from public.transactions where id = v_plain_id) <> 50
     or (select discount_amount from public.transactions where id = v_plain_id) <> 0
     or (select total_amount from public.transactions where id = v_plain_id) <> 50 then
    raise exception 'No-discount accounting is incorrect';
  end if;
  if (select gross_amount from public.transactions where id = v_discounted_id) <> 39
     or (select discount_amount from public.transactions where id = v_discounted_id) <> 10
     or (select total_amount from public.transactions where id = v_discounted_id) <> 29
     or (select service_price from public.transactions where id = v_discounted_id) <> 39
     or (select service_items -> 0 ->> 'price' from public.transactions where id = v_discounted_id)::numeric <> 39 then
    raise exception 'Fixed-discount accounting overwrote the gross service price';
  end if;
  if (select discount_amount from public.transactions where id = v_percentage_id) <> 3.90
     or (select total_amount from public.transactions where id = v_percentage_id) <> 35.10
     or (select promotion_pricing_snapshot ->> 'discount_amount' from public.transactions where id = v_percentage_id)::numeric <> 3.90 then
    raise exception 'Percentage discount rounding or snapshot persistence is incorrect';
  end if;

  select sum(gross_amount), sum(discount_amount), sum(total_amount),
         count(*) filter (where discount_amount > 0)
  into v_gross, v_discount, v_collected, v_discounted_count
  from public.transactions where id in (v_discounted_id, v_plain_id);
  if v_gross <> 89 or v_discount <> 10 or v_collected <> 79
     or v_gross - v_discount <> v_collected or v_discounted_count <> 1 then
    raise exception 'Daily sales accounting does not reconcile';
  end if;

  select public.csp_commission_for_items(
    jsonb_build_array(jsonb_build_object('id', v_service_id, 'price', 39)),
    v_therapist_id, 'Therapist'
  ) into v_commission_gross;
  select public.csp_commission_for_items(
    jsonb_build_array(jsonb_build_object('id', v_service_id, 'price', 29)),
    v_therapist_id, 'Therapist'
  ) into v_commission_discounted;
  if v_commission_gross is distinct from v_commission_discounted then
    raise exception 'Discount changed the therapist commission base';
  end if;

  select regexp_replace(
    pg_get_functiondef('public.record_online_booking_group_payment(uuid)'::regprocedure),
    '[[:space:]]+', '', 'g'
  ) into v_body;
  if v_body not ilike '%gross_amount%'
     or v_body not ilike '%discount_amount%'
     or v_body not ilike '%promotion_pricing_snapshot%'
     or v_body not ilike '%''price'',round(coalesce(h.subtotal_amount,h.total_amount,0),2)%' then
    raise exception 'Online group payment does not preserve original line pricing';
  end if;

  select regexp_replace(
    pg_get_functiondef('public.record_online_booking_payment(uuid)'::regprocedure),
    '[[:space:]]+', '', 'g'
  ) into v_body;
  if v_body not ilike '%outlet_payment_breakdown(v_hold.outlet_id,v_gross_amount,''billplz'')%'
     or v_body not ilike '%v_total_amount:=round(coalesce(v_hold.total_amount,0),2)%' then
    raise exception 'Online payment does not separate original price from final collected amount';
  end if;
end
$contract$;

rollback;
