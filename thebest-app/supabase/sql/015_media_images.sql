-- Device image uploads for business, service, and staff records.
-- Files live in Supabase Storage; tables keep public URLs for display.

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'app-images',
  'app-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

alter table if exists public.settings
  add column if not exists logo_url text not null default '';

alter table if exists public.services
  add column if not exists image_url text not null default '';

alter table if exists public.therapists
  add column if not exists profile_image_url text not null default '';

drop policy if exists "app_images_public_read" on storage.objects;
-- Public buckets can serve public URLs without a broad SELECT policy.
-- Keeping this policy removed avoids allowing clients to list all objects.

drop policy if exists "app_images_staff_insert" on storage.objects;
create policy "app_images_staff_insert"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'app-images'
);

drop policy if exists "app_images_staff_update" on storage.objects;
create policy "app_images_staff_update"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'app-images'
)
with check (
  bucket_id = 'app-images'
);

drop policy if exists "app_images_staff_delete" on storage.objects;
create policy "app_images_staff_delete"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'app-images'
);
