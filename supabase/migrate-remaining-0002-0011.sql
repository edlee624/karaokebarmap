-- Glowup Book - remaining schema (migrations 0002-0011). Run AFTER 0001 is already applied.

-- ===== 0002_booking_rpcs.sql =====
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

-- ===== 0003_customer_accounts.sql =====
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

-- ===== 0004_directory_listings.sql =====
-- ============================================================================
-- Glowup Book — unclaimed directory listings + claim flow
--
-- We seed the directory with public salon listings (e.g. from NY Open Data).
-- These have no owner yet (owner_id null, claimed=false) and aren't bookable
-- (is_published=false). They show in the directory so customers can find them
-- and owners can "claim" their page to take it over.
-- ============================================================================

-- Seed listings have no owner until claimed.
alter table public.salons alter column owner_id drop not null;
alter table public.salons add column if not exists claimed boolean not null default true;
alter table public.salons add column if not exists source  text    not null default 'owner';

-- Public read now also covers unclaimed listings (their name/address is public
-- info), in addition to published salons and members/admins.
drop policy if exists "salons: read published or member" on public.salons;
create policy "salons: read published listed or member" on public.salons for select
  using (is_published or claimed = false or public.is_salon_member(id) or public.is_admin());

-- Claim an unclaimed listing: the first logged-in user to claim it becomes the
-- owner and can then set it up and publish it.
create or replace function public.claim_salon(p_salon uuid)
returns public.salons
language plpgsql security definer set search_path = public as $$
declare v_row public.salons%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be logged in to claim a salon.';
  end if;
  update public.salons
     set owner_id = auth.uid(), claimed = true
   where id = p_salon and (owner_id is null or claimed = false)
   returning * into v_row;
  if not found then
    raise exception 'This salon has already been claimed.';
  end if;
  return v_row;
end; $$;
grant execute on function public.claim_salon(uuid) to authenticated;

-- ===== 0005_salon_socials.sql =====
-- ============================================================================
-- Glowup Book — social links on a salon profile
-- Each business profile now carries Instagram / Facebook / TikTok / website,
-- alongside the existing name, address, phone, email. These also become the
-- source for the homepage inspiration carousel once businesses connect their
-- social accounts.
-- ============================================================================

alter table public.salons add column if not exists instagram text;
alter table public.salons add column if not exists facebook  text;
alter table public.salons add column if not exists tiktok    text;
alter table public.salons add column if not exists website   text;

-- ===== 0006_admin.sql =====
-- ============================================================================
-- Glowup Book — platform super-admin
-- A profile with role='admin' can manage any salon and see platform stats.
-- (Designate one with:  update public.profiles set role='admin' where email='you@example.com';)
-- ============================================================================

-- Admins can update / delete any salon (in addition to salon managers/owners).
drop policy if exists "salons: manager update" on public.salons;
create policy "salons: manager or admin update" on public.salons for update
  using (public.is_salon_manager(id) or public.is_admin())
  with check (public.is_salon_manager(id) or public.is_admin());

drop policy if exists "salons: owner delete" on public.salons;
create policy "salons: owner or admin delete" on public.salons for delete
  using (owner_id = auth.uid() or public.is_admin());

-- Platform overview counts for the admin console (security definer, admin-gated).
create or replace function public.admin_overview()
returns json language plpgsql stable security definer set search_path = public as $$
declare result json;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  select json_build_object(
    'salons_total',     (select count(*) from public.salons),
    'salons_claimed',   (select count(*) from public.salons where claimed),
    'salons_published', (select count(*) from public.salons where is_published),
    'customers',        (select count(*) from public.customers),
    'appointments',     (select count(*) from public.appointments),
    'users',            (select count(*) from public.profiles)
  ) into result;
  return result;
end; $$;
grant execute on function public.admin_overview() to authenticated;

-- ===== 0007_salon_geo.sql =====
-- ============================================================================
-- Glowup Book — salon coordinates (for the directory map view)
-- Backfilled for the NYC seed from NY Open Data; geocoded for new salons later.
-- ============================================================================

alter table public.salons add column if not exists lat double precision;
alter table public.salons add column if not exists lon double precision;
create index if not exists salons_geo_idx on public.salons (lat, lon);

-- ===== 0008_profiles_favorites_reviews.sql =====
-- ============================================================================
-- Glowup Book — customer favorites & reviews, employee linking, and a fix for
-- the owner/employee salon lookup.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- FIX: with 10k public seed salons, a plain "select * from salons" returns far
-- more than the user's own. my_salons() returns ONLY salons the caller owns or
-- is a staff member of.
-- ---------------------------------------------------------------------------
create or replace function public.my_salons()
returns setof public.salons
language sql stable security definer set search_path = public as $$
  select s.* from public.salons s
  where s.owner_id = auth.uid()
     or exists (select 1 from public.salon_members m where m.salon_id = s.id and m.profile_id = auth.uid())
  order by s.created_at;
