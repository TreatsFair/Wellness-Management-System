-- Complete midnight handling across group availability and final hold allocation.
-- The single-service slot generator was corrected in 074; these downstream
-- functions repeat the therapist working-hours boundary and need the same
-- next-day interpretation for an inherited 00:00 closing time.

do $migration$
declare
  v_group_definition text;
  v_group_original text;
  v_hold_definition text;
  v_hold_original text;
begin
  v_group_definition := pg_get_functiondef(
    'public.get_public_booking_group_slots_scan_v1(jsonb,date,boolean)'::regprocedure
  );
  v_group_original := v_group_definition;
  v_group_definition := replace(
    v_group_definition,
    $old$p_date + wh.end_time >= (v_be at time zone 'Asia/Kuala_Lumpur')$old$,
    $new$p_date + wh.end_time
              + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
              >= (v_be at time zone 'Asia/Kuala_Lumpur')$new$
  );

  if v_group_definition = v_group_original
     or position('case when wh.end_time <= wh.start_time' in v_group_definition) = 0 then
    raise exception 'get_public_booking_group_slots_scan_v1 did not match the expected deployed definition';
  end if;

  v_hold_definition := pg_get_functiondef(
    'public.create_public_booking_hold_v2(uuid,timestamptz,text,text,text,text,text,text,text)'::regprocedure
  );
  v_hold_original := v_hold_definition;
  v_hold_definition := replace(
    v_hold_definition,
    $old$v_local_start::date + wh.end_time >= (v_block_end at time zone 'Asia/Kuala_Lumpur')$old$,
    $new$v_local_start::date + wh.end_time
        + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
        >= (v_block_end at time zone 'Asia/Kuala_Lumpur')$new$
  );

  if v_hold_definition = v_hold_original
     or position('case when wh.end_time <= wh.start_time' in v_hold_definition) = 0 then
    raise exception 'create_public_booking_hold_v2 did not match the expected deployed definition';
  end if;

  execute v_group_definition;
  execute v_hold_definition;
end
$migration$;
