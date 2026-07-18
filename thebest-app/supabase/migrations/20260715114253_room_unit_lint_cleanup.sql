create index if not exists transactions_room_unit_id_idx
  on public.transactions(room_unit_id)
  where room_unit_id is not null;

drop policy if exists room_units_admin_all on public.room_units;

drop policy if exists room_units_admin_insert on public.room_units;
create policy room_units_admin_insert on public.room_units
for insert to authenticated
with check (public.is_admin());

drop policy if exists room_units_admin_update on public.room_units;
create policy room_units_admin_update on public.room_units
for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists room_units_admin_delete on public.room_units;
create policy room_units_admin_delete on public.room_units
for delete to authenticated
using (public.is_admin());

;
