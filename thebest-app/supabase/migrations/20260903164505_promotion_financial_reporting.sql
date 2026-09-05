-- Preserve monetary promotions as explicit transaction adjustments.
-- total_amount remains the final/collected amount for paid transactions.

alter table public.transactions
  add column if not exists gross_amount numeric(12,2),
  add column if not exists discount_amount numeric(12,2) not null default 0,
  add column if not exists promotion_id uuid references public.promotions(id) on delete set null,
  add column if not exists promotion_code_id uuid references public.promotion_codes(id) on delete set null,
  add column if not exists promotion_code text,
  add column if not exists promotion_pricing_snapshot jsonb not null default '{}'::jsonb;

update public.transactions
set gross_amount = round(coalesce(gross_amount, total_amount), 2),
    discount_amount = round(coalesce(discount_amount, 0), 2),
    promotion_pricing_snapshot = coalesce(promotion_pricing_snapshot, '{}'::jsonb)
where gross_amount is null
   or discount_amount is null
   or promotion_pricing_snapshot is null;

alter table public.transactions alter column gross_amount set not null;

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.transactions'::regclass
      and conname = 'transactions_promotion_amounts_nonnegative'
  ) then
    alter table public.transactions
      add constraint transactions_promotion_amounts_nonnegative
      check (gross_amount >= 0 and discount_amount >= 0 and discount_amount <= gross_amount);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.transactions'::regclass
      and conname = 'transactions_promotion_amounts_reconcile'
  ) then
    alter table public.transactions
      add constraint transactions_promotion_amounts_reconcile
      check (abs((gross_amount - discount_amount) - total_amount) <= 0.01);
  end if;
end
$constraints$;

create index if not exists transactions_promotion_id_idx
  on public.transactions (promotion_id, created_at desc)
  where promotion_id is not null;
create index if not exists transactions_discounted_created_idx
  on public.transactions (created_at desc)
  where discount_amount > 0;

alter table public.promotion_redemptions
  add column if not exists transaction_id uuid references public.transactions(id) on delete restrict;
create unique index if not exists promotion_redemptions_transaction_uidx
  on public.promotion_redemptions (transaction_id)
  where transaction_id is not null;

create or replace function public.set_transaction_financial_snapshot()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  new.discount_amount := round(coalesce(new.discount_amount, 0), 2);
  if new.gross_amount is null then
    new.gross_amount := round(coalesce(new.total_amount, 0) + new.discount_amount, 2);
  elsif tg_op = 'UPDATE'
        and new.discount_amount = 0
        and new.promotion_id is null
        and new.total_amount is distinct from old.total_amount
        and new.gross_amount is not distinct from old.gross_amount then
    new.gross_amount := round(coalesce(new.total_amount, 0), 2);
  else
    new.gross_amount := round(new.gross_amount, 2);
  end if;
  new.promotion_pricing_snapshot := coalesce(new.promotion_pricing_snapshot, '{}'::jsonb);
  return new;
end;
$function$;

drop trigger if exists transactions_financial_snapshot on public.transactions;
create trigger transactions_financial_snapshot
before insert or update of total_amount, gross_amount, discount_amount,
  promotion_id, promotion_code_id, promotion_code, promotion_pricing_snapshot
on public.transactions
for each row execute function public.set_transaction_financial_snapshot();

