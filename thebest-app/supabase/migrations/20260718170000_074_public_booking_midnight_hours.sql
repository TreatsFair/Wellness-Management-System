-- Treat a closing time at or before opening as the next-day boundary.
-- This keeps daytime and overnight public availability working when an outlet
-- closes at midnight (00:00) and when therapist hours inherit that closing time.

do $migration$
declare
  v_definition text;
  v_original text;
begin
  v_definition := pg_get_functiondef(
    'public.get_public_booking_slots_v2(uuid,date,text)'::regprocedure
  );
  v_original := v_definition;

  v_definition := replace(
    v_definition,
    $old$
  v_close time;
$old$,
    $new$
  v_close time;
  v_close_at timestamp;
$new$
  );

  v_definition := replace(
    v_definition,
    $old$
    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);
    v_close := least(v_window.end_time, v_settings.public_close_time, v_business.close_time);
    if v_close <= v_open then continue; end if;
$old$,
    $new$
    v_open := greatest(v_window.start_time, v_settings.public_open_time, v_business.open_time);
    v_close_at := least(
      p_date + v_window.end_time
        + case when v_window.end_time <= v_window.start_time then interval '1 day' else interval '0' end,
      p_date + v_settings.public_close_time
        + case when v_settings.public_close_time <= v_settings.public_open_time then interval '1 day' else interval '0' end,
      p_date + v_business.close_time
        + case when v_business.close_time <= v_business.open_time then interval '1 day' else interval '0' end
    );
    if v_close_at <= p_date + v_open then continue; end if;
$new$
  );

  v_definition := replace(
    v_definition,
    $old$
    ) <= p_date + v_close loop
$old$,
    $new$
    ) <= v_close_at loop
$new$
  );

  v_definition := replace(
    v_definition,
    $old$
            and p_date + wh.end_time >= v_block_end_local
$old$,
    $new$
            and p_date + wh.end_time
              + case when wh.end_time <= wh.start_time then interval '1 day' else interval '0' end
              >= v_block_end_local
$new$
  );

  if v_definition = v_original
     or position('v_close_at timestamp;' in v_definition) = 0
     or position(') <= v_close_at loop' in v_definition) = 0
     or position('case when wh.end_time <= wh.start_time' in v_definition) = 0 then
    raise exception 'get_public_booking_slots_v2 did not match the expected deployed definition';
  end if;

  execute v_definition;
end
$migration$;
