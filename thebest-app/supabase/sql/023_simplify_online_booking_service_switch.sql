-- One admin-facing switch controls whether a configured service is public.
-- Patch already-deployed function bodies before removing the redundant flags.

do $$
declare
  v_signature text;
  v_definition text;
  v_patched text;
begin
  foreach v_signature in array array[
    'public.list_public_booking_catalogue(text)',
    'public.get_public_booking_slots_v2(uuid,date,text)'
  ] loop
    select pg_get_functiondef(v_signature::regprocedure) into v_definition;
    v_patched := replace(
      v_definition,
      'c.enabled and c.publicly_visible and c.online_bookable',
      'c.enabled'
    );
    v_patched := replace(
      v_patched,
      '(v_cfg.enabled and v_cfg.publicly_visible and v_cfg.online_bookable)',
      'v_cfg.enabled'
    );
    if v_patched <> v_definition then execute v_patched; end if;
  end loop;
end;
$$;

alter table public.online_booking_services
  drop column if exists publicly_visible,
  drop column if exists online_bookable;

drop index if exists public.online_booking_services_public_idx;
create index online_booking_services_public_idx
  on public.online_booking_services(outlet_id, enabled, display_order);

-- One admin-facing switch controls whether a configured service is public.
-- Patch already-deployed function bodies before removing the redundant flags.

do $$
declare
  v_signature text;
  v_definition text;
  v_patched text;
begin
  foreach v_signature in array array[
    'public.list_public_booking_catalogue(text)',
    'public.get_public_booking_slots_v2(uuid,date,text)'
  ] loop
    select pg_get_functiondef(v_signature::regprocedure) into v_definition;
    v_patched := replace(
      v_definition,
      'c.enabled and c.publicly_visible and c.online_bookable',
      'c.enabled'
    );
    v_patched := replace(
      v_patched,
      '(v_cfg.enabled and v_cfg.publicly_visible and v_cfg.online_bookable)',
      'v_cfg.enabled'
    );
    if v_patched <> v_definition then execute v_patched; end if;
  end loop;
end;
$$;

alter table public.online_booking_services
  drop column if exists publicly_visible,
  drop column if exists online_bookable;

drop index if exists public.online_booking_services_public_idx;
create index online_booking_services_public_idx
  on public.online_booking_services(outlet_id, enabled, display_order);

