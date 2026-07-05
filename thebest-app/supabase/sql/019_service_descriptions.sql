-- Treatment information displayed by the public booking website.
-- Existing services remain valid and start with an empty description.

alter table public.services
  add column if not exists service_description text not null default '';

