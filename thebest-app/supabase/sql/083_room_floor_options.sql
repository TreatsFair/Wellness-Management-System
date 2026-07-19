-- Keep room floors aligned with the two physical floor groups used by the app.
-- Legacy non-ground values are grouped into Upper before the enum is replaced.
create type public.room_floor_v2 as enum ('Ground', 'Upper');

alter table public.rooms
  alter column floor type public.room_floor_v2
  using (
    case
      when floor::text = 'Ground' then 'Ground'
      else 'Upper'
    end::public.room_floor_v2
  );

drop type public.room_floor;
alter type public.room_floor_v2 rename to room_floor;

comment on type public.room_floor is
  'Physical floor grouping for rooms: Ground or Upper.';
