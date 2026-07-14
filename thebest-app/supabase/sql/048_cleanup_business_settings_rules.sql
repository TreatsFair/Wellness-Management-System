-- Cleanup after 047: keep only the late-extension-aware checkout signature
-- and add validation constraints for the new business settings.

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'business_settings_sst_pricing_mode_check'
  ) then
    alter table public.business_settings
      add constraint business_settings_sst_pricing_mode_check
      check (sst_pricing_mode in ('inclusive', 'exclusive'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'business_settings_sst_rounding_mode_check'
  ) then
    alter table public.business_settings
      add constraint business_settings_sst_rounding_mode_check
      check (sst_rounding_mode in (
        'nearest_cent',
        'nearest_5_sen',
        'floor_cent',
        'ceil_cent'
      ));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'business_settings_sst_rate_check'
  ) then
    alter table public.business_settings
      add constraint business_settings_sst_rate_check
      check (sst_rate_percent >= 0 and sst_rate_percent <= 100);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'business_settings_late_minutes_check'
  ) then
    alter table public.business_settings
      add constraint business_settings_late_minutes_check
      check (
        late_grace_minutes between 0 and 240
        and no_show_threshold_minutes between 0 and 240
        and delay_warning_minutes between 0 and 240
      );
  end if;
end $$;

drop function if exists public.checkout_appointment_with_payment(
  uuid, uuid, text, text, date, time, time, timestamptz, timestamptz,
  uuid, text, numeric, numeric, numeric, text, text, text
);
