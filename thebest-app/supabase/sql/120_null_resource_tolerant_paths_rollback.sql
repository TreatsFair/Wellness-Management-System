-- 120_null_resource_tolerant_paths_rollback.sql
-- Restores the pre-120 (verbatim live) bodies of the two functions. Only safe
-- when no anonymous rows exist, since these bodies assume non-null room_id /
-- therapist_id. Re-concretise first if anonymous rows are present.

begin;

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
  if (select allocation_mode from public.rooms where id = new.room_id) <> 'specific_room' then
    new.room_unit_id := null;
    new.room_unit_name := '';
    return new;
  end if;
  v_start := public.csp_start_at(new.appointment_date, new.start_time);
  v_block_end := public.csp_end_at(new.appointment_date, new.start_time, new.end_time)
    + make_interval(mins => greatest(coalesce(new.buffer_after_minutes, 0), 0));
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
        public.csp_end_at(new.appointment_date, new.start_time, new.end_time)
    order by h.updated_at desc nulls last, h.created_at desc
    limit 1;
  end if;
  new.room_unit_id := public.allocate_specific_room_unit(
    new.room_id, v_start, v_block_end, new.room_unit_id, new.id, v_hold_id
  );
  select name into new.room_unit_name from public.room_units where id = new.room_unit_id;
  return new;
end;
$function$;

create or replace function public.consume_queue_on_appointment_start()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.actual_started_at is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.actual_started_at is not null then
    return new;
  end if;

  if lower(coalesce(new.status::text, '')) in (
       'cancelled', 'canceled', 'no_show', 'no-show', 'noshow'
     )
     or lower(coalesce(new.payment_status::text, '')) = 'voided' then
    return new;
  end if;

  perform public.consume_therapist_queue_turn_for_start(
    new.outlet_id,
    new.appointment_date,
    new.therapist_id,
    new.actual_started_at,
    new.id
  );

  return new;
end;
$function$;

commit;
