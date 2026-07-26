-- 087: Fix customer-facing typo on the Taman Wahyu public booking catalogue.
--
-- The Taman Wahyu operating-hours repair that originally lived here has moved to
-- 088, which introduces per-day business hours and can express the real
-- Mon-Thu 23:00 / Fri-Sun 23:30 schedule instead of a single flat close time.

update public.online_booking_services
set public_name = 'Body Massage'
where outlet_id = '00000000-0000-0000-0000-000000000002'
  and public_name = 'Body Masssage';
