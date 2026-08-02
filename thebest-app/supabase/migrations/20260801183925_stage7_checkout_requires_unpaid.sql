-- A server-authorised counter checkout may only transition an unpaid
-- appointment. This blocks an already-paid Billplz appointment from receiving
-- a second counter transaction when its primary receipt is group-linked.
create or replace function public.protect_appointment_financial_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('app.authorized_financial_write', true) = 'on'
     and old.payment_status <> 'unpaid'::public.payment_status then
    raise exception using
      errcode = '23514',
      message = 'Only an unpaid appointment can enter counter checkout.';
  end if;

  if (
    new.total_price is distinct from old.total_price
    or new.payment_status is distinct from old.payment_status
  ) and not (
    current_user in ('postgres', 'supabase_admin', 'service_role')
    or (select public.is_admin())
  ) then
    raise exception using
      errcode = '42501',
      message = 'Only an administrator or authorised payment workflow can change appointment financial fields.';
  end if;

  return new;
end;
$$;

revoke all on function public.protect_appointment_financial_fields()
from public, anon, authenticated, service_role;
