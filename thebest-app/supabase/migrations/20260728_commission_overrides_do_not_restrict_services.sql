-- Commission overrides must not restrict which services a therapist can do.
--
-- `therapists.service_commissions` was doing two unrelated jobs:
--
--   * the Therapists screen writes it as a per-service commission RATE
--     override (`{service_id: percent}`), and
--   * every scheduling path reads a non-empty map as an EXCLUSIVE eligibility
--     whitelist -- `allocate_preference_provisional_slots_122r_impl`,
--     `allocate_provisional_slots`, `finalize_and_start_appointment_core`,
--     `match_finalize_start_therapists_recursive`, `preview_check_in`,
--     `create_public_booking_hold_v2`, `get_public_booking_slots_v2`,
--     `get_public_booking_group_slots_scan_v1`, and the dormant
--     `capacity_feasible_119b_legacy`.
--
-- So setting one custom commission percent silently removed that therapist
-- from every other service. PV128's "(1) Alex" had a single 22% override on
-- Foot Massage and became foot-massage-only across nine active services. He
-- was the only therapist in either outlet with any override, which confirms
-- the whitelist behaviour has never been used deliberately.
--
-- Rather than rewrite nine large functions, the two concerns are separated at
-- the column level: rate overrides move to `commission_overrides`, and
-- `service_commissions` is emptied. Every eligibility clause then reads `{}`
-- and stops restricting, with no change to their bodies. `service_commissions`
-- is retained (empty) so those functions, and any rollback, stay valid.
--
-- Only one server-side function reads the map for RATES --
-- `csp_commission_for_items` -- so it is the single function repointed here.

begin;

alter table public.therapists
  add column if not exists commission_overrides jsonb not null
    default '{}'::jsonb;

comment on column public.therapists.commission_overrides is
  'Per-service commission rate overrides {service_id: percent}. Rates only -- '
  'this NEVER restricts which services a therapist can perform.';

comment on column public.therapists.service_commissions is
  'Deprecated as of 2026-07-28 and kept empty. Scheduling functions still read '
  'a non-empty value as an exclusive service whitelist, so do not write rate '
  'overrides here -- use commission_overrides.';

-- Move existing overrides across, then clear the whitelist side.
update public.therapists
set commission_overrides = coalesce(service_commissions, '{}'::jsonb)
where coalesce(service_commissions, '{}'::jsonb) <> '{}'::jsonb
  and commission_overrides = '{}'::jsonb;

update public.therapists
set service_commissions = '{}'::jsonb
where coalesce(service_commissions, '{}'::jsonb) <> '{}'::jsonb;

-- Rate lookup now reads the override column. Body is otherwise the live
-- definition verbatim.
create or replace function public.csp_commission_for_items(
  p_service_items jsonb,
  p_staff_id uuid,
  p_role text
)
returns numeric
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_overrides jsonb;
  v_is_counter boolean := position('counter' in lower(coalesce(p_role, ''))) > 0
    or position('cashier' in lower(coalesce(p_role, ''))) > 0;
  v_item jsonb;
  v_service_id uuid;
  v_total numeric := 0;
  v_default numeric;
begin
  if p_staff_id is null or p_service_items is null then
    return 0;
  end if;

  select coalesce(commission_overrides, '{}'::jsonb)
  into v_overrides
  from public.therapists
  where id = p_staff_id;

  for v_item in
    select value
    from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb))
  loop
    v_service_id := nullif(coalesce(
      v_item ->> 'id',
      v_item ->> 'serviceId',
      v_item ->> 'service_id'
    ), '')::uuid;
    if v_service_id is null then
      continue;
    end if;

    if v_overrides is not null and v_overrides ? v_service_id::text then
      v_total := v_total
        + coalesce((v_overrides ->> v_service_id::text)::numeric, 0);
      continue;
    end if;

    select case
      when v_is_counter then s.counter_commission
      else s.therapist_commission
    end
    into v_default
    from public.services s
    where s.id = v_service_id;

    v_total := v_total + coalesce(v_default, 0);
  end loop;

  return round(v_total, 2);
end;
$function$;

-- Nothing may reintroduce the whitelist by writing rates to the old column.
create or replace function public.therapists_reject_service_commission_writes()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if coalesce(new.service_commissions, '{}'::jsonb) <> '{}'::jsonb then
    raise exception using
      errcode = 'P0001',
      message = 'service_commissions is deprecated and must stay empty. '
                'Write per-service commission rates to commission_overrides.';
  end if;
  return new;
end;
$function$;

drop trigger if exists therapists_service_commissions_stay_empty
  on public.therapists;
create trigger therapists_service_commissions_stay_empty
  before insert or update of service_commissions on public.therapists
  for each row execute function
    public.therapists_reject_service_commission_writes();

commit;
