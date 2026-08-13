-- ============================================================================
-- Glowbook — public booking RPCs
--
-- The storefront is anonymous. We deliberately do NOT give anon read access to
-- appointments/customers. Instead, two SECURITY DEFINER functions provide a
-- narrow, safe interface:
--
--   get_available_slots(...) -> only the FREE start times for a day. It reads
--     appointments internally to mask busy times, but returns only timestamps,
--     never appointment/customer details.
--
--   book_appointment(...) -> validates the slot is real & free, finds-or-creates
--     the customer, and inserts the appointment atomically. Returns the new id.
--
-- Both run as the function owner (bypassing RLS) but enforce their own checks:
-- the salon must be published, the service active+bookable_online, the staff
-- active+accepts_online_booking, and the slot must fall inside working hours,
-- outside time_off, and not overlap an existing appointment.
-- ============================================================================

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- get_available_slots
-- For a given salon (by slug), service and date, return bookable start times.
-- p_staff is optional: null = "any available staff" (union of all eligible).
-- Slots are returned as timestamptz (UTC); the client renders them in the
-- salon's timezone.
-- ---------------------------------------------------------------------------
create or replace function public.get_available_slots(
  p_slug    text,
  p_service uuid,
  p_date    date,
  p_staff   uuid default null,
  p_slot_step_min int default 15
)
returns table (slot_start timestamptz, staff_id uuid)
language plpgsql stable security definer set search_path = public as $$
declare
  v_salon   public.salons%rowtype;
  v_service public.services%rowtype;
  v_total_min int;
  v_dow     int;
begin
  -- Salon must exist and be published.
  select * into v_salon from public.salons where slug = p_slug and is_published;
  if not found then
    return;   -- empty set
  end if;

  -- Service must belong to the salon and be online-bookable.
  select * into v_service from public.services
    where id = p_service and salon_id = v_salon.id and is_active and bookable_online;
  if not found then
    return;
  end if;

  v_total_min := v_service.duration_min + coalesce(v_service.buffer_min, 0);
  -- day-of-week in the salon's timezone
  v_dow := extract(dow from (p_date::timestamp))::int;

  return query
  with candidate_staff as (
    -- Eligible staff: active, online-bookable, can perform this service, and
    -- (if p_staff given) only that one.
    select s.id
    from public.staff s
    join public.staff_services ss on ss.staff_id = s.id and ss.service_id = p_service
    where s.salon_id = v_salon.id
      and s.is_active and s.accepts_online_booking
      and (p_staff is null or s.id = p_staff)
  ),
  -- For each eligible staff member, expand their working hours for this dow into
  -- candidate start times at p_slot_step_min intervals.
  steps as (
    select cs.id as staff_id,
           gs as slot_start
    from candidate_staff cs
    join public.working_hours wh
      on wh.staff_id = cs.id and wh.dow = v_dow
    cross join lateral generate_series(
      -- localize the working window to an absolute timestamptz for this date
      (p_date::text || ' ' || wh.start_time::text)::timestamp at time zone v_salon.timezone,
      ((p_date::text || ' ' || wh.end_time::text)::timestamp at time zone v_salon.timezone)
        - make_interval(mins => v_total_min),
      make_interval(mins => p_slot_step_min)
    ) as gs
  )
  select st.slot_start, st.staff_id
  from steps st
  where
    -- not in the past
    st.slot_start >= now()
    -- not overlapping an existing (non-cancelled) appointment for that staff
    and not exists (
      select 1 from public.appointments a
      where a.staff_id = st.staff_id
        and a.status in ('booked','confirmed','completed')
        and a.starts_at < st.slot_start + make_interval(mins => v_total_min)
        and a.ends_at   > st.slot_start
    )
    -- not inside a time-off block for that staff
    and not exists (
      select 1 from public.time_off t
      where t.staff_id = st.staff_id
        and t.starts_at < st.slot_start + make_interval(mins => v_total_min)
        and t.ends_at   > st.slot_start
    )
  order by st.slot_start, st.staff_id;
