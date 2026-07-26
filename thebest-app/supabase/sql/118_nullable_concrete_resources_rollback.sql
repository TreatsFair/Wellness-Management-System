-- 118_nullable_concrete_resources_rollback.sql
-- Reverses 118. IMPORTANT: SET NOT NULL will FAIL (by design) if any anonymous
-- rows exist (therapist_id IS NULL or room_id IS NULL). Per the Project B rollback
-- strategy (design §19), you must first RE-CONCRETISE all anonymous future rows
-- before running this. This rollback is only valid when no anonymous rows exist
-- (e.g. rolling back before migration 121 was ever enabled).

begin;

-- Fail fast with a clear message if anonymous rows are present.
do $$
declare
  v_anon integer;
begin
  select count(*) into v_anon
  from public.appointments
  where therapist_id is null or room_id is null;
  if v_anon > 0 then
    raise exception
      'Cannot roll back 118: % appointment row(s) still have NULL therapist_id/room_id. Re-concretise them first (design §19) before restoring NOT NULL.',
      v_anon;
  end if;
end;
$$;

alter table public.appointments
  drop constraint if exists appointments_confirmed_therapist_concrete;
alter table public.appointments
  drop constraint if exists appointments_confirmed_room_concrete;
alter table public.appointments
  drop constraint if exists appointments_started_requires_concrete;

alter table public.appointments alter column therapist_id set not null;
alter table public.appointments alter column room_id      set not null;

commit;
