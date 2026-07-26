-- Today-only therapist queue management.
--
-- queue_position is the single persisted order for the current business day.
-- Permanent therapists.display_order values remain untouched. A consumed turn
-- moves that therapist to the bottom through a trigger on turn_consumed_at.

alter table public.therapist_queue_day
  add column if not exists first_turn_consumed_at timestamptz,
  add column if not exists is_manual_override boolean not null default false,
  add column if not exists changed_by uuid,
  add column if not exists changed_at timestamptz,
  add column if not exists override_reason text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'therapist_queue_day_override_reason_length_check'
      and conrelid = 'public.therapist_queue_day'::regclass
  ) then
    alter table public.therapist_queue_day
      add constraint therapist_queue_day_override_reason_length_check
      check (override_reason is null or char_length(override_reason) <= 500);
  end if;
end $$;

-- Backfill the explicit first-turn marker. Actual service starts are used only
-- when legacy/reseeded queue rows no longer retain a consumed timestamp.
update public.therapist_queue_day day_state
set first_turn_consumed_at = coalesce(
  (
    select min(queue_row.turn_consumed_at)
    from public.therapist_queue queue_row
    where queue_row.outlet_id = day_state.outlet_id
      and queue_row.queue_date = day_state.queue_date
      and queue_row.turn_consumed_at is not null
  ),
  (
    select min(appointment.actual_started_at)
    from public.appointments appointment
    where appointment.outlet_id = day_state.outlet_id
      and appointment.appointment_date = day_state.queue_date
      and appointment.actual_started_at is not null
      and lower(appointment.status::text) not in (
        'cancelled', 'canceled', 'no_show', 'no-show', 'noshow'
      )
      and lower(coalesce(appointment.payment_status::text, '')) <> 'voided'
  )
)
where day_state.first_turn_consumed_at is null;

-- Convert the previous composite order (unconsumed first, then consumed time)
-- into queue_position so there remains exactly one persisted order field.
with ranked as (
  select
    queue_row.outlet_id,
    queue_row.queue_date,
    queue_row.therapist_id,
    row_number() over (
      partition by queue_row.outlet_id, queue_row.queue_date
      order by
        queue_row.protected_turn_owed desc,
        queue_row.turn_consumed_at nulls first,
        queue_row.queue_position,
        queue_row.therapist_id
    )::integer as live_position
  from public.therapist_queue queue_row
)
update public.therapist_queue queue_row
set queue_position = -ranked.live_position
from ranked
where queue_row.outlet_id = ranked.outlet_id
  and queue_row.queue_date = ranked.queue_date
  and queue_row.therapist_id = ranked.therapist_id;

update public.therapist_queue
set queue_position = -queue_position
where queue_position < 0;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'therapist_queue_day_position_unique'
      and conrelid = 'public.therapist_queue'::regclass
  ) then
    alter table public.therapist_queue
      add constraint therapist_queue_day_position_unique
      unique (outlet_id, queue_date, queue_position)
      deferrable initially deferred;
  end if;
end $$;

create or replace function public.record_therapist_queue_turn_consumption()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last_position integer;
begin
  if new.turn_consumed_at is null
     or old.turn_consumed_at is not distinct from new.turn_consumed_at then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(new.outlet_id::text || ':' || new.queue_date::text, 0)
  );

  select coalesce(max(queue_position), new.queue_position)
  into v_last_position
  from public.therapist_queue
  where outlet_id = new.outlet_id
    and queue_date = new.queue_date;

  update public.therapist_queue queue_row
  set queue_position = queue_row.queue_position - 1
  where queue_row.outlet_id = new.outlet_id
    and queue_row.queue_date = new.queue_date
    and queue_row.therapist_id <> new.therapist_id
    and queue_row.queue_position > old.queue_position;

  new.queue_position := v_last_position;

  update public.therapist_queue_day
  set first_turn_consumed_at = coalesce(
    first_turn_consumed_at,
    new.turn_consumed_at
  )
  where outlet_id = new.outlet_id
    and queue_date = new.queue_date;

  return new;
end;
$$;

revoke all on function public.record_therapist_queue_turn_consumption()
  from public, anon, authenticated;

drop trigger if exists therapist_queue_rotate_consumed_turn
  on public.therapist_queue;