end; $$;

-- Allow the storefront (anon) to call it.
grant execute on function public.get_available_slots(text, uuid, date, uuid, int) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- book_appointment
-- Validates and creates an online booking. Finds-or-creates the customer by
-- (salon, email). Re-checks availability inside a row lock to avoid double
-- booking. Returns the new appointment id.
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
  v_salon    public.salons%rowtype;
  v_service  public.services%rowtype;
  v_total_min int;
  v_end      timestamptz;
  v_dow      int;
  v_customer uuid;
  v_appt     uuid;
  v_ok       boolean;
begin
  if coalesce(trim(p_customer_name), '') = '' then
    raise exception 'A name is required to book.';
  end if;

  select * into v_salon from public.salons where slug = p_slug and is_published;
  if not found then raise exception 'This salon is not accepting online bookings.'; end if;

  select * into v_service from public.services
    where id = p_service and salon_id = v_salon.id and is_active and bookable_online;
  if not found then raise exception 'That service is not available to book online.'; end if;

  -- Staff must be eligible for this service.
  if not exists (
    select 1 from public.staff s
    join public.staff_services ss on ss.staff_id = s.id and ss.service_id = p_service
    where s.id = p_staff and s.salon_id = v_salon.id
      and s.is_active and s.accepts_online_booking
  ) then
    raise exception 'That staff member cannot perform this service.';
  end if;

  v_total_min := v_service.duration_min + coalesce(v_service.buffer_min, 0);
  v_end := p_start + make_interval(mins => v_total_min);

  if p_start < now() then
    raise exception 'That time is in the past.';
  end if;

  -- Slot must fall within the staff member's working hours for that weekday.
  v_dow := extract(dow from (p_start at time zone v_salon.timezone))::int;
  select exists (
    select 1 from public.working_hours wh
    where wh.staff_id = p_staff and wh.dow = v_dow
      and (p_start at time zone v_salon.timezone)::time >= wh.start_time
      and (v_end   at time zone v_salon.timezone)::time <= wh.end_time
  ) into v_ok;
  if not v_ok then
    raise exception 'That time is outside the staff member''s working hours.';
  end if;

  -- Lock overlapping rows for this staff to prevent a race / double-booking.
  perform 1 from public.appointments a
   where a.staff_id = p_staff
     and a.status in ('booked','confirmed','completed')
     and a.starts_at < v_end and a.ends_at > p_start
   for update;
  if found then
    raise exception 'Sorry, that slot was just taken. Please pick another time.';
  end if;

  -- Also respect time-off blocks.
  if exists (
    select 1 from public.time_off t
    where t.staff_id = p_staff and t.starts_at < v_end and t.ends_at > p_start
  ) then
    raise exception 'That time is not available.';
  end if;

  -- Find-or-create the customer by email (fallback: always create if no email).
  if coalesce(trim(p_customer_email), '') <> '' then
    select id into v_customer from public.customers
      where salon_id = v_salon.id and lower(email) = lower(trim(p_customer_email))
      limit 1;
  end if;
  if v_customer is null then
    insert into public.customers (salon_id, name, email, phone)
    values (v_salon.id, trim(p_customer_name), nullif(trim(p_customer_email), ''), nullif(trim(p_customer_phone), ''))
    returning id into v_customer;
  end if;

  insert into public.appointments
    (salon_id, customer_id, staff_id, service_id, starts_at, ends_at, status, source, price, notes)
  values
    (v_salon.id, v_customer, p_staff, p_service, p_start, v_end, 'booked', 'online', v_service.price, p_notes)
  returning id into v_appt;

  return v_appt;
end; $$;

grant execute on function public.book_appointment(text, uuid, uuid, timestamptz, text, text, text, text) to anon, authenticated;
