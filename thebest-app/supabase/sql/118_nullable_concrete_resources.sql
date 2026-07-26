-- 118_nullable_concrete_resources.sql
-- Phase 6A / Project B. Allow future appointments to hold ANONYMOUS capacity
-- demand by making the concrete resource ids nullable, while guaranteeing that a
-- STARTED or CONFIRMED appointment still carries concrete therapist + room.
--
-- This migration:
--   * creates NO anonymous rows,
--   * does NOT enable capacity-first,
--   * does NOT alter any Migration 116 function, trigger or Cron,
--   * is safe to apply while the feature flag is off (behaviour is unchanged;
--     the booking RPCs still write concrete ids until migration 121 is enabled).
--
-- room_unit_id is already nullable in production, so only therapist_id and
-- room_id are relaxed here.

begin;

-- 1. Relax NOT NULL on the two concrete resource ids. Foreign keys already
--    permit NULL (a NULL fk value is simply not checked), so no FK change.
alter table public.appointments alter column therapist_id drop not null;
alter table public.appointments alter column room_id      drop not null;

-- 2. Precise concreteness guards. CRITICAL: appointment `status = 'confirmed'`
--    means the BOOKING is confirmed, NOT that specific resources are confirmed.
--    A future confirmed appointment may be fully anonymous (therapist_id NULL,
--    room_id NULL, therapist/room assignment_state 'pending',
--    resources_confirmed_at NULL, actual_started_at NULL). Therefore `status =
--    'confirmed'` is deliberately NOT a trigger for requiring concrete resources.
--
--    (a) A CONFIRMED THERAPIST ASSIGNMENT requires a concrete therapist_id.
--        (Room may stay anonymous — e.g. exact requested therapist before start.)
--    (b) A CONFIRMED ROOM ASSIGNMENT requires a concrete room_id.
--        (Therapist may stay anonymous — e.g. manually locked room before start.)
--    (c) Once resources are confirmed, or the service has started, or the
--        appointment is in_progress/completed, BOTH therapist_id and room_id
--        must be concrete.
--
--    room_unit_id stays optional throughout (not every allocation uses a unit).
--
--    All three are added NOT VALID (brief catalog lock only) and VALIDATEd
--    separately. Verified pre-apply: 0 existing rows violate any of them.
alter table public.appointments
  add constraint appointments_confirmed_therapist_concrete
  check (
    therapist_assignment_state <> 'confirmed' or therapist_id is not null
  ) not valid;

alter table public.appointments
  add constraint appointments_confirmed_room_concrete
  check (
    room_assignment_state <> 'confirmed' or room_id is not null
  ) not valid;

alter table public.appointments
  add constraint appointments_started_requires_concrete
  check (
    not (
      (
        resources_confirmed_at is not null
        or actual_started_at is not null
        or status in ('in_progress', 'completed')
      )
      and (therapist_id is null or room_id is null)
    )
  ) not valid;

-- 3. Validate separately (ShareUpdateExclusive lock; scans existing rows).
alter table public.appointments
  validate constraint appointments_confirmed_therapist_concrete;
alter table public.appointments
  validate constraint appointments_confirmed_room_concrete;
alter table public.appointments
  validate constraint appointments_started_requires_concrete;

comment on constraint appointments_confirmed_therapist_concrete on public.appointments is
  'Project B: a confirmed THERAPIST assignment must carry a concrete therapist_id. status=confirmed (booking) does NOT imply this.';
comment on constraint appointments_confirmed_room_concrete on public.appointments is
  'Project B: a confirmed ROOM assignment must carry a concrete room_id. status=confirmed (booking) does NOT imply this.';
comment on constraint appointments_started_requires_concrete on public.appointments is
  'Project B: once resources_confirmed_at/actual_started_at is set or status is in_progress/completed, both therapist_id and room_id must be concrete. A future confirmed (booking) appointment may remain fully anonymous.';

commit;

-- Post-conditions to verify (see tests/phase6a_tests.sql):
--   * therapist_id / room_id are now nullable; room_unit_id already was.
--   * a future status='confirmed' row with NULL therapist_id/room_id and
--     assignment states 'pending' is ALLOWED.
--   * therapist_assignment_state='confirmed' with NULL therapist_id is rejected.
--   * room_assignment_state='confirmed' with NULL room_id is rejected.
--   * in_progress/completed | actual_started_at | resources_confirmed_at with a
--     NULL therapist_id or room_id is rejected.
--   * select count(*) from appointments where therapist_id is null or room_id is null  => 0
--     (this migration created no anonymous rows).