create or replace function public.record_online_booking_payment(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_hold public.booking_holds%rowtype;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_redemption public.promotion_redemptions%rowtype;
  v_therapist_name text := '';
  v_room_name text := '';
  v_service_price numeric := 0;
  v_sst_amount numeric := 0;
  v_total_amount numeric := 0;
  v_gross_amount numeric := 0;
  v_discount_amount numeric := 0;
  v_items jsonb := '[]'::jsonb;
  v_snapshot jsonb := '{}'::jsonb;
  v_transaction_id uuid;
begin
  select * into v_hold from public.booking_holds
  where public_token = p_token for update;
  if not found or v_hold.status <> 'confirmed' or v_hold.appointment_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  select * into v_appointment from public.appointments
  where id = v_hold.appointment_id;
  select * into v_customer from public.customers where id = v_appointment.customer_id;
  select coalesce(name, '') into v_therapist_name from public.therapists
  where id = v_appointment.therapist_id;
  select coalesce(name, '') into v_room_name from public.rooms
  where id = v_appointment.room_id;

  v_gross_amount := round(coalesce(v_hold.subtotal_amount, v_hold.total_amount, 0), 2);
  v_discount_amount := round(coalesce(v_hold.discount_amount, 0), 2);
  select b.service_price, b.sst_amount
  into v_service_price, v_sst_amount
  from public.outlet_payment_breakdown(
    v_hold.outlet_id, v_gross_amount, 'billplz'
  ) b;
  v_total_amount := round(coalesce(v_hold.total_amount, 0), 2);

  v_items := coalesce(
    nullif(v_hold.service_items, '[]'::jsonb),
    nullif(v_appointment.service_items, '[]'::jsonb),
    '[]'::jsonb
  );
  if jsonb_array_length(v_items) = 1 then
    v_items := jsonb_build_array(
      (v_items -> 0) || jsonb_build_object(
        'id', v_appointment.service_id,
        'name', coalesce(nullif(v_appointment.service_name, ''), v_items -> 0 ->> 'name', 'Service'),
        'price', v_gross_amount,
        'appointmentId', v_appointment.id,
        'lineType', 'booked',
        'assignedTherapistId', v_appointment.therapist_id,
        'assignedTherapistName', v_therapist_name,
        'assignedRoomId', v_appointment.room_id,
        'assignedRoomName', v_room_name
      )
    );
  end if;

  select * into v_redemption
  from public.promotion_redemptions r
  where r.booking_hold_id = v_hold.id and r.status = 'redeemed'
  order by r.redeemed_at desc nulls last, r.id desc
  limit 1;
  v_snapshot := coalesce(v_redemption.pricing_snapshot, v_hold.pricing_snapshot, '{}'::jsonb)
    || jsonb_build_object(
      'gross_amount', v_gross_amount,
      'discount_amount', v_discount_amount,
      'final_amount', v_total_amount,
      'promotion_id', coalesce(v_redemption.promotion_id, v_hold.promotion_id),
      'promotion_code', coalesce(v_redemption.promotion_code, v_hold.promotion_code),
      'transaction_recorded_at', now()
    );

  insert into public.transactions (
    outlet_id, appointment_id, customer_id, customer_name, customer_phone,
    service_id, service_name, service_items, item_count,
    therapist_id, therapist_name, room_id, room_name,
    service_price, sst_amount, total_amount, gross_amount, discount_amount,
    promotion_id, promotion_code_id, promotion_code, promotion_pricing_snapshot,
    payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_hold.outlet_id, v_appointment.id, v_appointment.customer_id,
    coalesce(v_customer.name, v_hold.customer_name),
    coalesce(v_customer.phone, v_hold.customer_phone),
    v_appointment.service_id, v_appointment.service_name, v_items,
    greatest(coalesce(v_appointment.item_count, 1), 1),
    v_appointment.therapist_id, v_therapist_name,
    v_appointment.room_id, v_room_name,
    v_service_price, v_sst_amount, v_total_amount,
    v_gross_amount, v_discount_amount,
    coalesce(v_redemption.promotion_id, v_hold.promotion_id),
    coalesce(v_redemption.promotion_code_id, v_hold.promotion_code_id),
    coalesce(v_redemption.promotion_code, v_hold.promotion_code), v_snapshot,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_hold.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_id)
    where source = 'online_booking' and appointment_id is not null
  do update set payment_status = 'paid',
                service_items = excluded.service_items,
                item_count = excluded.item_count,
                service_price = excluded.service_price,
                sst_amount = excluded.sst_amount,
                total_amount = excluded.total_amount,
                gross_amount = excluded.gross_amount,
                discount_amount = excluded.discount_amount,
                promotion_id = excluded.promotion_id,
                promotion_code_id = excluded.promotion_code_id,
                promotion_code = excluded.promotion_code,
                promotion_pricing_snapshot = excluded.promotion_pricing_snapshot,
                receipt_number = excluded.receipt_number
  returning id into v_transaction_id;

  if v_redemption.id is not null then
    update public.promotion_redemptions
    set transaction_id = v_transaction_id
    where id = v_redemption.id and transaction_id is distinct from v_transaction_id;
  end if;
  return v_transaction_id;
end;
$function$;

create or replace function public.record_online_booking_group_payment(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_group_id uuid;
  v_first public.booking_holds%rowtype;
  v_customer public.customers%rowtype;
  v_redemption public.promotion_redemptions%rowtype;
  v_service_price numeric := 0;
  v_sst numeric := 0;
  v_total numeric := 0;
  v_gross numeric := 0;
  v_discount numeric := 0;
  v_items jsonb;
  v_count integer;
  v_snapshot jsonb := '{}'::jsonb;
  v_transaction_id uuid;
begin
  select * into v_first from public.booking_holds h
  where h.booking_group_token = p_token
  order by h.guest_index limit 1 for update;
  if not found or v_first.appointment_group_id is null then
    raise exception 'The paid booking has not been confirmed';
  end if;
  v_group_id := v_first.appointment_group_id;

  select round(sum(coalesce(h.subtotal_amount, h.total_amount, 0)), 2),
         round(sum(coalesce(h.discount_amount, 0)), 2),
         round(sum(h.total_amount), 2),
         count(*),
         jsonb_agg(
           coalesce(h.service_items -> 0, '{}'::jsonb)
           || jsonb_strip_nulls(jsonb_build_object(
             'id', a.service_id,
             'name', coalesce(nullif(a.service_name, ''),
               nullif(h.service_items -> 0 ->> 'public_name', ''), s.name, 'Service'),
             'appointmentId', h.appointment_id,
             'guestName', h.guest_name,
             'price', round(coalesce(h.subtotal_amount, h.total_amount, 0), 2),
             'lineType', 'booked',
             'assignedTherapistId', a.therapist_id,
             'assignedTherapistName', therapist.name,
             'assignedRoomId', a.room_id,
             'assignedRoomName', room.name
           )) order by h.guest_index
         )
  into v_gross, v_discount, v_total, v_count, v_items
  from public.booking_holds h
  join public.appointments a on a.id = h.appointment_id
  left join public.services s on s.id = a.service_id
  left join public.therapists therapist on therapist.id = a.therapist_id
  left join public.rooms room on room.id = a.room_id
  where h.booking_group_token = p_token;

  select b.service_price, b.sst_amount
  into v_service_price, v_sst
  from public.outlet_payment_breakdown(v_first.outlet_id, v_gross, 'billplz') b;
  select * into v_customer from public.customers c where c.id = v_first.customer_id;
  select * into v_redemption
  from public.promotion_redemptions r
  where r.booking_group_token = p_token and r.status = 'redeemed'
  order by r.redeemed_at desc nulls last, r.id desc
  limit 1;
  v_snapshot := coalesce(v_redemption.pricing_snapshot, v_first.pricing_snapshot, '{}'::jsonb)
    || jsonb_build_object(
      'gross_amount', v_gross,
      'discount_amount', v_discount,
      'final_amount', v_total,
      'promotion_id', coalesce(v_redemption.promotion_id, v_first.promotion_id),
      'promotion_code', coalesce(v_redemption.promotion_code, v_first.promotion_code),
      'transaction_recorded_at', now()
    );

  insert into public.transactions (
    outlet_id, appointment_group_id, customer_id, customer_name, customer_phone,
    service_name, service_items, item_count, service_price, sst_amount,
    total_amount, gross_amount, discount_amount,
    promotion_id, promotion_code_id, promotion_code, promotion_pricing_snapshot,
    payment_method, payment_status, receipt_number, source, created_at
  ) values (
    v_first.outlet_id, v_group_id, v_first.customer_id,
    coalesce(v_customer.name, v_first.customer_name),
    coalesce(v_customer.phone, v_first.customer_phone),
    'Online group booking', v_items, v_count, v_service_price, v_sst, v_total,
    v_gross, v_discount,
    coalesce(v_redemption.promotion_id, v_first.promotion_id),
    coalesce(v_redemption.promotion_code_id, v_first.promotion_code_id),
    coalesce(v_redemption.promotion_code, v_first.promotion_code), v_snapshot,
    'billplz', 'paid',
    'BP-' || upper(coalesce(v_first.billplz_bill_id, left(p_token::text, 12))),
    'online_booking', now()
  )
  on conflict (appointment_group_id)
    where appointment_group_id is not null
      and coalesce(source, '') <> 'appointment_addon'
  do update set payment_status = 'paid', service_name = excluded.service_name,
                service_items = excluded.service_items, item_count = excluded.item_count,
                service_price = excluded.service_price, sst_amount = excluded.sst_amount,
                total_amount = excluded.total_amount,
                gross_amount = excluded.gross_amount,
                discount_amount = excluded.discount_amount,
                promotion_id = excluded.promotion_id,
                promotion_code_id = excluded.promotion_code_id,
                promotion_code = excluded.promotion_code,
                promotion_pricing_snapshot = excluded.promotion_pricing_snapshot,
                receipt_number = excluded.receipt_number
  returning id into v_transaction_id;

  if v_redemption.id is not null then
    update public.promotion_redemptions
    set transaction_id = v_transaction_id
    where id = v_redemption.id and transaction_id is distinct from v_transaction_id;
  end if;
  return v_transaction_id;
end;
$function$;

create or replace function public.list_staff_promotions(p_outlet_id uuid default null)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not public.is_admin() then
    raise exception using errcode = '42501', message = 'Promotion access is restricted to administrators.';
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
      from public.promotion_outlets po where po.promotion_id = p.id
    ), '[]'::jsonb),
    'service_ids', coalesce((
      select jsonb_agg(ps.service_id order by ps.service_id)
      from public.promotion_services ps where ps.promotion_id = p.id
    ), '[]'::jsonb),
    'codes', coalesce((
      select jsonb_agg(
        jsonb_build_object('id', pc.id, 'code', pc.code, 'active', pc.active)
        order by pc.created_at, pc.id
      ) from public.promotion_codes pc where pc.promotion_id = p.id
    ), '[]'::jsonb),
    'code_count', (select count(*) from public.promotion_codes pc where pc.promotion_id = p.id),
    'reserved_count', (select count(*) from public.promotion_redemptions pr where pr.promotion_id = p.id and pr.status = 'reserved'),
    'redeemed_count', (select count(*) from public.promotion_redemptions pr where pr.promotion_id = p.id and pr.status = 'redeemed'),
    'released_count', (select count(*) from public.promotion_redemptions pr where pr.promotion_id = p.id and pr.status = 'released'),
    'redeemed_discount_amount', coalesce((
      select round(sum(pr.discount_amount), 2)
      from public.promotion_redemptions pr
      where pr.promotion_id = p.id and pr.status = 'redeemed'
    ), 0),
    'redeemed_gross_amount', coalesce((
      select round(sum(pr.subtotal_amount), 2)
      from public.promotion_redemptions pr
      where pr.promotion_id = p.id and pr.status = 'redeemed'
    ), 0),
    'redeemed_net_amount', coalesce((
      select round(sum(pr.final_amount), 2)
      from public.promotion_redemptions pr
      where pr.promotion_id = p.id and pr.status = 'redeemed'
    ), 0)
  )
  from public.promotions p
  left join public.services addon on addon.id = p.free_addon_service_id
  where p_outlet_id is null
     or not exists (select 1 from public.promotion_outlets po where po.promotion_id = p.id)
     or exists (
       select 1 from public.promotion_outlets po
       where po.promotion_id = p.id and po.outlet_id = p_outlet_id
     )
  order by p.active desc, p.starts_at desc, p.created_at desc;
