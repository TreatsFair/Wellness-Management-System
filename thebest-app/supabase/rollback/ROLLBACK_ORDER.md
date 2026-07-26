# Phase 6B.1 rollback order

These files live **outside** `supabase/migrations/` on purpose. They are never
picked up by `supabase db push` and must never be run during a normal, successful
deployment. Run them only to undo Phase 6B.1.

## Preconditions

* `capacity_first_enabled` must be OFF for **every** outlet.
* There must be zero anonymous future appointments
  (`therapist_id IS NULL OR room_id IS NULL` on unstarted `pending`/`confirmed`
  rows). The 122d rollback enforces both of these itself and aborts otherwise.

## Order — strictly reverse of application

1. `20260725084813_122e_capacity_first_single_update_and_create_rollback.sql`
2. `20260725084600_122d_capacity_first_group_update_rollback.sql`
3. `20260725084300_119c_capacity_feasible_anonymous_room_fix_rollback.sql`

122e must go first because its wrappers call `capacity_feasible`, which 119c's
rollback renames. 119c must go last for the same reason.

## 122f / 122g

`122f` and `122g` are body-only corrections that removed writes to the
non-existent `appointments.is_provisional` column. They have **no separate
rollback**: undoing them would restore a body that cannot execute. Rolling back
122e and 122d discards those bodies entirely, which is the correct outcome.

## ACL note

Each rollback re-grants EXECUTE to `authenticated` after renaming a legacy
function back to its public name. This is required: the forward migrations
revoked every client role from the `*_legacy` names, and `ALTER FUNCTION ...
RENAME` carries the ACL with the function. Without the re-grant the restored
RPC would be callable only by `postgres` and the Flutter app would break.

Target ACL after any rollback (matching the pre-Phase-6B.1 deployed state):

| function | ACL |
| --- | --- |
| `capacity_feasible` | `postgres` only |
| `create_appointment_with_csp` | `postgres`, `authenticated` |
| `update_appointment_with_csp` | `postgres`, `authenticated` |
| `update_appointment_group_with_csp` | `postgres`, `authenticated` |
