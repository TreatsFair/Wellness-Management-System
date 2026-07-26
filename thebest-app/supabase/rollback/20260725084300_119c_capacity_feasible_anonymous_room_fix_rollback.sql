-- Rollback for 119c. Safe only while the Project B flag is OFF and before
-- later migrations depend on the wrapper's anonymous-room accounting.

begin;

drop function if exists public.capacity_feasible(
  uuid, jsonb, text, uuid, uuid
);

alter function public.capacity_feasible_119b_legacy(
  uuid, jsonb, text, uuid, uuid
) rename to capacity_feasible;

-- Deployed ACL for capacity_feasible is postgres-only; reassert it.
revoke all on function public.capacity_feasible(
  uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated, service_role;

commit;