end;
$function$;

-- Online Booking management is admin-only in the app; keep database
-- authorization aligned so regular staff cannot bypass the hidden menu.
drop policy if exists promotions_staff_select on public.promotions;
create policy promotions_staff_select on public.promotions
for select to authenticated using ((select public.is_admin()));
drop policy if exists promotion_codes_staff_select on public.promotion_codes;
create policy promotion_codes_staff_select on public.promotion_codes
for select to authenticated using ((select public.is_admin()));
drop policy if exists promotion_outlets_staff_select on public.promotion_outlets;
create policy promotion_outlets_staff_select on public.promotion_outlets
for select to authenticated using ((select public.is_admin()));
drop policy if exists promotion_services_staff_select on public.promotion_services;
create policy promotion_services_staff_select on public.promotion_services
for select to authenticated using ((select public.is_admin()));

do $admin_management$
declare
  v_function regprocedure;
  v_definition text;
begin
  foreach v_function in array array[
    'public.generate_staff_promotion_code(uuid)'::regprocedure,
    'public.upsert_staff_promotion(jsonb)'::regprocedure,
    'public.set_staff_promotion_active(uuid,boolean)'::regprocedure
  ] loop
    select pg_get_functiondef(v_function) into v_definition;
    v_definition := replace(v_definition, 'public.is_staff_or_admin()', 'public.is_admin()');
    v_definition := replace(v_definition, 'restricted to staff', 'restricted to administrators');
    execute v_definition;
  end loop;
end
$admin_management$;

revoke all on function public.set_transaction_financial_snapshot()
  from public, anon, authenticated;
revoke all on function public.record_online_booking_payment(uuid)
  from public, anon, authenticated;
revoke all on function public.record_online_booking_group_payment(uuid)
  from public, anon, authenticated;
grant execute on function public.record_online_booking_payment(uuid) to service_role;
grant execute on function public.record_online_booking_group_payment(uuid) to service_role;
revoke all on table public.promotion_redemptions from anon;

comment on column public.transactions.gross_amount is
  'Original customer-facing service total before monetary promotion discounts.';
comment on column public.transactions.discount_amount is
  'Separate monetary promotion adjustment; never a replacement service price.';
comment on column public.transactions.total_amount is
  'Final payable amount; for paid non-voided transactions this is Sales Collected.';
comment on column public.transactions.promotion_pricing_snapshot is
  'Immutable promotion/pricing audit snapshot copied from the redeemed booking hold.';
comment on column public.promotion_redemptions.transaction_id is
  'Paid transaction created atomically with promotion redemption.';