create trigger therapist_queue_rotate_consumed_turn
before update of turn_consumed_at on public.therapist_queue
for each row execute function public.record_therapist_queue_turn_consumption();

-- The live RPC keeps its existing signature. queue_position now carries the
-- current daily order directly; protected turns remain the only temporary
-- priority above that order.
create or replace function public.get_therapist_queue(
  p_outlet_id uuid,
  p_date date,
  p_now_time time,
  p_duration integer
)
returns table (
  therapist_id uuid,
  name text,
  gender text,
  queue_position integer,
  status text,
  free_at time,
  free_in_minutes integer,
  protected_turn_owed boolean,
  is_recommended boolean,
  rotation_rank bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  return query
  with avail as (
    select availability.therapist_id,
           availability.status,
           availability.free_at,
           availability.free_in_minutes
    from public.get_walkin_therapist_availability(
      p_date, p_now_time, greatest(p_duration, 1)
    ) availability
  ),
  ordered as (
    select
      queue_row.therapist_id,
      therapist.name,
      therapist.gender,
      queue_row.queue_position,
      avail.status,
      avail.free_at,
      avail.free_in_minutes,
      queue_row.protected_turn_owed,
      row_number() over (
        order by
          queue_row.protected_turn_owed desc,
          queue_row.queue_position,
          queue_row.therapist_id
      ) as rotation_rank
    from public.therapist_queue queue_row
    join public.therapists therapist
      on therapist.id = queue_row.therapist_id
    join avail on avail.therapist_id = queue_row.therapist_id
    where queue_row.outlet_id = p_outlet_id
      and queue_row.queue_date = p_date
      and therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
  )
  select
    ordered.therapist_id,
    ordered.name,
    ordered.gender,
    ordered.queue_position,
    ordered.status,
    ordered.free_at,
    ordered.free_in_minutes,
    ordered.protected_turn_owed,
    ordered.rotation_rank = (
      select min(candidate.rotation_rank)
      from ordered candidate
      where candidate.status = 'free_now'
    ) as is_recommended,
    ordered.rotation_rank
  from ordered
  order by ordered.rotation_rank;
end;
$$;

revoke all on function public.get_therapist_queue(uuid, date, time, integer)
  from public, anon;
grant execute on function public.get_therapist_queue(uuid, date, time, integer)
  to authenticated;

create or replace function public.automatic_therapist_queue_starter(
  p_outlet_id uuid,
  p_date date
)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_day_of_week integer := extract(dow from p_date)::integer;
  v_previous_order integer := -1;
  v_starter_id uuid;
begin
  select coalesce(therapist.display_order, -1)
  into v_previous_order
  from public.therapist_queue_day previous_day
  left join public.therapists therapist
    on therapist.id = previous_day.starter_therapist_id
  where previous_day.outlet_id = p_outlet_id
    and previous_day.queue_date < p_date
  order by previous_day.queue_date desc
  limit 1;

  if not found then v_previous_order := -1; end if;

  select therapist.id
  into v_starter_id
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and therapist.display_order > v_previous_order
    and exists (
      select 1
      from public.therapist_working_hours working_hours
      join public.business_hours outlet_hours
        on outlet_hours.outlet_id = therapist.outlet_id
       and outlet_hours.day_of_week = working_hours.day_of_week
       and not coalesce(outlet_hours.is_closed, false)
      where working_hours.therapist_id = therapist.id
        and working_hours.day_of_week = v_day_of_week
    )
  order by therapist.display_order, therapist.name
  limit 1;

  if v_starter_id is null then
    select therapist.id
    into v_starter_id
    from public.therapists therapist
    where therapist.outlet_id = p_outlet_id
      and coalesce(therapist.availability_status, true)
      and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
      and exists (
        select 1
        from public.therapist_working_hours working_hours
        join public.business_hours outlet_hours
          on outlet_hours.outlet_id = therapist.outlet_id
         and outlet_hours.day_of_week = working_hours.day_of_week
         and not coalesce(outlet_hours.is_closed, false)
        where working_hours.therapist_id = therapist.id
          and working_hours.day_of_week = v_day_of_week
      )
    order by therapist.display_order, therapist.name
    limit 1;
  end if;

  return v_starter_id;
end;
$$;

revoke all on function public.automatic_therapist_queue_starter(uuid, date)
  from public, anon, authenticated;

create or replace function public.rebuild_therapist_queue_from_starter(
  p_outlet_id uuid,
  p_date date,
  p_starter_therapist_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day_of_week integer := extract(dow from p_date)::integer;
  v_starter_order integer;
begin
  select therapist.display_order
  into v_starter_order
  from public.therapists therapist
  where therapist.id = p_starter_therapist_id
    and therapist.outlet_id = p_outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and exists (
      select 1
      from public.therapist_working_hours working_hours
      join public.business_hours outlet_hours
        on outlet_hours.outlet_id = therapist.outlet_id
       and outlet_hours.day_of_week = working_hours.day_of_week
       and not coalesce(outlet_hours.is_closed, false)
      where working_hours.therapist_id = therapist.id
        and working_hours.day_of_week = v_day_of_week
    );

  if v_starter_order is null then
    raise exception using
      errcode = '22023',
      message = 'The selected starter is not an active scheduled therapist for this outlet today.';
  end if;

  delete from public.therapist_queue
  where outlet_id = p_outlet_id and queue_date = p_date;

  insert into public.therapist_queue (
    outlet_id, queue_date, therapist_id, queue_position
  )
  select
    p_outlet_id,
    p_date,
    therapist.id,
    row_number() over (
      order by
        case when therapist.display_order >= v_starter_order then 0 else 1 end,
        therapist.display_order,
        therapist.name
    )::integer
  from public.therapists therapist
  where therapist.outlet_id = p_outlet_id
    and coalesce(therapist.availability_status, true)
    and lower(coalesce(therapist.role, 'therapist')) = 'therapist'
    and exists (
      select 1
      from public.therapist_working_hours working_hours
      join public.business_hours outlet_hours
        on outlet_hours.outlet_id = therapist.outlet_id
       and outlet_hours.day_of_week = working_hours.day_of_week
       and not coalesce(outlet_hours.is_closed, false)
      where working_hours.therapist_id = therapist.id
        and working_hours.day_of_week = v_day_of_week
    );
end;
$$;

revoke all on function public.rebuild_therapist_queue_from_starter(
  uuid, date, uuid
) from public, anon, authenticated;

create or replace function public.seed_therapist_queue(
  p_outlet_id uuid,
  p_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_starter_id uuid;
begin
  if exists (
    select 1 from public.therapist_queue_day
    where outlet_id = p_outlet_id and queue_date = p_date
  ) then
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );

  if exists (
    select 1 from public.therapist_queue_day
    where outlet_id = p_outlet_id and queue_date = p_date
  ) then
    return;
  end if;

  v_starter_id := public.automatic_therapist_queue_starter(
    p_outlet_id, p_date
  );
  if v_starter_id is null then return; end if;

  insert into public.therapist_queue_day (
    outlet_id, queue_date, starter_therapist_id
  ) values (p_outlet_id, p_date, v_starter_id);

  perform public.rebuild_therapist_queue_from_starter(
    p_outlet_id, p_date, v_starter_id
  );
end;
$$;

revoke all on function public.seed_therapist_queue(uuid, date)
  from public, anon, authenticated;

create or replace function public.today_queue_has_started(
  p_outlet_id uuid,
  p_date date
)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select day_state.first_turn_consumed_at
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    (
      select min(appointment.actual_started_at)
      from public.appointments appointment
      where appointment.outlet_id = p_outlet_id
        and appointment.appointment_date = p_date
        and appointment.actual_started_at is not null
        and lower(appointment.status::text) not in (
          'cancelled', 'canceled', 'no_show', 'no-show', 'noshow'
        )
        and lower(coalesce(appointment.payment_status::text, '')) <> 'voided'
    )
  );
$$;

revoke all on function public.today_queue_has_started(uuid, date)
  from public, anon, authenticated;

create or replace function public.get_today_queue_management(
  p_outlet_id uuid,
  p_date date,
  p_now_time time
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;

  perform public.seed_therapist_queue(p_outlet_id, p_date);

  with live_queue as (
    select queue_entry.*, therapist.profile_image_url
    from public.get_therapist_queue(
      p_outlet_id, p_date, p_now_time, 1
    ) queue_entry
    join public.therapists therapist
      on therapist.id = queue_entry.therapist_id
  ),
  current_next as (
    select live_queue.*
    from live_queue
    order by
      case when live_queue.is_recommended then 0 else 1 end,
      live_queue.rotation_rank
    limit 1
  )
  select jsonb_build_object(
    'queue_date', p_date,
    'starter', (
      select jsonb_build_object(
        'therapist_id', starter.id,
        'name', starter.name,
        'profile_image_url', starter.profile_image_url
      )
      from public.therapist_queue_day day_state
      join public.therapists starter
        on starter.id = day_state.starter_therapist_id
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'is_manual_override', coalesce((
      select day_state.is_manual_override
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ), false),
    'changed_by', (
      select day_state.changed_by
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'changed_at', (
      select day_state.changed_at
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'reason', (
      select day_state.override_reason
      from public.therapist_queue_day day_state
      where day_state.outlet_id = p_outlet_id
        and day_state.queue_date = p_date
    ),
    'first_turn_consumed_at', public.today_queue_has_started(
      p_outlet_id, p_date
    ),
    'requires_reset_warning', public.today_queue_has_started(
      p_outlet_id, p_date
    ) is not null,
    'current_next', (
      select jsonb_build_object(
        'therapist_id', current_next.therapist_id,
        'name', current_next.name,
        'profile_image_url', current_next.profile_image_url,
        'status', current_next.status
      )
      from current_next
    ),
    'live_queue', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'therapist_id', live_queue.therapist_id,
          'name', live_queue.name,
          'gender', live_queue.gender,
          'profile_image_url', live_queue.profile_image_url,
          'queue_position', live_queue.queue_position,
          'status', live_queue.status,
          'free_at', live_queue.free_at,
          'protected_turn_owed', live_queue.protected_turn_owed,
          'is_recommended', live_queue.is_recommended,
          'rotation_rank', live_queue.rotation_rank
        ) order by live_queue.rotation_rank
      )
      from live_queue
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_today_queue_management(uuid, date, time)
  from public, anon;
grant execute on function public.get_today_queue_management(uuid, date, time)
  to authenticated;

create or replace function public.change_today_queue_starter(
  p_outlet_id uuid,
  p_date date,
  p_starter_therapist_id uuid,
  p_reason text default null,
  p_confirm_reset boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_first_turn timestamptz;
  v_now_time time := (now() at time zone 'Asia/Kuala_Lumpur')::time;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = '22023',
      message = 'Only today''s live queue can be changed.';
  end if;
  if char_length(coalesce(p_reason, '')) > 500 then
    raise exception using errcode = '22023',
      message = 'Reason must be 500 characters or fewer.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  if not exists (
    select 1
    from public.get_therapist_queue(
      p_outlet_id, p_date, v_now_time, 1
    ) live_queue
    where live_queue.therapist_id = p_starter_therapist_id
  ) then
    raise exception using errcode = '22023',
      message = 'Choose an active therapist who is currently scheduled and on shift.';
  end if;

  v_first_turn := public.today_queue_has_started(p_outlet_id, p_date);
  if v_first_turn is not null and not p_confirm_reset then
    raise exception using errcode = 'P0001',
      message = 'RESET_CONFIRMATION_REQUIRED';
  end if;

  update public.therapist_queue_day
  set starter_therapist_id = p_starter_therapist_id,
      is_manual_override = true,
      changed_by = auth.uid(),
      changed_at = now(),
      override_reason = nullif(btrim(p_reason), '')
  where outlet_id = p_outlet_id and queue_date = p_date;

  perform public.rebuild_therapist_queue_from_starter(
    p_outlet_id, p_date, p_starter_therapist_id
  );
end;
$$;

revoke all on function public.change_today_queue_starter(
  uuid, date, uuid, text, boolean
) from public, anon;
grant execute on function public.change_today_queue_starter(
  uuid, date, uuid, text, boolean
) to authenticated;

create or replace function public.reorder_current_therapist_queue(
  p_outlet_id uuid,
  p_date date,
  p_therapist_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_time time := (now() at time zone 'Asia/Kuala_Lumpur')::time;
  v_expected_count integer;
  v_supplied_count integer := coalesce(cardinality(p_therapist_ids), 0);
  v_position_slots integer[];
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = '22023',
      message = 'Only today''s live queue can be reordered.';
  end if;
  if v_supplied_count = 0 then
    raise exception using errcode = '22023',
      message = 'Provide the current live therapist order.';
  end if;
  if (
    select count(distinct supplied.id)
    from unnest(p_therapist_ids) supplied(id)
  ) <> v_supplied_count then
    raise exception using errcode = '22023',
      message = 'Each live therapist must appear exactly once.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  select count(*)
  into v_expected_count
  from public.get_therapist_queue(
    p_outlet_id, p_date, v_now_time, 1
  );

  if v_expected_count <> v_supplied_count
     or exists (
       select 1
       from unnest(p_therapist_ids) supplied(id)
       where not exists (
         select 1
         from public.get_therapist_queue(
           p_outlet_id, p_date, v_now_time, 1
         ) live_queue
         where live_queue.therapist_id = supplied.id
       )
     ) then
    raise exception using errcode = '22023',
      message = 'The live queue changed. Refresh it before saving the new order.';
  end if;

  perform 1
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
  order by queue_row.queue_position, queue_row.therapist_id
  for update;

  select array_agg(queue_row.queue_position order by queue_row.queue_position)
  into v_position_slots
  from public.therapist_queue queue_row
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
    and queue_row.therapist_id = any(p_therapist_ids);

  update public.therapist_queue queue_row
  set queue_position = -100000 - supplied.ordinality::integer,
      protected_turn_owed = false,
      protected_turn_reason = null
  from unnest(p_therapist_ids) with ordinality supplied(id, ordinality)
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
    and queue_row.therapist_id = supplied.id;

  update public.therapist_queue queue_row
  set queue_position = requested.queue_position
  from unnest(p_therapist_ids, v_position_slots)
    requested(id, queue_position)
  where queue_row.outlet_id = p_outlet_id
    and queue_row.queue_date = p_date
    and queue_row.therapist_id = requested.id;
end;
$$;

revoke all on function public.reorder_current_therapist_queue(
  uuid, date, uuid[]
) from public, anon;
grant execute on function public.reorder_current_therapist_queue(
  uuid, date, uuid[]
) to authenticated;

create or replace function public.reset_today_queue_to_automatic(
  p_outlet_id uuid,
  p_date date,
  p_reason text default null,
  p_confirm_reset boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_starter_id uuid;
  v_first_turn timestamptz;
begin
  if auth.uid() is null or not public.is_staff_or_admin() then
    raise exception 'Not authorised';
  end if;
  if p_date <> (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception using errcode = '22023',
      message = 'Only today''s live queue can be reset.';
  end if;
  if char_length(coalesce(p_reason, '')) > 500 then
    raise exception using errcode = '22023',
      message = 'Reason must be 500 characters or fewer.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_outlet_id::text || ':' || p_date::text, 0)
  );
  perform public.seed_therapist_queue(p_outlet_id, p_date);

  v_first_turn := public.today_queue_has_started(p_outlet_id, p_date);
  if v_first_turn is not null and not p_confirm_reset then
    raise exception using errcode = 'P0001',
      message = 'RESET_CONFIRMATION_REQUIRED';
  end if;

  v_starter_id := public.automatic_therapist_queue_starter(
    p_outlet_id, p_date
  );
  if v_starter_id is null then
    raise exception using errcode = '22023',
      message = 'No active therapist is scheduled for this outlet today.';
  end if;

  update public.therapist_queue_day
  set starter_therapist_id = v_starter_id,
      is_manual_override = false,
      changed_by = auth.uid(),
      changed_at = now(),
      override_reason = nullif(btrim(p_reason), '')
  where outlet_id = p_outlet_id and queue_date = p_date;

  perform public.rebuild_therapist_queue_from_starter(
    p_outlet_id, p_date, v_starter_id
  );
end;
$$;

revoke all on function public.reset_today_queue_to_automatic(
  uuid, date, text, boolean
) from public, anon;
grant execute on function public.reset_today_queue_to_automatic(
  uuid, date, text, boolean
) to authenticated;

comment on column public.therapist_queue.queue_position is
  'Current base order for this outlet business date; consumed turns rotate to the bottom.';
comment on column public.therapist_queue_day.first_turn_consumed_at is
  'First queue turn consumed on this business date; remains set after manual resets.';
comment on column public.therapist_queue_day.is_manual_override is
  'Whether today''s stored starter was manually selected instead of automatic.';
