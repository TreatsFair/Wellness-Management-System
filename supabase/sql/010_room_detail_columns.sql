alter table if exists public.rooms
  add column if not exists room_type text not null default 'body_room',
  add column if not exists floor text not null default 'Main Floor',
  add column if not exists total_slots integer not null default 1,
  add column if not exists equipment text not null default '';
