-- Staff slot suggestions use the outlet's configured interval and only label
-- true schedule-adjacency wins as recommended.
create or replace function public.get_available_slots(
  p_date date,
  p_therapist_id uuid,
  p_room_id uuid,
  p_duration integer,
  p_exclude_id uuid default null
)
returns table (
  start_time time,
  end_time time,
  classification text,
  score integer,
  reason text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_open time := '09:00'::time;
  v_close time := '21:00'::time;
  v_interval integer := 10;
  v_outlet_id uuid;
  v_start_at timestamp;
  v_end_at timestamp;
  v_close_at timestamp;
  v_now_local timestamp := (now() at time zone 'Asia/Kuala_Lumpur');
  v_check record;
  v_score integer;
  v_reason text;
  v_has_before boolean;
  v_has_after boolean;
  v_therapist_count numeric := 0;
  v_average_count numeric := 0;
begin
  if p_duration is null or p_duration <= 0 then return; end if;

  select t.outlet_id
  into v_outlet_id
  from public.therapists t
  join public.rooms r on r.id = p_room_id and r.outlet_id = t.outlet_id
  where t.id = p_therapist_id;

  if v_outlet_id is null then return; end if;

  select
    coalesce(bs.open_time, '09:00'::time),
    coalesce(bs.close_time, '21:00'::time),
    greatest(coalesce(obs.slot_interval_minutes, 10), 5)
  into v_open, v_close, v_interval
  from public.business_settings bs
  left join public.online_booking_outlet_settings obs
    on obs.outlet_id = bs.outlet_id
  where bs.outlet_id = v_outlet_id
  limit 1;

  v_open := coalesce(v_open, '09:00'::time);
  v_close := coalesce(v_close, '21:00'::time);
  v_interval := greatest(coalesce(v_interval, 10), 5);
  v_start_at := p_date + v_open;
  v_close_at := p_date + v_close
    + case when v_close <= v_open then interval '1 day' else interval '0' end;

  select count(*)
  into v_therapist_count
  from public.appointments a
  where a.appointment_date::date between p_date - 1 and p_date + 1
    and a.outlet_id = v_outlet_id
    and a.therapist_id = p_therapist_id
    and public.csp_blocks_schedule(a.status::text);

  select coalesce(avg(day_count), 0)
  into v_average_count
  from (
    select count(*)::numeric as day_count
    from public.appointments a
    where a.appointment_date::date = p_date
      and a.outlet_id = v_outlet_id
      and public.csp_blocks_schedule(a.status::text)
      and a.therapist_id is not null
    group by a.therapist_id
  ) counts;

  while v_start_at + make_interval(mins => p_duration) <= v_close_at loop
    v_end_at := v_start_at + make_interval(mins => p_duration);

    if v_start_at <= v_now_local then
      v_start_at := v_start_at + make_interval(mins => v_interval);
      continue;
    end if;

    select * into v_check
    from public.check_booking_availability(
      p_date,
      v_start_at::time,
      v_end_at::time,
      p_therapist_id,
      p_room_id,
      p_exclude_id
    );

    start_time := v_start_at::time;
    end_time := v_end_at::time;

    if not coalesce(v_check.therapist_available, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'therapist_conflict';
      return next;
    elsif coalesce(v_check.room_full, false) then
      classification := 'unavailable';
      score := 0;
      reason := 'room_full';
      return next;
    end if;

    select exists (
      select 1
      from public.appointments a
      where a.appointment_date::date between p_date - 1 and p_date + 1
        and a.outlet_id = v_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
        and public.csp_appointment_block_end_at(a) = v_start_at
        and (p_exclude_id is null or a.id <> p_exclude_id)
    ) into v_has_before;

    select exists (
      select 1
      from public.appointments a
      where a.appointment_date::date between p_date - 1 and p_date + 1
        and a.outlet_id = v_outlet_id
        and public.csp_blocks_schedule(a.status::text)
        and (a.therapist_id = p_therapist_id or a.room_id = p_room_id)
        and public.csp_appointment_start_at(a) = v_end_at
        and (p_exclude_id is null or a.id <> p_exclude_id)
    ) into v_has_after;

    if v_has_before and v_has_after then
      v_score := 300;
      v_reason := 'fills_between_bookings';
    elsif v_has_before then
      v_score := 200;
      v_reason := 'starts_after_booking';
    elsif v_has_after then
      v_score := 150;
      v_reason := 'ends_before_booking';
    elsif v_average_count > 0 and v_therapist_count < v_average_count then
      v_score := 10;
      v_reason := 'balances_workload';
    else
      v_score := 0;
      v_reason := 'standard_slot';
    end if;

    classification := case
      when v_has_before or v_has_after then 'recommended'
      else 'standard'
    end;
    score := v_score;
    reason := v_reason;
    return next;

    v_start_at := v_start_at + make_interval(mins => v_interval);
  end loop;
end;
$$;

-- Calculate commission from the services on one receipt. Group receipts resolve
-- each line's therapist through its appointment instead of using Pax 1.
create or replace function public.csp_commission_for_transaction_items(
  p_service_items jsonb,
  p_default_therapist_id uuid default null
)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v_item jsonb;
  v_appointment_id uuid;
  v_therapist_id uuid;
  v_total numeric := 0;
begin
  for v_item in
    select value from jsonb_array_elements(coalesce(p_service_items, '[]'::jsonb))
  loop
    v_appointment_id := nullif(coalesce(
      v_item ->> 'appointmentId', v_item ->> 'appointment_id'
    ), '')::uuid;
    v_therapist_id := nullif(coalesce(
      v_item ->> 'assignedTherapistId',
      v_item ->> 'assigned_therapist_id'
    ), '')::uuid;

    if v_therapist_id is null and v_appointment_id is not null then
      select a.therapist_id into v_therapist_id
      from public.appointments a where a.id = v_appointment_id;
    end if;
    v_therapist_id := coalesce(v_therapist_id, p_default_therapist_id);
    v_total := v_total + public.csp_commission_for_items(
      jsonb_build_array(v_item), v_therapist_id, 'Therapist'
    );
  end loop;
  return round(v_total, 2);
end;
$$;

create or replace function public.normalize_appointment_addon_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_owner_id uuid;
  v_first_owner_id uuid;
  v_multiple_owners boolean := false;
begin
  if new.source::text <> 'appointment_addon' then return new; end if;

  for v_item in
    select value from jsonb_array_elements(coalesce(new.service_items, '[]'::jsonb))
  loop
    v_owner_id := nullif(coalesce(
      v_item ->> 'appointmentId', v_item ->> 'appointment_id'
    ), '')::uuid;
    if v_owner_id is null then continue; end if;
    if v_first_owner_id is null then
      v_first_owner_id := v_owner_id;
    elsif v_first_owner_id <> v_owner_id then
      v_multiple_owners := true;
    end if;
  end loop;

  if v_first_owner_id is not null and not v_multiple_owners then
    new.appointment_id := v_first_owner_id;
    select
      a.therapist_id,
      coalesce(t.name, ''),
      a.room_id,
      coalesce(r.name, '')
    into new.therapist_id, new.therapist_name, new.room_id, new.room_name
    from public.appointments a
    left join public.therapists t on t.id = a.therapist_id
    left join public.rooms r on r.id = a.room_id
    where a.id = v_first_owner_id;
  elsif v_multiple_owners then
    new.appointment_id := null;
    new.therapist_id := null;
    new.therapist_name := 'Multiple therapists';
    new.room_id := null;
    new.room_name := 'Multiple rooms';
  end if;

  new.therapist_commission_amount :=
    public.csp_commission_for_transaction_items(
      new.service_items, new.therapist_id
    );
  return new;
end;
$$;

drop trigger if exists transactions_normalize_appointment_addon on public.transactions;
create trigger transactions_normalize_appointment_addon
before insert or update of service_items on public.transactions
for each row execute function public.normalize_appointment_addon_transaction();

create or replace function public.recalculate_appointment_therapist_commission(
  p_appointment_id uuid
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_primary_transaction public.transactions%rowtype;
  v_transaction public.transactions%rowtype;
  v_allocation record;
  v_amount numeric;
  v_total numeric := 0;
  v_group_incomplete boolean;
begin
  select * into v_appointment
  from public.appointments where id = p_appointment_id;
  if not found then return 0; end if;

  select * into v_primary_transaction
  from public.transactions t
  where t.payment_status = 'paid'
    and t.source::text <> 'appointment_addon'
    and (
      t.appointment_id = p_appointment_id
      or (
        v_appointment.appointment_group_id is not null
        and t.appointment_group_id = v_appointment.appointment_group_id
      )
    )
  order by t.created_at
  limit 1;
  if not found then return 0; end if;

  if not exists (
    select 1 from public.appointment_therapist_allocations
    where appointment_id = p_appointment_id
  ) then
    insert into public.appointment_therapist_allocations (
      appointment_id, therapist_id, commission_share, allocation_method, created_by
    ) values (
      p_appointment_id, v_appointment.therapist_id, 1, 'full', auth.uid()
    );
  end if;

  for v_allocation in
    select * from public.appointment_therapist_allocations
    where appointment_id = p_appointment_id
  loop
    v_amount := case
      when v_primary_transaction.source::text = 'online_booking'
        and v_appointment.status <> 'completed' then 0
      else round(
        public.csp_commission_for_items(
          coalesce(v_appointment.service_items, '[]'::jsonb),
          v_allocation.therapist_id,
          'Therapist'
        ) * v_allocation.commission_share,
        2
      )
    end;
    update public.appointment_therapist_allocations
    set commission_amount = v_amount
    where id = v_allocation.id;
  end loop;

  select coalesce(sum(ata.commission_amount), 0)
  into v_total
  from public.appointment_therapist_allocations ata
  where ata.appointment_id = p_appointment_id;

  for v_transaction in
    select * from public.transactions t
    where t.payment_status = 'paid'
      and (
        t.appointment_id = p_appointment_id
        or (
          v_appointment.appointment_group_id is not null
          and t.appointment_group_id = v_appointment.appointment_group_id
        )
      )
  loop
    v_group_incomplete := false;
    if v_transaction.source::text = 'online_booking' then
      if v_transaction.appointment_id is not null then
        select a.status <> 'completed' into v_group_incomplete
        from public.appointments a where a.id = v_transaction.appointment_id;
      elsif v_transaction.appointment_group_id is not null then
        select exists (
          select 1 from public.appointments a
          where a.appointment_group_id = v_transaction.appointment_group_id
            and a.status not in ('completed', 'cancelled', 'no_show')
        ) into v_group_incomplete;
      end if;
    end if;

    update public.transactions
    set therapist_commission_amount = case
          when v_group_incomplete then 0
          else public.csp_commission_for_transaction_items(
            v_transaction.service_items, v_transaction.therapist_id
          )
        end,
        updated_at = now()
    where id = v_transaction.id;
  end loop;

  return v_total;
end;
$$;

-- Repair existing group add-on receipts using their item-level appointment owner.
update public.transactions t
set service_items = t.service_items,
    updated_at = now()
where t.source::text = 'appointment_addon'
  and t.appointment_group_id is not null
  and jsonb_array_length(coalesce(t.service_items, '[]'::jsonb)) > 0;

revoke all on function public.csp_commission_for_transaction_items(jsonb, uuid)
  from public, anon;
grant execute on function public.csp_commission_for_transaction_items(jsonb, uuid)
  to authenticated, service_role;
