-- ============================================================================
-- Glowup Book — customer accounts
--
-- Customers self-register on glowupbook.com (profiles.role = 'customer') and can
-- view/cancel their own bookings across every salon. We link a customer record
-- to an auth account via customers.account_id. Reads/cancels go through
-- SECURITY DEFINER RPCs so we don't have to broaden table RLS.
--
-- (Employees are NOT created here — they remain admin-managed `staff` rows.)
-- ============================================================================

-- 1) New role value. (PG15: ADD VALUE is fine inside a tx as long as the new
--    value isn't *used* in the same tx — nothing below uses the literal.)
alter type user_role add value if not exists 'customer';

-- 2) Link customer records to an auth account.
alter table public.customers
  add column if not exists account_id uuid references auth.users(id) on delete set null;
create index if not exists customers_account_idx on public.customers (account_id);

-- 3) Re-create book_appointment so that when a logged-in customer books, their
--    account is linked to the customer record (claimed if it already existed by
--    email). Anonymous booking still works exactly as before.
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
  v_uid      uuid := auth.uid();   -- null for anonymous bookings
begin
  if coalesce(trim(p_customer_name), '') = '' then
    raise exception 'A name is required to book.';
  end if;

  select * into v_salon from public.salons where slug = p_slug and is_published;
  if not found then raise exception 'This salon is not accepting online bookings.'; end if;

  select * into v_service from public.services
    where id = p_service and salon_id = v_salon.id and is_active and bookable_online;
  if not found then raise exception 'That service is not available to book online.'; end if;

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

  perform 1 from public.appointments a
   where a.staff_id = p_staff
     and a.status in ('booked','confirmed','completed')
     and a.starts_at < v_end and a.ends_at > p_start
   for update;
  if found then
    raise exception 'Sorry, that slot was just taken. Please pick another time.';
  end if;

  if exists (
    select 1 from public.time_off t
    where t.staff_id = p_staff and t.starts_at < v_end and t.ends_at > p_start
  ) then
    raise exception 'That time is not available.';
  end if;

  -- Find-or-create the customer. Prefer the logged-in account, then email.
  if v_uid is not null then
    select id into v_customer from public.customers
      where salon_id = v_salon.id and account_id = v_uid limit 1;
  end if;
  if v_customer is null and coalesce(trim(p_customer_email), '') <> '' then
    select id into v_customer from public.customers
      where salon_id = v_salon.id and lower(email) = lower(trim(p_customer_email)) limit 1;
  end if;

  if v_customer is null then
    insert into public.customers (salon_id, name, email, phone, account_id)
    values (v_salon.id, trim(p_customer_name),
            nullif(trim(p_customer_email), ''), nullif(trim(p_customer_phone), ''), v_uid)
    returning id into v_customer;
  elsif v_uid is not null then
    -- claim an existing (e.g. previously walk-in) record for this account
    update public.customers set account_id = v_uid
      where id = v_customer and account_id is null;
  end if;

  insert into public.appointments
    (salon_id, customer_id, staff_id, service_id, starts_at, ends_at, status, source, price, notes)
  values
    (v_salon.id, v_customer, p_staff, p_service, p_start, v_end, 'booked', 'online', v_service.price, p_notes)
  returning id into v_appt;

  return v_appt;
end; $$;

grant execute on function public.book_appointment(text, uuid, uuid, timestamptz, text, text, text, text) to anon, authenticated;

-- 4) A customer's own bookings across all salons (joined for display).
create or replace function public.my_appointments()
returns table (
  id uuid, salon_name text, salon_slug text, service_name text, staff_name text,
  starts_at timestamptz, ends_at timestamptz, status appointment_status, price numeric
)
language sql stable security definer set search_path = public as $$
  select a.id, sl.name, sl.slug, sv.name, st.name, a.starts_at, a.ends_at, a.status, a.price
  from public.appointments a
  join public.customers c on c.id = a.customer_id and c.account_id = auth.uid()
  join public.salons sl on sl.id = a.salon_id
  left join public.services sv on sv.id = a.service_id
  left join public.staff st on st.id = a.staff_id
  order by a.starts_at desc;
$$;
grant execute on function public.my_appointments() to authenticated;

-- 5) Let a customer cancel their own upcoming booking.
create or replace function public.cancel_my_appointment(p_appt uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.appointments a set status = 'cancelled'
  where a.id = p_appt
    and a.starts_at > now()
    and exists (select 1 from public.customers c where c.id = a.customer_id and c.account_id = auth.uid());
  if not found then
    raise exception 'Booking not found, already started, or not yours to cancel.';
  end if;
end; $$;
grant execute on function public.cancel_my_appointment(uuid) to authenticated;
