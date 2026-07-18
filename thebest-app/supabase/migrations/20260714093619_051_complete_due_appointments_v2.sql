create or replace function public.complete_due_appointments(
  p_outlet_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_expected_end timestamptz;
  v_updated integer := 0;
  v_transaction record;
  v_commission numeric;
begin
  for v_row in
    select a.*
    from public.appointments a
    where a.status = 'in_progress'
      and a.payment_status = 'paid'
      and a.actual_started_at is not null
      and (p_outlet_id is null or a.outlet_id = p_outlet_id)
    for update of a skip locked
  loop
    v_expected_end := greatest(
      v_row.actual_started_at + (
        coalesce(
          v_row.booked_end_at,
          (coalesce(v_row.booked_date, v_row.appointment_date) + coalesce(v_row.booked_end_time, v_row.end_time))
            at time zone 'Asia/Kuala_Lumpur',
          v_row.end_at at time zone 'Asia/Kuala_Lumpur'
        )
        - coalesce(
          v_row.booked_start_at,
          (coalesce(v_row.booked_date, v_row.appointment_date) + coalesce(v_row.booked_start_time, v_row.start_time))
            at time zone 'Asia/Kuala_Lumpur',
          v_row.start_at at time zone 'Asia/Kuala_Lumpur'
        )
      ),
      coalesce(
        v_row.end_at at time zone 'Asia/Kuala_Lumpur',
        v_row.booked_end_at,
        (coalesce(v_row.booked_date, v_row.appointment_date) + coalesce(v_row.booked_end_time, v_row.end_time))
          at time zone 'Asia/Kuala_Lumpur'
      )
    );

    if v_expected_end >= now() then
      continue;
    end if;

    update public.appointments
    set status = 'completed',
        actual_completed_at = v_expected_end,
        updated_at = now()
    where id = v_row.id;

    v_updated := v_updated + 1;
  end loop;

  for v_transaction in
    select t.id, t.appointment_id, t.appointment_group_id
    from public.transactions t
    where t.source = 'online_booking'
      and t.payment_status = 'paid'
      and coalesce(t.therapist_commission_amount, 0) = 0
      and (p_outlet_id is null or t.outlet_id = p_outlet_id)
  loop
    v_commission := 0;

    if v_transaction.appointment_id is not null then
      select public.csp_commission_for_items(coalesce(a.service_items, '[]'::jsonb), a.therapist_id, 'Therapist')
      into v_commission
      from public.appointments a
      where a.id = v_transaction.appointment_id
        and a.status = 'completed'
        and a.actual_completed_at is not null;
    elsif v_transaction.appointment_group_id is not null
      and not exists (
        select 1
        from public.appointments pending
        where pending.appointment_group_id = v_transaction.appointment_group_id
          and pending.status not in ('completed', 'cancelled', 'no_show')
      ) then
      select coalesce(sum(public.csp_commission_for_items(coalesce(a.service_items, '[]'::jsonb), a.therapist_id, 'Therapist')), 0)
      into v_commission
      from public.appointments a
      where a.appointment_group_id = v_transaction.appointment_group_id
        and a.status = 'completed'
        and a.actual_completed_at is not null;
    end if;

    if coalesce(v_commission, 0) > 0 then
      update public.transactions
      set therapist_commission_amount = v_commission,
          updated_at = now()
      where id = v_transaction.id
        and therapist_commission_amount = 0;
    end if;
  end loop;

  return v_updated;
end;
$$;

revoke all on function public.complete_due_appointments(uuid) from public, anon;
grant execute on function public.complete_due_appointments(uuid) to authenticated, service_role;;
