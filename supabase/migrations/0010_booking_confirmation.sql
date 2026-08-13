-- ============================================================================
-- Glowup Book — appointment reconfirmation + no cross-salon double-booking
-- ============================================================================

-- A per-appointment token lets a business email/text a one-tap confirm link.
alter table public.appointments add column if not exists confirm_token uuid not null default gen_random_uuid();
alter table public.appointments add column if not exists confirmation_requested_at timestamptz;
create index if not exists appointments_confirm_token_idx on public.appointments (confirm_token);

-- ---------------------------------------------------------------------------
-- book_appointment — now also blocks the SAME person (by account or email)
-- from holding two overlapping appointments across any salons.
-- ---------------------------------------------------------------------------
create or replace function public.book_appointment(
  p_slug          text,
  p_service       uuid,
  p_staff         uuid,
  p_start         timestamptz,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text default null,
  p_notes         text default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_salon public.salons%rowtype; v_service public.services%rowtype;
  v_total_min int; v_end timestamptz; v_dow int; v_customer uuid; v_appt uuid; v_ok boolean;
  v_uid uuid := auth.uid();
begin
  if coalesce(trim(p_customer_name), '') = '' then raise exception 'A name is required to book.'; end if;
  select * into v_salon from public.salons where slug = p_slug and is_published;
  if not found then raise exception 'This salon is not accepting online bookings.'; end if;
  select * into v_service from public.services
    where id = p_service and salon_id = v_salon.id and is_active and bookable_online;
  if not found then raise exception 'That service is not available to book online.'; end if;
  if not exists (
    select 1 from public.staff s join public.staff_services ss on ss.staff_id = s.id and ss.service_id = p_service
    where s.id = p_staff and s.salon_id = v_salon.id and s.is_active and s.accepts_online_booking
  ) then raise exception 'That staff member cannot perform this service.'; end if;

  v_total_min := v_service.duration_min + coalesce(v_service.buffer_min, 0);
  v_end := p_start + make_interval(mins => v_total_min);
  if p_start < now() then raise exception 'That time is in the past.'; end if;

  v_dow := extract(dow from (p_start at time zone v_salon.timezone))::int;
  select exists (
    select 1 from public.working_hours wh
    where wh.staff_id = p_staff and wh.dow = v_dow
      and (p_start at time zone v_salon.timezone)::time >= wh.start_time
      and (v_end   at time zone v_salon.timezone)::time <= wh.end_time
  ) into v_ok;
  if not v_ok then raise exception 'That time is outside the staff member''s working hours.'; end if;

  perform 1 from public.appointments a
   where a.staff_id = p_staff and a.status in ('booked','confirmed','completed')
     and a.starts_at < v_end and a.ends_at > p_start for update;
  if found then raise exception 'Sorry, that slot was just taken. Please pick another time.'; end if;

  if exists (select 1 from public.time_off t where t.staff_id = p_staff and t.starts_at < v_end and t.ends_at > p_start) then
    raise exception 'That time is not available.';
  end if;

  -- NEW: same person can't double-book overlapping times across any salon.
  if exists (
    select 1 from public.appointments a join public.customers cu on cu.id = a.customer_id
    where a.status in ('booked','confirmed','completed')
      and a.starts_at < v_end and a.ends_at > p_start
      and ( (v_uid is not null and cu.account_id = v_uid)
            or (coalesce(trim(p_customer_email),'') <> '' and lower(cu.email) = lower(trim(p_customer_email))) )
  ) then
    raise exception 'You already have a booking that overlaps this time. Please pick another slot.';
  end if;

  if v_uid is not null then
    select id into v_customer from public.customers where salon_id = v_salon.id and account_id = v_uid limit 1;
  end if;
  if v_customer is null and coalesce(trim(p_customer_email), '') <> '' then
    select id into v_customer from public.customers where salon_id = v_salon.id and lower(email) = lower(trim(p_customer_email)) limit 1;
  end if;
  if v_customer is null then
    insert into public.customers (salon_id, name, email, phone, account_id)
    values (v_salon.id, trim(p_customer_name), nullif(trim(p_customer_email), ''), nullif(trim(p_customer_phone), ''), v_uid)
    returning id into v_customer;
  elsif v_uid is not null then
    update public.customers set account_id = v_uid where id = v_customer and account_id is null;
  end if;

  insert into public.appointments (salon_id, customer_id, staff_id, service_id, starts_at, ends_at, status, source, price, notes)
  values (v_salon.id, v_customer, p_staff, p_service, p_start, v_end, 'booked', 'online', v_service.price, p_notes)
  returning id into v_appt;
  return v_appt;
end; $$;
grant execute on function public.book_appointment(text, uuid, uuid, timestamptz, text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Confirmation via emailed/texted token link (anonymous-friendly).
-- ---------------------------------------------------------------------------
create or replace function public.confirm_appointment(p_token uuid)
returns table (salon_name text, starts_at timestamptz, service_name text)
language plpgsql security definer set search_path = public as $$
begin
  update public.appointments a set status = 'confirmed', confirmation_requested_at = coalesce(confirmation_requested_at, now())
   where a.confirm_token = p_token and a.status in ('booked','confirmed') and a.starts_at > now();
  return query
    select sl.name, a.starts_at, sv.name
    from public.appointments a
    join public.salons sl on sl.id = a.salon_id
    left join public.services sv on sv.id = a.service_id
    where a.confirm_token = p_token;
end; $$;
grant execute on function public.confirm_appointment(uuid) to anon, authenticated;

-- A logged-in customer confirms their own booking from "My account".
create or replace function public.confirm_my_appointment(p_appt uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.appointments a set status = 'confirmed'
   where a.id = p_appt and a.starts_at > now()
     and exists (select 1 from public.customers c where c.id = a.customer_id and c.account_id = auth.uid());
  if not found then raise exception 'Booking not found or cannot be confirmed.'; end if;
end; $$;
grant execute on function public.confirm_my_appointment(uuid) to authenticated;
