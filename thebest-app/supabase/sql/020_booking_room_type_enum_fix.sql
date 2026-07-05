-- The live services.room_type column is an enum. Cast room types to text
-- before using an empty-string fallback in the public booking functions.

do $$
declare
  v_signature text;
  v_definition text;
  v_patched text;
begin
  foreach v_signature in array array[
    'public.get_public_booking_slots(uuid,uuid[],date,text)',
    'public.create_public_booking_hold(uuid,uuid[],timestamptz,text,text,text,text,text,text,text)'
  ] loop
    select pg_get_functiondef(v_signature::regprocedure)
    into v_definition;

    v_patched := replace(
      v_definition,
      'coalesce(s.room_type, '''')',
      'coalesce(s.room_type::text, '''')'
    );
    v_patched := replace(
      v_patched,
      'coalesce(r.room_type, r.type::text, '''')',
      'coalesce(r.room_type::text, r.type::text, '''')'
    );

    if v_patched = v_definition then
      raise exception 'No room_type expression was patched in %', v_signature;
    end if;

    execute v_patched;
  end loop;
end;
$$;

