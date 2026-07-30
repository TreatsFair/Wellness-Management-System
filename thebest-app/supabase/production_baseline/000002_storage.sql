-- ============================================================================
-- 000002_storage.sql  —  Storage configuration for Treats Production
-- ============================================================================
-- Target : erjttzhownsxohpvzjbs (PRODUCTION, ap-southeast-1)
-- Derived: read-only inspection of staging hvyzexmsaxwendcexehx, 2026-07-30
-- Status : DRAFT — not applied anywhere.
--
-- A `--schema=public` dump cannot carry storage.buckets rows or the
-- storage.objects policies, so they are recreated deliberately here.
--
-- Reproduces staging EXACTLY. It copies NO files: staging holds 19 dummy
-- objects in app-images and none of them are referenced here. Real production
-- service images are uploaded separately, later.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- NOTE: this file contains no BEGIN/COMMIT. The transaction boundary is
-- supplied externally by psql --single-transaction, together with
-- ON_ERROR_STOP=1, so any failure rolls the whole file back. An internal
-- COMMIT would end that wrapper transaction early and silently weaken the
-- protection.

-- ---------------------------------------------------------------------------
-- 1. app-images bucket
--    Staging values, verified 2026-07-30:
--      id/name           = app-images
--      public            = true
--      file_size_limit   = 5242880  (5 MiB)
--      allowed_mime_types= {image/jpeg, image/png, image/webp}
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'app-images',
  'app-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  name               = excluded.name,
  public             = excluded.public,
  file_size_limit    = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- 2. storage.objects policies
--
--    Staging has exactly three, all PERMISSIVE, all granted to `authenticated`,
--    all keyed only on bucket_id. There is deliberately NO SELECT policy —
--    see the note in section 3.
--
--    ***CORRECTED FOR PRODUCTION — this is a deliberate divergence from
--    staging, approved as Stage 3D decision 12.***
--
--    Staging's three policies are NAMED "staff" but their predicate is only
--    `bucket_id = 'app-images'`, with no role check, so any authenticated user
--    can write to the bucket. Production adds the missing
--    `public.is_staff_or_admin()` term to INSERT, UPDATE and DELETE. The
--    bucket_id condition is retained unchanged, so these policies still govern
--    only app-images and cannot leak into another bucket.
--
--    Public READ is unaffected: the bucket is public, and Storage serves
--    public-bucket reads without consulting storage.objects RLS. Tightening
--    writes does not touch the read path (see section 3).
--
--    DIFF vs staging, per policy:
--        INSERT  with check (bucket_id = 'app-images')
--             -> with check (bucket_id = 'app-images' AND public.is_staff_or_admin())
--        UPDATE  using/with check (bucket_id = 'app-images')
--             -> using/with check (bucket_id = 'app-images' AND public.is_staff_or_admin())
--        DELETE  using (bucket_id = 'app-images')
--             -> using (bucket_id = 'app-images' AND public.is_staff_or_admin())
--
--    DEPENDENCY: public.is_staff_or_admin() is created by 000001, so this file
--    MUST be applied after 000001. The guard below fails loudly rather than
--    creating a policy that references a missing function.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'is_staff_or_admin'
  ) then
    raise exception
      'public.is_staff_or_admin() is missing — apply 000001_baseline_public.sql '
      'before 000002_storage.sql.';
  end if;
end
$$;

drop policy if exists "app_images_staff_insert" on storage.objects;
create policy "app_images_staff_insert"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'app-images'::text
  and public.is_staff_or_admin()
);

drop policy if exists "app_images_staff_update" on storage.objects;
create policy "app_images_staff_update"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'app-images'::text
  and public.is_staff_or_admin()
)
with check (
  bucket_id = 'app-images'::text
  and public.is_staff_or_admin()
);

drop policy if exists "app_images_staff_delete" on storage.objects;
create policy "app_images_staff_delete"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'app-images'::text
  and public.is_staff_or_admin()
);

-- ---------------------------------------------------------------------------
-- 3. Why no SELECT policy is needed — CONFIRMED
--
--    The bucket has public = true. Supabase Storage serves objects in a public
--    bucket over /storage/v1/object/public/<bucket>/<path> without consulting
--    storage.objects RLS, so a public read path exists with no SELECT policy.
--    Staging relies on this and carries no SELECT policy; migration 015's own
--    comment states it directly: "Public buckets can serve public URLs without
--    a broad SELECT policy."
--
--    Consequence to be aware of: object URLs are effectively unguessable-but-
--    public. Service images are non-sensitive, so this is appropriate. Do not
--    place anything confidential in app-images.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. Ownership / grants
--
--    storage.objects and storage.buckets are owned by supabase_storage_admin
--    and are created by the platform. No ownership change is attempted and no
--    grants are issued: production's platform defaults for the storage schema
--    were verified on 2026-07-30 and already grant postgres, anon,
--    authenticated and service_role the same privileges staging has
--    (TABLES arwdDxtm, SEQUENCES rwU, FUNCTIONS X, granted by postgres).
-- ---------------------------------------------------------------------------


-- ============================================================================
-- Verification after applying (expect exactly these):
--
--   select id, public, file_size_limit, allowed_mime_types
--     from storage.buckets where id = 'app-images';
--   -- app-images | t | 5242880 | {image/jpeg,image/png,image/webp}
--
--   select polname, polcmd from pg_policy p
--     join pg_class c on c.oid = p.polrelid
--     join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'storage' and c.relname = 'objects'
--    order by polname;
--   -- app_images_staff_delete | d
--   -- app_images_staff_insert | a
--   -- app_images_staff_update | w
--
--   select count(*) from storage.objects;   -- expect 0 (no files copied)
-- ============================================================================
