-- The room-aware overload replaces the original app RPC. Keeping both makes
-- PostgREST overload resolution harder and leaves the old lint issue active.
drop function if exists public.reserve_staff_walkin_allocation(
  text, integer, uuid, uuid, text, text, uuid, uuid, jsonb, date, time, time,
  numeric
);

-- Recreate the already-installed overload with its booking_holds column fully
-- qualified. The main migration contains the readable canonical definition;
-- this small follow-up also repairs databases where it was already applied.
do $$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.reserve_staff_walkin_allocation(text, integer, uuid, uuid, text, text, uuid, uuid, jsonb, date, time, time, numeric, uuid)'::regprocedure
  ) into v_definition;

  v_definition := replace(
    v_definition,
    'and expires_at <= now();',
    'and booking_holds.expires_at <= now();'
  );
  execute v_definition;
end;
$$;
