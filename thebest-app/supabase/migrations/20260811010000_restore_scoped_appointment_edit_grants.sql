-- Restore the minimum column privileges required by the current staff
-- appointment editor. Migration 20260801190822 intentionally revoked broad
-- direct INSERT/UPDATE access, but the Flutter edit flow still saves these
-- non-lifecycle fields through PostgREST after CSP has validated scheduling.
--
-- Row access remains constrained by appointments_update_staff_admin. This
-- migration does not grant payment_status or any scheduling/lifecycle column.
-- Existing financial-field triggers continue to rebuild catalogue-derived
-- service details and totals before accepting a staff update.

grant update (
  customer_id,
  service_id,
  service_name,
  service_items,
  item_count,
  total_price,
  type,
  notes
) on table public.appointments to authenticated;
