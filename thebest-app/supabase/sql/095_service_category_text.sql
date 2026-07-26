-- services.category was a fixed enum (service_category: Services/Packages/Add-ons),
-- but the app treats categories as free-form: there is a per-outlet
-- service_categories text table and an "Add Category" flow. Saving a service with
-- any new category (e.g. "Online") failed with:
--   invalid input value for enum service_category: "Online" (22P02)
--
-- Convert the column to plain text so custom categories can be stored. The
-- service_category enum is used by nothing else (verified: no other columns, no
-- routine bodies reference it), so it is dropped afterwards. Category ordering in
-- the app is handled in Dart (_compareServiceCategories), not by the enum order.

alter table public.services alter column category drop default;
alter table public.services alter column category type text using category::text;
alter table public.services alter column category set default 'Services';

drop type if exists public.service_category;
