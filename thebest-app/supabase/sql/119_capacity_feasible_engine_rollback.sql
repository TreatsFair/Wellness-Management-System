-- 119_capacity_feasible_engine_rollback.sql
-- Drops the additive shadow engine. Safe at any time: these functions are wired
-- to nothing, so removing them cannot affect production behaviour.

begin;

drop function if exists public.capacity_feasible(uuid, jsonb, text, uuid, uuid);
drop function if exists public.capacity_bipartite_saturates(jsonb);
drop function if exists public.capacity_kuhn_augment(text, jsonb, jsonb, jsonb);

commit;