$$;
grant execute on function public.my_salons() to authenticated;

-- ---------------------------------------------------------------------------
-- FAVORITES — a customer's saved salons
-- ---------------------------------------------------------------------------
create table if not exists public.favorites (
  account_id uuid not null references auth.users(id) on delete cascade,
  salon_id   uuid not null references public.salons(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (account_id, salon_id)
);
alter table public.favorites enable row level security;
create policy "favorites: own" on public.favorites for all
  using (account_id = auth.uid()) with check (account_id = auth.uid());

-- ---------------------------------------------------------------------------
-- REVIEWS — a customer rates a past appointment (1–5 + comment)
-- ---------------------------------------------------------------------------
create table if not exists public.reviews (
  id             uuid primary key default gen_random_uuid(),
  account_id     uuid not null references auth.users(id) on delete cascade,
  salon_id       uuid not null references public.salons(id) on delete cascade,
  appointment_id uuid references public.appointments(id) on delete set null,
  rating         int  not null check (rating between 1 and 5),
  comment        text,
  created_at     timestamptz not null default now(),
  unique (appointment_id)
);
alter table public.reviews enable row level security;
-- Public can read reviews (so salons show ratings); customers manage their own.
create policy "reviews: public read" on public.reviews for select using (true);
create policy "reviews: own write"  on public.reviews for all
  using (account_id = auth.uid()) with check (account_id = auth.uid());

-- Re-define my_appointments to also return salon_id (needed to leave a review).
-- Drop first: 0003 defined it with different return columns, and Postgres won't
-- let CREATE OR REPLACE change the output columns.
drop function if exists public.my_appointments();
create function public.my_appointments()
returns table (
  id uuid, salon_id uuid, salon_name text, salon_slug text, service_name text, staff_name text,
  starts_at timestamptz, ends_at timestamptz, status appointment_status, price numeric
)
language sql stable security definer set search_path = public as $$
  select a.id, sl.id, sl.name, sl.slug, sv.name, st.name, a.starts_at, a.ends_at, a.status, a.price
  from public.appointments a
  join public.customers c on c.id = a.customer_id and c.account_id = auth.uid()
  join public.salons sl on sl.id = a.salon_id
  left join public.services sv on sv.id = a.service_id
  left join public.staff st on st.id = a.staff_id
  order by a.starts_at desc;
$$;
grant execute on function public.my_appointments() to authenticated;

-- Average rating + count for a salon (display on storefront/directory).
create or replace function public.salon_rating(p_salon uuid)
returns table (avg_rating numeric, review_count bigint)
language sql stable security definer set search_path = public as $$
  select round(avg(rating), 1), count(*) from public.reviews where salon_id = p_salon;
$$;
grant execute on function public.salon_rating(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- EMPLOYEE LINKING — a salon manager links a self-registered employee account
-- (by email) to their salon: creates the membership + a staff row.
-- ---------------------------------------------------------------------------
create or replace function public.link_employee(p_salon uuid, p_email text, p_name text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_profile uuid; v_name text;
begin
  if not public.is_salon_manager(p_salon) then raise exception 'Only the salon owner/manager can add employees.'; end if;
  select id, coalesce(full_name, email) into v_profile, v_name
    from public.profiles where lower(email) = lower(trim(p_email)) limit 1;
  if v_profile is null then
    raise exception 'No Glowup Book account found for %. Ask them to sign up as an employee first.', p_email;
  end if;
  insert into public.salon_members (salon_id, profile_id, member_role)
    values (p_salon, v_profile, 'staff')
    on conflict (salon_id, profile_id) do nothing;
  insert into public.staff (salon_id, profile_id, name)
    select p_salon, v_profile, coalesce(p_name, v_name)
    where not exists (select 1 from public.staff where salon_id = p_salon and profile_id = v_profile);
end; $$;
grant execute on function public.link_employee(uuid, text, text) to authenticated;

-- An employee's upcoming appointments at the salons they belong to.
create or replace function public.my_staff_appointments()
returns table (id uuid, salon_name text, service_name text, customer_name text,
               starts_at timestamptz, ends_at timestamptz, status appointment_status)
language sql stable security definer set search_path = public as $$
  select a.id, sl.name, sv.name, c.name, a.starts_at, a.ends_at, a.status
  from public.appointments a
  join public.staff st on st.id = a.staff_id and st.profile_id = auth.uid()
  join public.salons sl on sl.id = a.salon_id
  left join public.services sv on sv.id = a.service_id
  left join public.customers c on c.id = a.customer_id
  where a.starts_at >= (now() - interval '1 day')
  order by a.starts_at;
$$;
grant execute on function public.my_staff_appointments() to authenticated;

-- ===== 0009_employee_portfolio.sql =====
-- ============================================================================
-- Glowup Book — employee skills/bio, photo portfolio (Supabase Storage), and
-- linking employees by email OR phone.
-- ============================================================================

-- Employee (and anyone) profile: skills + bio.
alter table public.profiles add column if not exists skills text;
alter table public.profiles add column if not exists bio    text;

-- ---------------------------------------------------------------------------
-- PORTFOLIO — photos of finished work, uploaded by employees.
-- ---------------------------------------------------------------------------
create table if not exists public.portfolio (
  id             uuid primary key default gen_random_uuid(),
  salon_id       uuid references public.salons(id) on delete cascade,
  profile_id     uuid not null references auth.users(id) on delete cascade,  -- uploader
  appointment_id uuid references public.appointments(id) on delete set null,
  path           text not null,            -- storage object path in the 'portfolio' bucket
  caption        text,
  is_public      boolean not null default true,
  created_at     timestamptz not null default now()
);
alter table public.portfolio enable row level security;
create index if not exists portfolio_salon_idx on public.portfolio (salon_id, created_at desc);

create policy "portfolio: read public or member" on public.portfolio for select
  using (is_public or profile_id = auth.uid() or public.is_salon_member(salon_id) or public.is_admin());
create policy "portfolio: uploader insert" on public.portfolio for insert
  with check (profile_id = auth.uid() and (salon_id is null or public.is_salon_member(salon_id)));
create policy "portfolio: uploader or manager manage" on public.portfolio for all
  using (profile_id = auth.uid() or public.is_salon_manager(salon_id))
  with check (profile_id = auth.uid() or public.is_salon_manager(salon_id));

-- ---------------------------------------------------------------------------
-- STORAGE bucket for portfolio images (public read; authenticated upload).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('portfolio', 'portfolio', true)
  on conflict (id) do nothing;

drop policy if exists "portfolio storage read"   on storage.objects;
drop policy if exists "portfolio storage upload" on storage.objects;
drop policy if exists "portfolio storage manage" on storage.objects;
create policy "portfolio storage read"   on storage.objects for select using (bucket_id = 'portfolio');
create policy "portfolio storage upload" on storage.objects for insert to authenticated with check (bucket_id = 'portfolio');
create policy "portfolio storage manage" on storage.objects for all to authenticated
  using (bucket_id = 'portfolio' and owner = auth.uid()) with check (bucket_id = 'portfolio' and owner = auth.uid());

-- ---------------------------------------------------------------------------
-- Link an employee by email OR phone.
-- ---------------------------------------------------------------------------
create or replace function public.link_employee(p_salon uuid, p_email text, p_name text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_profile uuid; v_name text; v_key text := trim(coalesce(p_email, ''));
begin
  if not public.is_salon_manager(p_salon) then raise exception 'Only the salon owner/manager can add employees.'; end if;
  select id, coalesce(full_name, email) into v_profile, v_name
    from public.profiles
    where lower(email) = lower(v_key)
       or regexp_replace(coalesce(phone, ''), '\D', '', 'g') = regexp_replace(v_key, '\D', '', 'g') and v_key <> ''
    limit 1;
  if v_profile is null then
    raise exception 'No Glowup Book account found for %. Invite them to sign up as an employee first.', p_email;
  end if;
  insert into public.salon_members (salon_id, profile_id, member_role) values (p_salon, v_profile, 'staff')
    on conflict (salon_id, profile_id) do nothing;
  insert into public.staff (salon_id, profile_id, name)
    select p_salon, v_profile, coalesce(p_name, v_name)
    where not exists (select 1 from public.staff where salon_id = p_salon and profile_id = v_profile);
end; $$;
grant execute on function public.link_employee(uuid, text, text) to authenticated;

-- All of an employee's appointments (past + upcoming) for history.
create or replace function public.my_staff_appointments()
returns table (id uuid, salon_name text, service_name text, customer_name text,
               starts_at timestamptz, ends_at timestamptz, status appointment_status)
language sql stable security definer set search_path = public as $$
  select a.id, sl.name, sv.name, c.name, a.starts_at, a.ends_at, a.status
  from public.appointments a
  join public.staff st on st.id = a.staff_id and st.profile_id = auth.uid()
  join public.salons sl on sl.id = a.salon_id
  left join public.services sv on sv.id = a.service_id
  left join public.customers c on c.id = a.customer_id
  order by a.starts_at desc;
$$;
grant execute on function public.my_staff_appointments() to authenticated;

-- ===== 0010_booking_confirmation.sql =====
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

-- ===== 0011_reminded_at.sql =====
-- ============================================================================
-- Glowup Book — track when a reminder email was sent (dedupe reminders).
-- ============================================================================
alter table public.appointments add column if not exists reminded_at timestamptz;
