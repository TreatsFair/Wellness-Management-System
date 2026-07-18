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
        coalesce(v_row.booked_end_at, v_row.end_at at time zone 'Asia/Kuala_Lumpur')
        - coalesce(v_row.booked_start_at, v_row.start_at at time zone 'Asia/Kuala_Lumpur')
      ),
      coalesce(v_row.end_at at time zone 'Asia/Kuala_Lumpur', v_row.booked_end_at)
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

    select t.id, t.service_items, t.therapist_commission_amount
    into v_transaction
    from public.transactions t
    where t.source = 'online_booking'
      and t.payment_status = 'paid'
      and (
        t.appointment_id = v_row.id
        or (v_row.appointment_group_id is not null and t.appointment_group_id = v_row.appointment_group_id)
      )
    limit 1;

    if v_transaction.id is not null and coalesce(v_transaction.therapist_commission_amount, 0) = 0 then
      v_commission := public.csp_commission_for_items(v_transaction.service_items, v_row.therapist_id, 'Therapist');
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
