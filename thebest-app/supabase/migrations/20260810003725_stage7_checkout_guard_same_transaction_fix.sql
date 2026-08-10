-- Keep the Stage 7 unpaid-at-checkout boundary while allowing the remaining
-- statements in the same atomic checkout to update the now-paid appointment.
--
-- The transaction INSERT trigger sets app.authorized_financial_write = on.
-- Some checkout/start RPCs then perform another appointment UPDATE that
-- includes a protected column without changing payment_status. The previous
-- guard rejected that idempotent paid -> paid update because it inspected only
-- OLD.payment_status. Require an actual payment-status transition before
-- rejecting a non-unpaid row.

create or replace function public.protect_appointment_financial_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_snapshot record;
  v_breakdown record;
begin
  if tg_op = 'UPDATE'
     and current_setting('app.authorized_financial_write', true) = 'on'
     and old.payment_status is distinct from 'unpaid'::public.payment_status
     and new.payment_status is distinct from old.payment_status then
    raise exception using
      errcode = '23514',
      message = 'Only an unpaid appointment can enter counter checkout.';
  end if;

  if auth.uid() is null then
    return new;
  end if;
  if not (select public.is_staff_or_admin()) then
    raise exception using errcode = '42501', message = 'Not authorised';
  end if;
  if jsonb_typeof(coalesce(new.service_items, '[]'::jsonb)) = 'array'
     and jsonb_array_length(coalesce(new.service_items, '[]'::jsonb)) > 0 then
    select * into v_snapshot
    from private.authoritative_service_snapshot(new.outlet_id, new.service_items);
    new.service_items := v_snapshot.service_items;
    new.item_count := v_snapshot.item_count;
    new.service_id := ((v_snapshot.service_items -> 0) ->> 'id')::uuid;
    new.service_name := (v_snapshot.service_items -> 0) ->> 'name';
    if new.payment_status = 'paid'::public.payment_status then
      select * into v_breakdown
      from public.outlet_payment_breakdown(
        new.outlet_id,
        v_snapshot.display_price,
        'counter'
      );
      new.total_price := v_breakdown.total_amount;
    else
      new.total_price := v_snapshot.display_price;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.protect_appointment_financial_fields()
from public, anon, authenticated, service_role;

comment on function public.protect_appointment_financial_fields()
is 'Protects appointment money while allowing idempotent paid-row updates later in one authorized checkout transaction.';
