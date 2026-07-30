# Image migration manifest

**Status: PLAN ONLY.** No file has been downloaded, uploaded, or modified. No
Storage object exists in production yet.

Source project: `hvyzexmsaxwendcexehx` (STAGING, `ap-northeast-1`) — appears
here as provenance only, never in executable SQL.
Destination project: `erjttzhownsxohpvzjbs` (PRODUCTION, `ap-southeast-1`).
Destination bucket: **`app-images`** (created by `000002_storage.sql`).
Captured: 2026-07-30 from `storage.objects` metadata.

Object paths are **preserved byte-for-byte** from staging. Every service image
lives at `services/<service_id>/<epoch>.jpg`, and `000004_seed_configuration.sql`
preserves the five service UUIDs, so the paths remain valid and meaningful
without rewriting. Nothing needs renaming.

## The five selected Taman Wahyu service images

| # | Service ID | Service name | Staging bucket | Object path (identical in production) | MIME | Bytes |
|---|---|---|---|---|---|---|
| 1 | `83893724-c584-4603-b208-1db6db0b2ab0` | Foot Massage — RM39.00 / 50 min | `app-images` | `services/83893724-c584-4603-b208-1db6db0b2ab0/1784532121800.jpg` | `image/jpeg` | 279,442 |
| 2 | `a5f9c703-9d80-42a6-9282-449fbdb29d65` | Foot Massage — RM59.00 / 75 min | `app-images` | `services/a5f9c703-9d80-42a6-9282-449fbdb29d65/1784532229861.jpg` | `image/jpeg` | 279,442 |
| 3 | `edd2553e-9d98-45d2-9b89-c67a2c6444c8` | Foot Massage — RM78.00 / 90 min | `app-images` | `services/edd2553e-9d98-45d2-9b89-c67a2c6444c8/1784532261837.jpg` | `image/jpeg` | 279,442 |
| 4 | `4af490ba-064b-4fd4-85fd-9edba196a62d` | Traditional Body Massage — RM99.00 / 60 min | `app-images` | `services/4af490ba-064b-4fd4-85fd-9edba196a62d/1784532433657.jpg` | `image/jpeg` | 175,797 |
| 5 | `c5c786c0-7a5b-4cd4-84ac-b8c7f83986dd` | Traditional Body Massage — RM129.00 / 80 min | `app-images` | `services/c5c786c0-7a5b-4cd4-84ac-b8c7f83986dd/1784532464920.jpg` | `image/jpeg` | 175,797 |

Service #5's name is spelt `Traditional` here and in `000004`; staging's record
was misspelt `Traditonal` and the spelling was corrected at source in Stage 3D.
The object path is unchanged — it is keyed on the UUID, not the name.

All five satisfy the `000002` bucket constraints: `image/jpeg` is in the allowed
MIME list, and the largest file (279,442 B) is well under the 5,242,880 B limit.

> **Duplicate images — accepted, decision closed.** Files 1-3 are all exactly
> **279,442 bytes** and files 4-5 both exactly **175,797 bytes**, so these are
> almost certainly two photographs uploaded five times. The product owner has
> accepted duplicates for launch: the three Foot Massage cards will show the same
> picture at three prices, and the two Traditional Body Massage cards likewise.
> All five files are still migrated individually so each service keeps its own
> object path and can be given a distinct image later without touching the
> database wiring. Checksums in step 2 will record the duplication for the file.

## Business logo

| Item | Value |
|---|---|
| Source path | `business/logo/1782894757128.png` |
| Destination path | `business/logo/1782894757128.png` (unchanged) |
| Bucket | `app-images` → `app-images` |
| MIME | `image/png` |
| Bytes | 131,114 |
| Created in staging | 2026-07-01 |
| Destination DB field | `public.settings.logo_url` (id = `business`) |

Included because the business identity is real and this is the current logo in
use. `000004` seeds `settings.logo_url` as `NULL`, so it is written only after
the object exists in production.

## Objects deliberately NOT migrated (13 of 19)

| Path pattern | Count | Reason |
|---|---|---|
| `online-booking/<uuid>/*.png` | 9 | Belong to the excluded `(Online Exclusive) …` services and the mislinked PV128 card. 1.7-1.9 MB each. The five production cards reuse their **service** image instead of a second copy — `000004` sets both `services.image_url` and `online_booking_services.public_image_url` to the same migrated URL. |
| `services/096141fa-…/1782896063198.jpg` | 1 | PV128 service, not among the selected five |
| `services/096141fa-…/1782897780486.png` | 1 | Superseded upload for the same PV128 service |
| `services/f3e88593-…/1782896115999.jpg` | 1 | PV128 service (the one carrying staging's 22% commission override), not selected |
| `therapists/db01a5e3-…/1782897544451.jpg` | 1 | Placeholder therapist photo; no therapists are seeded |

Six objects migrate (5 service images + 1 logo), thirteen do not.

## Destination database fields to update

After the six objects exist in production, and only then:

| Table | Column | Rows | New value |
|---|---|---|---|
| `public.services` | `image_url` | 5 | `https://erjttzhownsxohpvzjbs.supabase.co/storage/v1/object/public/app-images/services/<service_id>/<file>.jpg` |
| `public.online_booking_services` | `public_image_url` | 5 | same URL as the matching service (card id mirrors service id 1:1) |
| `public.settings` | `logo_url` | 1 | `https://erjttzhownsxohpvzjbs.supabase.co/storage/v1/object/public/app-images/business/logo/1782894757128.png` |

11 column updates across 3 tables.

## Execution procedure (later stage — not now)

Prerequisite: `000002_storage.sql` applied, so the bucket and its MIME/size
limits exist.

1. Download the six objects from staging using the staging public URLs (the
   bucket is public, so no credentials are needed for reads).
2. Compute a SHA-256 checksum for each downloaded file and record it here.
3. Upload each to production `app-images` at the identical object path.
4. Verify the stored `metadata->>'mimetype'` and `metadata->>'size'` in
   production match the source table above exactly.
5. Compute SHA-256 of each object as served from the production public URL.
6. Confirm source and destination checksums match, file by file. Stop on any
   mismatch — do not update a database URL for a file that did not verify.
7. Update the 11 columns listed above.
8. Confirm no production row points at staging:
   ```sql
   select count(*) from public.services            where image_url        like '%hvyzex%';  -- 0
   select count(*) from public.online_booking_services
                                                   where public_image_url like '%hvyzex%';  -- 0
   select count(*) from public.settings            where logo_url         like '%hvyzex%';  -- 0
   ```
9. Fetch each production URL once and confirm HTTP 200 with the expected
   `Content-Type`.

`000004` uses `ON CONFLICT … DO UPDATE` clauses that deliberately **omit**
`image_url`, `public_image_url` and `logo_url`, so re-running the seed after this
migration will not blank the URLs.
