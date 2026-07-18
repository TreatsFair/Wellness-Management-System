-- Restore online booking comments that were preserved on confirmed holds but
-- cleared from appointment records by an older group-edit payload.

with appointment_comments as (
  select distinct on (h.appointment_id)
    h.appointment_id,
    trim(h.notes) as notes
  from public.booking_holds h
  where h.appointment_id is not null
    and trim(coalesce(h.notes, '')) <> ''
  order by h.appointment_id, h.created_at desc
)
update public.appointments a
set notes = comments.notes
from appointment_comments comments
where a.id = comments.appointment_id
  and trim(coalesce(a.notes, '')) = '';

with group_comments as (
  select distinct on (h.appointment_group_id)
    h.appointment_group_id,
    trim(h.notes) as notes
  from public.booking_holds h
  where h.appointment_group_id is not null
    and trim(coalesce(h.notes, '')) <> ''
  order by h.appointment_group_id, h.created_at desc
)
update public.appointment_groups groups
set notes = comments.notes
from group_comments comments
where groups.id = comments.appointment_group_id
  and trim(coalesce(groups.notes, '')) = '';
