-- LOCAL rollback for 20260726085754_122q_atomic_finalize_and_start.sql.
-- Not executed. Dropping guest columns discards locally stored per-pax details.

drop function if exists public.create_staff_walkin_group_and_start_with_payment(
  uuid, text, integer, date, jsonb, text, text, text, uuid, text,
  numeric, numeric, numeric, text, text, text, text, timestamptz
);
drop function if exists public.create_staff_walkin_and_start_with_payment(
  uuid, uuid, uuid, uuid, uuid, date, time, time, numeric, text, jsonb,
  integer, text, text, text, uuid, text, numeric, numeric, text, text, text,
  text, text, uuid, text, timestamptz
);
drop function if exists public.finalize_and_start_appointment_group(
  uuid, uuid[], text, text, jsonb, jsonb, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
);
drop function if exists public.finalize_and_start_appointment(
  uuid, text, text, text, text, jsonb, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz, uuid, text,
  numeric, numeric, numeric, text, text
);
drop function if exists public.finalize_and_start_appointment_core(
  uuid, text, text, text, text, jsonb, uuid, text, text,
  uuid, uuid, timestamptz, timestamptz
);

-- Restore the pre-122q, NULL-tolerant scheduled-window room-unit trigger body.
create or replace function public.assign_appointment_room_unit()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare
  v_start timestamp;
  v_block_end timestamp;
  v_hold_id uuid;
begin
  if new.room_id is null then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;
  if (select allocation_mode from public.rooms where id = new.room_id)
       <> 'specific_room' then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;
  v_start := public.csp_start_at(new.appointment_date, new.start_time);
  v_block_end := public.csp_end_at(
    new.appointment_date,
    new.start_time,
    new.end_time
  ) + make_interval(
    mins => greatest(coalesce(new.buffer_after_minutes, 0), 0)
  );
  if new.room_unit_id is null then
    select h.id, h.assigned_room_unit_id
    into v_hold_id, new.room_unit_id
    from public.booking_holds h
    where h.assigned_room_id = new.room_id
      and h.assigned_therapist_id = new.therapist_id
      and h.assigned_room_unit_id is not null
      and h.status not in ('expired', 'cancelled', 'failed')
      and (h.start_at at time zone 'Asia/Kuala_Lumpur') = v_start
      and (h.end_at at time zone 'Asia/Kuala_Lumpur') =
        public.csp_end_at(
          new.appointment_date,
          new.start_time,
          new.end_time
        )
    order by h.updated_at desc nulls last, h.created_at desc
    limit 1;
  end if;
  new.room_unit_id := public.allocate_specific_room_unit(
    new.room_id,
    v_start,
    v_block_end,
    new.room_unit_id,
    new.id,
    v_hold_id
  );
  select u.name
  into new.room_unit_name
  from public.room_units u
  where u.id = new.room_unit_id;
  return new;
end;
$function$;

alter table public.appointments
  drop column if exists guest_phone,
  drop column if exists guest_name;
