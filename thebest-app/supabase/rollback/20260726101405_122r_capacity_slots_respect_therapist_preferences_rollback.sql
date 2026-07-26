-- LOCAL rollback. Not executed.
drop function if exists public.allocate_preference_provisional_slots(
  uuid, date, time, jsonb, uuid
);
drop function if exists public.get_counter_preference_capacity_slots(
  uuid, date, jsonb, uuid, uuid
);
