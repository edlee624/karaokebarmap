-- ============================================================================
-- Karaoke Bar Map — full database setup (paste into Supabase SQL editor).
-- Runs all migrations 0001–0015 in order, then seeds 225 US karaoke venues.
-- Safe to re-run: seed uses ON CONFLICT DO NOTHING; DDL mostly IF NOT EXISTS.
-- ============================================================================

-- ===================== 0001_init.sql =====================
-- ============================================================================
-- Glowbook — initial schema
-- Multi-tenant booking CRM for salons / barbers / hairdressers / nail studios.
--
-- Each salon is a tenant. Staff log in via Supabase Auth; their access is scoped
-- to the salon(s) they belong to. The PUBLIC storefront is anonymous: visitors
-- never query appointment rows directly — availability and booking go through
-- SECURITY DEFINER RPCs (see 0002) so no customer data leaks to the browser.
--
-- Security model: the browser talks to Postgres directly through Supabase, so
-- Row Level Security (RLS) is the real boundary. Every table has RLS enabled and
-- explicit policies. The anon/auth client can ONLY do what the policies allow.
-- ============================================================================

create extension if not exists "pgcrypto";

-- Forward references in policies call helper functions defined just below; defer
-- body validation until call time so creation order doesn't error.
set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type user_role         as enum ('owner', 'staff', 'admin');
create type member_role        as enum ('owner', 'manager', 'staff');
create type appointment_status as enum ('booked', 'confirmed', 'completed', 'cancelled', 'no_show');
create type appointment_source as enum ('online', 'manual');

-- ---------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER so policies can call them without
-- recursing into RLS). STABLE; search_path pinned for safety.
-- ---------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- Is the current user a member (any role) of this salon?
create or replace function public.is_salon_member(p_salon uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.salons s where s.id = p_salon and s.owner_id = auth.uid()
    union
    select 1 from public.salon_members m where m.salon_id = p_salon and m.profile_id = auth.uid()
  );
$$;

-- Is the current user an owner/manager of this salon (i.e. can manage settings)?
create or replace function public.is_salon_manager(p_salon uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.salons s where s.id = p_salon and s.owner_id = auth.uid()
    union
    select 1 from public.salon_members m
      where m.salon_id = p_salon and m.profile_id = auth.uid()
        and m.member_role in ('owner','manager')
  );
$$;

-- updated_at trigger helper
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

-- ===========================================================================
-- IDENTITY
-- ===========================================================================

-- One row per auth.users. Created automatically on signup (trigger below).
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        user_role   not null default 'owner',
  full_name   text,
  email       text,
  phone       text,
  avatar_url  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;

create policy "profiles: self read"   on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profiles: self update" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- inserts happen via the signup trigger (security definer), not the client.

-- Provision a profile row when a new auth user is created. The name flows from
-- the signup metadata the frontend passes (data: { full_name }).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce((new.raw_user_meta_data->>'role')::user_role, 'owner')
  );
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ===========================================================================
-- SALONS (tenants)
-- ===========================================================================
create table public.salons (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references public.profiles(id) on delete cascade,
  name          text not null,
  slug          text not null unique,          -- public storefront URL: /book/<slug>
  business_type text,                           -- 'hair' | 'barber' | 'nails' | 'beauty' | ...
  about         text,
  phone         text,
  email         text,
  address       text,
  city          text,
  timezone      text not null default 'UTC',    -- IANA tz; availability is computed in it
  logo_url      text,
  cover_url     text,
  currency      text not null default 'USD',
  is_published  boolean not null default false, -- storefront live + bookable online?
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
alter table public.salons enable row level security;
create trigger salons_touch before update on public.salons for each row execute function public.touch_updated_at();
create index on public.salons (owner_id);

-- Published salons are publicly readable (the storefront). Members always see
-- their own. Anyone authenticated/anon can read a published salon's profile.
create policy "salons: read published or member" on public.salons for select
  using (is_published or public.is_salon_member(id) or public.is_admin());
create policy "salons: owner insert" on public.salons for insert with check (owner_id = auth.uid());
create policy "salons: manager update" on public.salons for update
  using (public.is_salon_manager(id)) with check (public.is_salon_manager(id));
create policy "salons: owner delete" on public.salons for delete using (owner_id = auth.uid());

-- Staff who have a login. (Staff WITHOUT a login still exist as rows in `staff`.)
create table public.salon_members (
  salon_id    uuid not null references public.salons(id) on delete cascade,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  member_role member_role not null default 'staff',
  created_at  timestamptz not null default now(),
  primary key (salon_id, profile_id)
);
alter table public.salon_members enable row level security;
create policy "members: read"   on public.salon_members for select
  using (public.is_salon_member(salon_id) or profile_id = auth.uid());
create policy "members: manage"  on public.salon_members for all
  using (public.is_salon_manager(salon_id)) with check (public.is_salon_manager(salon_id));

-- ===========================================================================
-- STAFF (service providers — may or may not have a login)
-- ===========================================================================
create table public.staff (
  id          uuid primary key default gen_random_uuid(),
  salon_id    uuid not null references public.salons(id) on delete cascade,
  profile_id  uuid references public.profiles(id) on delete set null,  -- null = no login
  name        text not null,
  title       text,                              -- 'Senior Stylist', 'Barber', ...
  bio         text,
  photo_url   text,
  color       text,                              -- calendar colour, e.g. '#FF5A3C'
  is_active   boolean not null default true,
  accepts_online_booking boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.staff enable row level security;
create trigger staff_touch before update on public.staff for each row execute function public.touch_updated_at();
create index on public.staff (salon_id);

-- Active staff at a published salon are public (shown on the storefront).
create policy "staff: read public or member" on public.staff for select
  using (
    public.is_salon_member(salon_id)
    or (is_active and exists (select 1 from public.salons s where s.id = salon_id and s.is_published))
    or public.is_admin()
  );
create policy "staff: manager write" on public.staff for all
  using (public.is_salon_manager(salon_id)) with check (public.is_salon_manager(salon_id));

-- ===========================================================================
-- SERVICES
-- ===========================================================================
create table public.service_categories (
  id         uuid primary key default gen_random_uuid(),
  salon_id   uuid not null references public.salons(id) on delete cascade,
  name       text not null,
  sort_order int not null default 0
);
alter table public.service_categories enable row level security;
create index on public.service_categories (salon_id);
create policy "categories: read public or member" on public.service_categories for select
  using (
    public.is_salon_member(salon_id)
    or exists (select 1 from public.salons s where s.id = salon_id and s.is_published)
    or public.is_admin()
  );
create policy "categories: manager write" on public.service_categories for all
  using (public.is_salon_manager(salon_id)) with check (public.is_salon_manager(salon_id));

create table public.services (
  id            uuid primary key default gen_random_uuid(),
  salon_id      uuid not null references public.salons(id) on delete cascade,
  category_id   uuid references public.service_categories(id) on delete set null,
  name          text not null,
  description   text,
  duration_min  int not null default 30,        -- appointment length
  buffer_min    int not null default 0,         -- clean-up/turnaround after
  price         numeric(10,2) not null default 0,
  is_active     boolean not null default true,
  bookable_online boolean not null default true,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
alter table public.services enable row level security;
create trigger services_touch before update on public.services for each row execute function public.touch_updated_at();
create index on public.services (salon_id);

-- Active + online-bookable services at a published salon are public.
create policy "services: read public or member" on public.services for select
  using (
    public.is_salon_member(salon_id)
    or (is_active and bookable_online
        and exists (select 1 from public.salons s where s.id = salon_id and s.is_published))
    or public.is_admin()
  );
create policy "services: manager write" on public.services for all
  using (public.is_salon_manager(salon_id)) with check (public.is_salon_manager(salon_id));

-- Which staff can perform which service (many-to-many).
create table public.staff_services (
  staff_id   uuid not null references public.staff(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (staff_id, service_id)
);
alter table public.staff_services enable row level security;
-- Readable wherever the parent service is readable (reuse the services policy via join).
create policy "staff_services: read" on public.staff_services for select
  using (exists (select 1 from public.services sv where sv.id = service_id));
create policy "staff_services: manager write" on public.staff_services for all
  using (exists (select 1 from public.services sv where sv.id = service_id and public.is_salon_manager(sv.salon_id)))
  with check (exists (select 1 from public.services sv where sv.id = service_id and public.is_salon_manager(sv.salon_id)));

-- ===========================================================================
-- AVAILABILITY: recurring working hours + one-off time off
-- ===========================================================================
-- Weekly recurring hours per staff member. dow: 0=Sunday .. 6=Saturday.
-- Times are wall-clock in the salon's timezone.
create table public.working_hours (
  id         uuid primary key default gen_random_uuid(),
  salon_id   uuid not null references public.salons(id) on delete cascade,
  staff_id   uuid not null references public.staff(id) on delete cascade,
  dow        int  not null check (dow between 0 and 6),
  start_time time not null,
  end_time   time not null,
  check (end_time > start_time)
);
alter table public.working_hours enable row level security;
create index on public.working_hours (staff_id);
-- Public read so the storefront can compute slots (no customer data here).
create policy "hours: read public or member" on public.working_hours for select
  using (
    public.is_salon_member(salon_id)
    or exists (select 1 from public.salons s where s.id = salon_id and s.is_published)
    or public.is_admin()
  );
create policy "hours: manager write" on public.working_hours for all
  using (public.is_salon_manager(salon_id)) with check (public.is_salon_manager(salon_id));

-- One-off blocks (holidays, vacation, breaks). Overrides working_hours.
create table public.time_off (
  id         uuid primary key default gen_random_uuid(),
  salon_id   uuid not null references public.salons(id) on delete cascade,
  staff_id   uuid not null references public.staff(id) on delete cascade,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  reason     text,
  check (ends_at > starts_at)
);
alter table public.time_off enable row level security;
create index on public.time_off (staff_id, starts_at);
create policy "time_off: read public or member" on public.time_off for select
  using (
    public.is_salon_member(salon_id)
    or exists (select 1 from public.salons s where s.id = salon_id and s.is_published)
    or public.is_admin()
  );
create policy "time_off: manager write" on public.time_off for all
  using (public.is_salon_manager(salon_id)) with check (public.is_salon_manager(salon_id));

-- ===========================================================================
-- CUSTOMERS (private to the salon — NEVER public)
-- ===========================================================================
create table public.customers (
  id          uuid primary key default gen_random_uuid(),
  salon_id    uuid not null references public.salons(id) on delete cascade,
  name        text not null,
  email       text,
  phone       text,
  notes       text,                              -- staff-only notes / preferences
  marketing_opt_in boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.customers enable row level security;
create trigger customers_touch before update on public.customers for each row execute function public.touch_updated_at();
create index on public.customers (salon_id);
create index on public.customers (salon_id, email);

-- Customers are visible ONLY to salon members. The public booking flow creates
-- customers via the SECURITY DEFINER book_appointment RPC, not direct insert.
create policy "customers: member read"  on public.customers for select using (public.is_salon_member(salon_id));
create policy "customers: member write" on public.customers for all
  using (public.is_salon_member(salon_id)) with check (public.is_salon_member(salon_id));

-- ===========================================================================
-- APPOINTMENTS (private to the salon — NEVER public)
-- ===========================================================================
create table public.appointments (
  id           uuid primary key default gen_random_uuid(),
  salon_id     uuid not null references public.salons(id) on delete cascade,
  customer_id  uuid references public.customers(id) on delete set null,
  staff_id     uuid references public.staff(id) on delete set null,
  service_id   uuid references public.services(id) on delete set null,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  status       appointment_status not null default 'booked',
  source       appointment_source not null default 'manual',
  price        numeric(10,2),                    -- snapshot of price at booking time
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (ends_at > starts_at)
);
alter table public.appointments enable row level security;
create trigger appointments_touch before update on public.appointments for each row execute function public.touch_updated_at();
create index on public.appointments (salon_id, starts_at);
create index on public.appointments (staff_id, starts_at);

-- Appointments are visible ONLY to salon members. Online bookings are inserted
-- by the book_appointment RPC (security definer); manual bookings by members.
create policy "appointments: member read"  on public.appointments for select using (public.is_salon_member(salon_id));
create policy "appointments: member write" on public.appointments for all
  using (public.is_salon_member(salon_id)) with check (public.is_salon_member(salon_id));

-- ===================== 0002_booking_rpcs.sql =====================
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

-- ===================== 0003_customer_accounts.sql =====================
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

-- ===================== 0004_directory_listings.sql =====================
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

-- ===================== 0005_salon_socials.sql =====================
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

-- ===================== 0006_admin.sql =====================
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

-- ===================== 0007_salon_geo.sql =====================
-- ============================================================================
-- Glowup Book — salon coordinates (for the directory map view)
-- Backfilled for the NYC seed from NY Open Data; geocoded for new salons later.
-- ============================================================================

alter table public.salons add column if not exists lat double precision;
alter table public.salons add column if not exists lon double precision;
create index if not exists salons_geo_idx on public.salons (lat, lon);

-- ===================== 0008_profiles_favorites_reviews.sql =====================
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

-- ===================== 0009_employee_portfolio.sql =====================
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

-- ===================== 0010_booking_confirmation.sql =====================
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

-- ===================== 0011_reminded_at.sql =====================
-- ============================================================================
-- Glowup Book — track when a reminder email was sent (dedupe reminders).
-- ============================================================================
alter table public.appointments add column if not exists reminded_at timestamptz;

-- ===================== 0012_security_hardening.sql =====================
-- ===========================================================================
-- 0012_security_hardening.sql
-- Closes privilege-escalation and data-integrity holes found in review.
--
--   1. CRITICAL — any authenticated user could `update profiles set role='admin'`
--      on their own row and become a platform admin (RLS WITH CHECK cannot
--      restrict columns). Fixed with a BEFORE UPDATE trigger that pins `role`
--      for non-admins.
--   2. CRITICAL — handle_new_user() trusted client-supplied signup metadata for
--      `role`, so anyone could self-provision as 'admin'. Now 'admin' is never
--      accepted from metadata.
--   3. HIGH — reviews had no visit validation (any user could post unlimited
--      reviews for any salon). Now an insert requires a COMPLETED appointment
--      that belongs to the reviewer.
--
-- Idempotent: safe to run more than once.
-- ===========================================================================

-- ---- 1. Block self-escalation of profiles.role ----------------------------
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Only a platform admin may change anyone's role (including their own).
  -- For everyone else, silently keep the existing role so normal profile
  -- edits (name/phone/avatar) still succeed.
  if new.role is distinct from old.role and not public.is_admin() then
    new.role := old.role;
  end if;
  return new;
end; $$;

drop trigger if exists profiles_guard_role on public.profiles;
create trigger profiles_guard_role
  before update on public.profiles
  for each row execute function public.guard_profile_role();

-- ---- 2. Never provision an admin from signup metadata ----------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_role user_role;
begin
  -- Parse the requested role, but tolerate garbage and never allow 'admin'.
  begin
    v_role := coalesce(nullif(new.raw_user_meta_data->>'role','')::user_role, 'owner');
  exception when others then
    v_role := 'owner';
  end;
  if v_role = 'admin' then
    v_role := 'owner';
  end if;

  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    v_role
  );
  return new;
end; $$;

-- ---- 3. Reviews require a completed, owned appointment ---------------------
drop policy if exists "reviews: own write" on public.reviews;

-- Read stays public (salons show ratings).
-- Insert: must be your own account, tied to a COMPLETED appointment that is
-- yours and belongs to the salon being reviewed.
create policy "reviews: insert own completed" on public.reviews for insert
  with check (
    account_id = auth.uid()
    and appointment_id is not null
    and exists (
      select 1
      from public.appointments ap
      join public.customers c on c.id = ap.customer_id
      where ap.id = reviews.appointment_id
        and ap.salon_id = reviews.salon_id
        and c.account_id = auth.uid()
        and ap.status = 'completed'
    )
  );

-- Update / delete: only your own review.
create policy "reviews: update own" on public.reviews for update
  using (account_id = auth.uid()) with check (account_id = auth.uid());
create policy "reviews: delete own" on public.reviews for delete
  using (account_id = auth.uid());

notify pgrst, 'reload schema';

-- ===================== 0013_booking_privacy_and_admin_bootstrap.sql =====================
-- ===========================================================================
-- 0013_booking_privacy_and_admin_bootstrap.sql
--
--   1. book_appointment — two privacy fixes:
--      (a) Customer-record takeover: an existing walk-in customer row was linked
--          to the booker's account whenever the booking email matched, letting an
--          attacker claim a victim's record (and see their history) by booking
--          with the victim's email. Now a record is only linked to an account
--          when the booking email is the caller's OWN verified auth email.
--      (b) Cross-salon schedule enumeration: the "same person can't double-book"
--          check matched any free-text email across all salons with a distinct
--          error, leaking whether an email had an appointment at a probed time.
--          Now that check runs only for the logged-in caller's own identity.
--
--   2. guard_profile_role — allow trusted server-side sessions (SQL editor =
--      'postgres', service key = 'service_role') to change roles, so the first
--      platform admin can actually be provisioned. Browser API sessions
--      ('authenticated'/'anon') are still blocked from self-escalation.
--
-- Idempotent: safe to run more than once.
-- ===========================================================================

-- ---- 1. book_appointment ---------------------------------------------------
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
  v_auth_email text;
  v_email_is_mine boolean;
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

  -- Staff slot conflict (locks overlapping rows). Always enforced.
  perform 1 from public.appointments a
   where a.staff_id = p_staff and a.status in ('booked','confirmed','completed')
     and a.starts_at < v_end and a.ends_at > p_start for update;
  if found then raise exception 'Sorry, that slot was just taken. Please pick another time.'; end if;

  if exists (select 1 from public.time_off t where t.staff_id = p_staff and t.starts_at < v_end and t.ends_at > p_start) then
    raise exception 'That time is not available.';
  end if;

  -- The caller's verified email (only for logged-in users). Used to decide when
  -- a booking may be tied to their account — never trust the free-text field.
  if v_uid is not null then
    select email into v_auth_email from auth.users where id = v_uid;
  end if;
  v_email_is_mine := v_uid is not null and v_auth_email is not null
                     and lower(trim(coalesce(p_customer_email, ''))) = lower(v_auth_email);

  -- Same person can't hold two overlapping appointments across salons. Only
  -- enforced for the logged-in caller's own identity (account or verified email)
  -- so anonymous callers can't probe someone else's schedule via this error.
  if v_uid is not null and exists (
    select 1 from public.appointments a join public.customers cu on cu.id = a.customer_id
    where a.status in ('booked','confirmed','completed')
      and a.starts_at < v_end and a.ends_at > p_start
      and ( cu.account_id = v_uid
            or (v_auth_email is not null and lower(cu.email) = lower(v_auth_email)) )
  ) then
    raise exception 'You already have a booking that overlaps this time. Please pick another slot.';
  end if;

  -- Resolve the customer record for this booking.
  if v_uid is not null then
    select id into v_customer from public.customers where salon_id = v_salon.id and account_id = v_uid limit 1;
  end if;
  if v_customer is null and coalesce(trim(p_customer_email), '') <> '' then
    select id into v_customer from public.customers where salon_id = v_salon.id and lower(email) = lower(trim(p_customer_email)) limit 1;
  end if;
  if v_customer is null then
    insert into public.customers (salon_id, name, email, phone, account_id)
    values (v_salon.id, trim(p_customer_name), nullif(trim(p_customer_email), ''), nullif(trim(p_customer_phone), ''),
            -- Link to the account only when unambiguously the caller's own booking.
            case when v_uid is not null and (coalesce(trim(p_customer_email),'') = '' or v_email_is_mine)
                 then v_uid else null end)
    returning id into v_customer;
  elsif v_email_is_mine then
    -- Claim an existing walk-in record ONLY when the booking email is the
    -- caller's own verified email (prevents claiming another person's record).
    update public.customers set account_id = v_uid where id = v_customer and account_id is null;
  end if;

  insert into public.appointments (salon_id, customer_id, staff_id, service_id, starts_at, ends_at, status, source, price, notes)
  values (v_salon.id, v_customer, p_staff, p_service, p_start, v_end, 'booked', 'online', v_service.price, p_notes)
  returning id into v_appt;
  return v_appt;
end; $$;
grant execute on function public.book_appointment(text, uuid, uuid, timestamptz, text, text, text, text) to anon, authenticated;

-- ---- 2. guard_profile_role — allow trusted sessions to bootstrap admins -----
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Block role changes made through the public API (PostgREST runs as the
  -- 'authenticated'/'anon' role) unless the caller is already an admin. Trusted
  -- server-side sessions (SQL editor = 'postgres', Edge Functions with the
  -- service key = 'service_role') pass through, so the first admin can be set.
  if new.role is distinct from old.role
     and current_user in ('authenticated', 'anon')
     and not public.is_admin() then
    new.role := old.role;
  end if;
  return new;
end; $$;

notify pgrst, 'reload schema';

-- ===================== 0014_karaoke_and_djs.sql =====================
-- ============================================================================
-- Karaoke Bar Map — three listing categories on the listing (tenant) model
--
-- Design note: this project reuses the proven booking/CRM stack from the salon
-- template. The tenant table is still called `salons` internally, but every
-- listing is one of THREE categories, stored in the existing `business_type`:
--   'karaoke_bar'       — a dedicated karaoke bar / KTV-room spot
--   'bar_with_karaoke'  — a regular bar that also runs karaoke
--   'dj'                — a karaoke DJ (a person/service, not a venue)
--
-- The first two are venues (book a room / table for a time slot); a DJ is booked
-- for an event. DJs are modeled DISTINCTLY: each DJ listing carries a 1:1
-- `dj_profiles` row with fields a venue never uses (genres, travel radius, rate,
-- gear, mixes).
-- ============================================================================

-- Constrain business_type to the three known categories. (Existing template
-- values like 'hair' don't exist in a fresh Karaoke Bar Map database.)
alter table public.salons
  add constraint salons_category_chk
  check (business_type is null or business_type in
         ('karaoke_bar','bar_with_karaoke','dj'));

create index if not exists salons_category_idx on public.salons (business_type);

-- How karaoke works at a VENUE (null for DJ listings):
--   'open'    — open-mic / stage karaoke, you sing in front of the room
--   'in_room' — private KTV rooms / booths you rent
--   'both'    — offers open floor AND private rooms
alter table public.salons
  add column if not exists karaoke_type text
  check (karaoke_type is null or karaoke_type in ('open','in_room','both'));

-- ---------------------------------------------------------------------------
-- DJ-specific profile (1:1 with a salon row where business_type = 'dj').
-- Kept in its own table so venue rows stay clean and DJ fields can grow.
-- ---------------------------------------------------------------------------
create table if not exists public.dj_profiles (
  salon_id          uuid primary key references public.salons(id) on delete cascade,
  stage_name        text,
  -- A performer is a karaoke DJ, a KJ (karaoke host/jockey), or both. KJs and
  -- DJs share this one profile type and the same booking engine.
  performer_type    text    not null default 'dj'
                    check (performer_type in ('dj','kj','both')),
  genres            text[]  not null default '{}',   -- ['karaoke','top 40','hip hop','latin']
  base_city         text,                            -- where the DJ is based
  travel_radius_mi  int     not null default 25,     -- how far they'll travel
  willing_to_travel boolean not null default true,
  hourly_rate       numeric(10,2),                   -- typical rate (display only)
  min_hours         int     not null default 2,      -- minimum booking length
  provides_karaoke  boolean not null default true,   -- brings a karaoke rig?
  provides_sound    boolean not null default true,   -- brings PA / lights?
  years_experience  int,
  soundcloud        text,
  mixcloud          text,
  spotify           text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
alter table public.dj_profiles enable row level security;
create trigger dj_profiles_touch before update on public.dj_profiles
  for each row execute function public.touch_updated_at();

-- Readable wherever the parent listing is readable (published, unclaimed, or
-- you're a member/admin) — reuse the same visibility rule as salons.
create policy "dj_profiles: read with listing" on public.dj_profiles for select
  using (
    exists (
      select 1 from public.salons s
      where s.id = salon_id
        and (s.is_published or s.claimed = false
             or public.is_salon_member(s.id) or public.is_admin())
    )
  );

-- Only the listing's manager (owner/manager) can write the DJ profile.
create policy "dj_profiles: manager write" on public.dj_profiles for all
  using (public.is_salon_manager(salon_id))
  with check (public.is_salon_manager(salon_id));

-- ---------------------------------------------------------------------------
-- Convenience view: a DJ's listing + profile in one shot for the directory.
-- Only surfaces columns already public via RLS on the underlying tables.
-- ---------------------------------------------------------------------------
create or replace view public.dj_directory as
  select s.id, s.slug, s.name, s.city, s.about, s.logo_url, s.cover_url,
         s.lat, s.lon, s.is_published, s.claimed, s.instagram, s.website,
         d.stage_name, d.performer_type, d.genres, d.base_city, d.travel_radius_mi,
         d.willing_to_travel, d.hourly_rate, d.min_hours, d.years_experience
    from public.salons s
    join public.dj_profiles d on d.salon_id = s.id
   where s.business_type = 'dj';

-- ===================== 0015_keep_host_accounts.sql =====================
-- ============================================================================
-- Karaoke Bar Map — a host/KJ always keeps their account
--
-- A host (KJ) with a login is three things: an auth account + `profiles` row,
-- a `salon_members` link (dashboard access to a venue), and a `staff` row (the
-- venue's roster). Removing a host from ONE venue's list must:
--   • drop them from that venue's roster (`staff`)
--   • revoke that venue's dashboard access (`salon_members`, staff role only)
-- but must NEVER delete their account, their portfolio, or their membership at
-- any OTHER venue. This RPC enforces that guarantee atomically.
-- ============================================================================

create or replace function public.remove_staff(p_staff uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_salon uuid; v_profile uuid;
begin
  select salon_id, profile_id into v_salon, v_profile
    from public.staff where id = p_staff;
  if v_salon is null then
    raise exception 'Host not found.';
  end if;
  if not public.is_salon_manager(v_salon) then
    raise exception 'Only the venue owner/manager can remove a host.';
  end if;

  -- Off this venue's roster. (appointments.staff_id is ON DELETE SET NULL, so
  -- past bookings are kept but unassigned.)
  delete from public.staff where id = p_staff;

  -- Revoke this venue's dashboard access for the linked account — but only the
  -- 'staff' membership, so we never strip an owner/manager of their own venue.
  if v_profile is not null then
    delete from public.salon_members
     where salon_id = v_salon and profile_id = v_profile and member_role = 'staff';
  end if;

  -- Deliberately DO NOT touch public.profiles / auth.users. The host keeps their
  -- Karaoke Bar Map account, portfolio, and any other venues they belong to.
end; $$;

grant execute on function public.remove_staff(uuid) to authenticated;

-- ===================== data/seed_venues.sql =====================
-- Karaoke Bar Map — seed of unclaimed US karaoke venues (OpenStreetMap).
-- Generated by make_seed.py. Safe to re-run (on conflict do nothing by slug).

insert into public.salons
  (name, slug, business_type, karaoke_type, phone, address, city, website, lat, lon, claimed, source, is_published, currency, timezone)
values
  ('Recessions', 'recessions-28133', 'bar_with_karaoke', 'open', '+1 202-296-6686', '1823 L Street Northwest', 'North West, DC', 'https://www.recessionsdc.com/', 38.903892, -77.042733, false, 'osm', false, 'USD', 'America/New_York'),
  ('Club Mari''s / Mogura', 'club-mari-s-mogura-22287', 'bar_with_karaoke', 'open', '+1 415 6735636', '1825 Webster Street', null, null, 37.785114, -122.432186, false, 'osm', false, 'USD', 'America/New_York'),
  ('Homer''s Neighborhood Bar', 'homer-s-neighborhood-bar-41015', 'bar_with_karaoke', 'open', '+1-512-251-5554', '1779 Wells Branch Parkway', 'Austin, TX', 'https://homersneighborhoodbar.com/', 30.435597, -97.673859, false, 'osm', false, 'USD', 'America/New_York'),
  ('Shanghai Room', 'shanghai-room-37225', 'bar_with_karaoke', 'open', null, '8580 Greenwood Avenue North', 'Seattle, WA', 'https://www.theshanghairoom.com/', 47.692204, -122.355109, false, 'osm', false, 'USD', 'America/New_York'),
  ('Hula Hula', 'hula-hula-68499', 'bar_with_karaoke', 'open', '+1-206-284-5003', '1501 East Olive Way', 'Seattle, WA', 'http://hulahula.org/', 47.61792, -122.325942, false, 'osm', false, 'USD', 'America/New_York'),
  ('VIP Karaoke', 'vip-karaoke-80846', 'karaoke_bar', 'both', null, '964 Maple Road', 'Buffalo, NY', null, 42.991599, -78.751249, false, 'osm', false, 'USD', 'America/New_York'),
  ('Baranof', 'baranof-03644', 'bar_with_karaoke', 'open', null, '8549 Greenwood Avenue North', 'Seattle', null, 47.691803, -122.355569, false, 'osm', false, 'USD', 'America/New_York'),
  ('Goemon Izakaya', 'goemon-izakaya-25665', 'bar_with_karaoke', 'open', null, '3129 Clement Street', 'San Francisco', null, 37.781523, -122.492956, false, 'osm', false, 'USD', 'America/New_York'),
  ('Encore Karaoke and Sushi Lounge', 'encore-karaoke-and-sushi-lounge-44837', 'karaoke_bar', 'both', null, null, null, 'https://encorekaraokemn.com/', 44.962583, -93.241745, false, 'osm', false, 'USD', 'America/New_York'),
  ('Sid Gold''s Request Room', 'sid-gold-s-request-room-54896', 'bar_with_karaoke', 'open', '+1 929-260-1070', '1262 5th Street Northeast', null, 'https://sidgolds.com/washington-dc/', 38.907929, -76.998829, false, 'osm', false, 'USD', 'America/New_York'),
  ('Ginza', 'ginza-85099', 'bar_with_karaoke', 'open', null, '9616 Reisterstown Road', 'Owings Mills, MD', null, 39.403639, -76.762142, false, 'osm', false, 'USD', 'America/New_York'),
  ('7 Bamboo', '7-bamboo-35105', 'bar_with_karaoke', 'open', null, '162 Jackson Street', 'San Jose, CA', 'https://7bamboolounge.com/', 37.348474, -121.895006, false, 'osm', false, 'USD', 'America/New_York'),
  ('Professional Karaoke', 'professional-karaoke-27436', 'karaoke_bar', 'both', null, null, null, null, 37.298134, -121.839335, false, 'osm', false, 'USD', 'America/New_York'),
  ('High Note Karaoke Lounge', 'high-note-karaoke-lounge-53797', 'karaoke_bar', 'both', '+1 414 226 5852', '645 North James Lovell Street', 'Milwaukee', null, 43.03852, -87.92051, false, 'osm', false, 'USD', 'America/New_York'),
  ('Konet', 'konet-47391', 'karaoke_bar', 'both', null, null, null, null, 37.743182, -122.475375, false, 'osm', false, 'USD', 'America/New_York'),
  ('Mì Quảng Cô Thảo', 'm-qu-ng-c-th-o-27189', 'bar_with_karaoke', 'open', '+1-408-501-0011', '1560 North 4th Street', 'San Jose, CA', null, 37.366258, -121.908273, false, 'osm', false, 'USD', 'America/New_York'),
  ('Muzette', 'muzette-38502', 'bar_with_karaoke', 'open', null, null, null, null, 38.919803, -77.041513, false, 'osm', false, 'USD', 'America/New_York'),
  ('Cafe Nhớ', 'cafe-nh-25251', 'bar_with_karaoke', 'open', '+1 703-237-1121', '6757 Wilson Boulevard', 'VA', 'https://edencenter.com/stores/cafe-nho/', 38.874375, -77.154224, false, 'osm', false, 'USD', 'America/New_York'),
  ('Hoa Viên Quán', 'hoa-vi-n-qu-n-25264', 'bar_with_karaoke', 'open', null, '6757 Wilson Boulevard', 'Falls Church, VA', null, 38.874538, -77.154007, false, 'osm', false, 'USD', 'America/New_York'),
  ('Le Mirage', 'le-mirage-25265', 'bar_with_karaoke', 'open', null, 'Wilson Boulevard', 'Falls Church, VA', null, 38.87448, -77.153983, false, 'osm', false, 'USD', 'America/New_York'),
  ('Sweet Jane''s', 'sweet-jane-s-20087', 'bar_with_karaoke', 'open', '+1-718-381-2031', '64-02 68th Avenue', 'Glendale, NY', null, 40.705619, -73.894287, false, 'osm', false, 'USD', 'America/New_York'),
  ('Chicago''s Pub & Billiards', 'chicago-s-pub-billiards-49024', 'bar_with_karaoke', 'open', '+1-519-621-2222', '1 Hespeler Road', null, 'https://www.chicagopubcambridge.com/', 43.374736, -80.317681, false, 'osm', false, 'USD', 'America/New_York'),
  ('Liquor Lounge Cafe', 'liquor-lounge-cafe-95821', 'bar_with_karaoke', 'open', '+1 305-672-7171', '1560 Collins Avenue', 'Miami Beach, FL', null, 25.78904, -80.13048, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Crescent', 'the-crescent-73723', 'bar_with_karaoke', 'open', null, '1413 East Olive Way', 'Seattle, WA', null, 47.617466, -122.326305, false, 'osm', false, 'USD', 'America/New_York'),
  ('Walt''s Inn', 'walt-s-inn-01048', 'bar_with_karaoke', 'open', '+1 410-327-1495', '3201 Odonnell Street', 'Baltimore, MD', 'http://www.waltsinn.com/', 39.280227, -76.570967, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Otheroom', 'the-otheroom-67432', 'bar_with_karaoke', 'open', '+1-212-645-9758', '143 Perry Street', null, 'https://theotheroomnyc.com/', 40.734943, -74.008038, false, 'osm', false, 'USD', 'America/New_York'),
  ('Southgate Roller Rink', 'southgate-roller-rink-67415', 'bar_with_karaoke', 'open', '+1-206-707-6949', '9646 17th Avenue Southwest', 'Seattle, WA', null, 47.516049, -122.355973, false, 'osm', false, 'USD', 'America/New_York'),
  ('5 Bar Karaoke Lounge', '5-bar-karaoke-lounge-54089', 'karaoke_bar', 'both', '+1 212-594-6644', '38 West 32nd Street', 'New York, NY', 'https://www.5barkaraoke.com', 40.747787, -73.987423, false, 'osm', false, 'USD', 'America/New_York'),
  ('Century Ktu', 'century-ktu-38430', 'bar_with_karaoke', 'open', '+1-303-750-0059', '1555 South Havana Street', 'Aurora, CO', null, 39.688534, -104.867712, false, 'osm', false, 'USD', 'America/New_York'),
  ('Alice’s Lounge', 'alice-s-lounge-14741', 'bar_with_karaoke', 'open', '+1-773-279-9382', '3420 West Belmont Avenue', 'Chicago, IL', null, 41.939341, -87.717258, false, 'osm', false, 'USD', 'America/New_York'),
  ('Nam''s Noodle', 'nam-s-noodle-79986', 'bar_with_karaoke', 'open', null, '1336 Regent Street', 'Madison, WI', 'https://www.namnoodle.com/', 43.067876, -89.408457, false, 'osm', false, 'USD', 'America/New_York'),
  ('Goemon & Kakigori', 'goemon-kakigori-34325', 'bar_with_karaoke', 'open', '+1 415-756-9986', '3141 Clement Street', null, null, 37.781525, -122.493123, false, 'osm', false, 'USD', 'America/New_York'),
  ('Monroe''s Nightclub & Grill', 'monroe-s-nightclub-grill-47492', 'bar_with_karaoke', 'open', null, 'Hilltop Drive', null, null, 40.580162, -122.357387, false, 'osm', false, 'USD', 'America/New_York'),
  ('Tokki', 'tokki-99471', 'bar_with_karaoke', 'open', null, '182 East Cheyenne Mountain Boulevard', 'Colorado Springs, CO', 'https://tokkicolorado.com/', 38.790487, -104.823402, false, 'osm', false, 'USD', 'America/New_York'),
  ('Bull Shooters', 'bull-shooters-94497', 'bar_with_karaoke', 'open', '+1-602-441-2447', '3337 West Peoria Avenue', 'Phoenix, AZ', 'https://bullshooters-az.com', 33.580691, -112.132775, false, 'osm', false, 'USD', 'America/New_York'),
  ('Chuan Du Hot Pot', 'chuan-du-hot-pot-86159', 'bar_with_karaoke', 'open', '+1-203-745-4127', '27 Temple Street', 'New Haven, CT', 'https://newhavenhotpot.wixsite.com/mysite/', 41.30417, -72.928601, false, 'osm', false, 'USD', 'America/New_York'),
  ('Music Tunnel KTV Cafe', 'music-tunnel-ktv-cafe-34644', 'karaoke_bar', 'in_room', '+1 408-446-0888', '1132 South De Anza Boulevard', 'San Jose', 'https://www.musictunnelktv.com/', 37.30577, -122.031694, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke Bleu', 'karaoke-bleu-70511', 'karaoke_bar', 'both', null, null, null, null, 34.039826, -118.442501, false, 'osm', false, 'USD', 'America/New_York'),
  ('Khartoum', 'khartoum-99956', 'bar_with_karaoke', 'open', null, '300 Orchard City Drive', 'Campbell, CA', null, 37.285789, -121.943847, false, 'osm', false, 'USD', 'America/New_York'),
  ('Festa Wine & Cocktail Lounge', 'festa-wine-cocktail-lounge-92442', 'bar_with_karaoke', 'open', '+1 415 5675866', null, null, 'https://festalounge.com/', 37.785178, -122.431609, false, 'osm', false, 'USD', 'America/New_York'),
  ('Pagoda', 'pagoda-73173', 'bar_with_karaoke', 'open', null, '1704 Post Street', 'San Francisco, CA', null, 37.785714, -122.429999, false, 'osm', false, 'USD', 'America/New_York'),
  ('Privé', 'priv-09719', 'bar_with_karaoke', 'open', '+1-604-336-9330', '1001 West Broadway', null, 'https://privevancouver.com/', 49.263639, -123.126978, false, 'osm', false, 'USD', 'America/New_York'),
  ('K One Karaoke', 'k-one-karaoke-82873', 'karaoke_bar', 'both', '+1-212-925-1999', null, null, null, 40.717342, -73.995048, false, 'osm', false, 'USD', 'America/New_York'),
  ('Rising Tides', 'rising-tides-50976', 'bar_with_karaoke', 'open', null, '9909 Garland Road', null, 'https://risingtidesbar.com/', 32.837633, -96.69786, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Brass Monkey', 'the-brass-monkey-94759', 'bar_with_karaoke', 'open', null, null, null, null, 34.061059, -118.298909, false, 'osm', false, 'USD', 'America/New_York'),
  ('Gaythering', 'gaythering-97279', 'bar_with_karaoke', 'open', '+1 786-284-1176', '1409 Lincoln Road', 'Miami Beach, FL', 'https://www.gaythering.com/bar.html', 25.790564, -80.143828, false, 'osm', false, 'USD', 'America/New_York'),
  ('Tom''s Burgers', 'tom-s-burgers-89005', 'bar_with_karaoke', 'open', '+1-323-722-1051', '1501 Olympic Boulevard', null, null, 34.008442, -118.117812, false, 'osm', false, 'USD', 'America/New_York'),
  ('Park Center Lounge', 'park-center-lounge-12015', 'bar_with_karaoke', 'open', null, null, null, null, 39.914693, -105.008174, false, 'osm', false, 'USD', 'America/New_York'),
  ('L''Astral 2000', 'l-astral-2000-04494', 'bar_with_karaoke', 'open', '+1 514 523 1447', '1845 Rue Ontario Est', null, null, 45.526492, -73.559036, false, 'osm', false, 'USD', 'America/New_York'),
  ('161 Lafayette', '161-lafayette-71796', 'bar_with_karaoke', 'open', null, '161 Lafayette Street', null, 'https://www.161lafayettebar.com', 40.719814, -73.999074, false, 'osm', false, 'USD', 'America/New_York'),
  ('Papi Chulo', 'papi-chulo-05766', 'bar_with_karaoke', 'open', '+1-514-721-8485', '3388 Rue Jean-Talon Est', null, 'https://restaurantpapichulo.com/', 45.560366, -73.596759, false, 'osm', false, 'USD', 'America/New_York'),
  ('Bistro Chez Alberto', 'bistro-chez-alberto-05767', 'bar_with_karaoke', 'open', null, '3380 Rue Jean-Talon Est', null, 'http://chezalberto.com/', 45.560308, -73.596829, false, 'osm', false, 'USD', 'America/New_York'),
  ('Pub les Sportifs', 'pub-les-sportifs-79657', 'bar_with_karaoke', 'open', '+1 514 521 2046', '2300 Rue Ontario Est', null, null, 45.530476, -73.554887, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Square Deal', 'the-square-deal-82498', 'bar_with_karaoke', 'open', '+1 507 720 6062', null, null, null, 44.163092, -94.006651, false, 'osm', false, 'USD', 'America/New_York'),
  ('Astro Karaoke', 'astro-karaoke-42386', 'karaoke_bar', 'both', '+1-310-530-4800', '2150 Lomita Boulevard', null, 'https://astrokaraoke.com/', 33.801828, -118.319023, false, 'osm', false, 'USD', 'America/New_York'),
  ('OTR Funplex', 'otr-funplex-47948', 'bar_with_karaoke', 'open', '+1 513-675-0525', '1112 Race Street', 'Cincinnati, OH', 'https://www.otrfunplex.com/', 39.107532, -84.516075, false, 'osm', false, 'USD', 'America/New_York'),
  ('Planet Rose', 'planet-rose-82579', 'bar_with_karaoke', 'open', null, '219 Avenue A', 'New York', null, 40.730147, -73.98075, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Bangkok Lounge', 'the-bangkok-lounge-22272', 'bar_with_karaoke', 'open', '+1-843-203-4322', '353 King Street', 'Charleston, SC', 'https://www.thebangkoklounge.com', 32.784933, -79.935859, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Basket Case Pub', 'the-basket-case-pub-69001', 'bar_with_karaoke', 'open', '+1-309-676-2273', '610 West Main Street', 'Peoria, IL', null, 40.699356, -89.602579, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Shores Bar and Restaurant', 'the-shores-bar-and-restaurant-07906', 'bar_with_karaoke', 'open', null, '1031 Harbor Boulevard', 'Oxnard, CA', null, 34.190975, -119.23934, false, 'osm', false, 'USD', 'America/New_York'),
  ('Lane 33 Bar & Grill', 'lane-33-bar-grill-18867', 'bar_with_karaoke', 'open', null, null, null, null, 34.192986, -118.57184, false, 'osm', false, 'USD', 'America/New_York'),
  ('Club Ya-Mang', 'club-ya-mang-81403', 'bar_with_karaoke', 'open', '+1 702-792-5500', '953 East Sahara Avenue', 'Las Vegas, NV', null, 36.143468, -115.143416, false, 'osm', false, 'USD', 'America/New_York'),
  ('Assa Karaoke', 'assa-karaoke-96920', 'karaoke_bar', 'both', '+1 725-201-2074', '953 East Sahara Avenue', 'Las Vegas, NV', null, 36.14318, -115.144172, false, 'osm', false, 'USD', 'America/New_York'),
  ('Paradise Isle', 'paradise-isle-49779', 'bar_with_karaoke', 'open', null, '9568 Las Tunas Drive', 'Temple City, CA', null, 34.106364, -118.061357, false, 'osm', false, 'USD', 'America/New_York'),
  ('Dave''s Pubb', 'dave-s-pubb-36162', 'bar_with_karaoke', 'open', '+1 208-456-2789', null, null, 'https://davestetonia.com', 43.814664, -111.160424, false, 'osm', false, 'USD', 'America/New_York'),
  ('8090 KTV', '8090-ktv-82573', 'karaoke_bar', 'in_room', null, null, null, null, 43.652847, -79.398895, false, 'osm', false, 'USD', 'America/New_York'),
  ('Effie''s Restaurant and Bar', 'effie-s-restaurant-and-bar-29990', 'bar_with_karaoke', 'open', '+1-408-374-3400', '331 West Hacienda Avenue', 'Campbell, CA', 'https://www.effiesrestaurantandbar.com/', 37.269536, -121.956946, false, 'osm', false, 'USD', 'America/New_York'),
  ('Metro Sportz Bar', 'metro-sportz-bar-95659', 'bar_with_karaoke', 'open', null, null, 'Phoenix', null, 33.579404, -112.11868, false, 'osm', false, 'USD', 'America/New_York'),
  ('Mango''s Tropical Cafe Orlando', 'mango-s-tropical-cafe-orlando-19619', 'bar_with_karaoke', 'open', '+1-407-673-4422', '8126 International Drive', 'Orlando, FL', 'https://mangos.com/mangos-orlando/', 28.448123, -81.471741, false, 'osm', false, 'USD', 'America/New_York'),
  ('Revive', 'revive-54105', 'bar_with_karaoke', 'open', null, '90 King Street North', null, null, 43.468257, -80.522884, false, 'osm', false, 'USD', 'America/New_York'),
  ('Insa', 'insa-45981', 'bar_with_karaoke', 'open', '+1-718-855-2620', '328 Douglass Street', null, 'https://www.insabrooklyn.com/', 40.67943, -73.982683, false, 'osm', false, 'USD', 'America/New_York'),
  ('Mango''s Tropical Cafe Miami Beach', 'mango-s-tropical-cafe-miami-beach-02204', 'bar_with_karaoke', 'open', '+1 305-673-4422', '900 Ocean Drive', 'Miami Beach, FL', 'https://miami.mangos.com/', 25.779419, -80.131164, false, 'osm', false, 'USD', 'America/New_York'),
  ('Soho KTV & Bar', 'soho-ktv-bar-29952', 'karaoke_bar', 'in_room', null, '32-03 Farrington Street', 'Flushing, NY', null, 40.767682, -73.832876, false, 'osm', false, 'USD', 'America/New_York'),
  ('Family Karaoke', 'family-karaoke-47927', 'karaoke_bar', 'both', null, '11433 Goodnight Lane', null, 'https://familykaraokedfw.com/', 32.89681, -96.902543, false, 'osm', false, 'USD', 'America/New_York'),
  ('Voicebox Karaoke', 'voicebox-karaoke-70053', 'karaoke_bar', 'both', '+1-503-303-8220', '734 Southeast 6th Avenue', 'Portland, OR', 'https://voiceboxkaraoke.com/', 45.517527, -122.65943, false, 'osm', false, 'USD', 'America/New_York'),
  ('Galaxy KTV', 'galaxy-ktv-45879', 'karaoke_bar', 'in_room', null, null, null, null, 41.508936, -81.668782, false, 'osm', false, 'USD', 'America/New_York'),
  ('Casey Jones Tavern', 'casey-jones-tavern-52800', 'bar_with_karaoke', 'open', null, null, null, null, 41.463757, -81.790787, false, 'osm', false, 'USD', 'America/New_York'),
  ('Broken Glass Bar', 'broken-glass-bar-01417', 'bar_with_karaoke', 'open', '+1 458 205 8243', '2222 Highway 99 North', 'Eugene, OR', null, 44.090677, -123.161095, false, 'osm', false, 'USD', 'America/New_York'),
  ('Mom''s Bar', 'mom-s-bar-36200', 'bar_with_karaoke', 'open', null, '614 University Avenue', 'Madison, WI', null, 43.073433, -89.396405, false, 'osm', false, 'USD', 'America/New_York'),
  ('168 Crab & Karaoke', '168-crab-karaoke-29977', 'karaoke_bar', 'both', '+1-248-616-0168', '32415 John R Road', 'Madison Heights, MI', 'https://www.168crab.com/', 42.531274, -83.107971, false, 'osm', false, 'USD', 'America/New_York'),
  ('Sinatra (Bay & Karaoke)', 'sinatra-bay-karaoke-50413', 'karaoke_bar', 'both', null, null, null, null, 24.162534, -110.314595, false, 'osm', false, 'USD', 'America/New_York'),
  ('K Karaoke Bar', 'k-karaoke-bar-26851', 'karaoke_bar', 'both', null, '2110 Rue Crescent', null, null, 45.498273, -73.578289, false, 'osm', false, 'USD', 'America/New_York'),
  ('Canary Roost Karaoke Bar', 'canary-roost-karaoke-bar-47839', 'karaoke_bar', 'both', '+1-512-836-6360', '11900 Metric Boulevard', 'Austin, TX', 'https://canary-roost.business.site/', 30.400485, -97.703962, false, 'osm', false, 'USD', 'America/New_York'),
  ('Kroaky''s Karaoke', 'kroaky-s-karaoke-92974', 'karaoke_bar', 'both', null, 'South Tamiami Trail', null, 'http://www.kroakys.com', 27.29035, -82.531112, false, 'osm', false, 'USD', 'America/New_York'),
  ('Gamba Karaoke', 'gamba-karaoke-54946', 'karaoke_bar', 'both', null, '19990 East Homestead Road', 'Cupertino, CA', null, 37.336887, -122.02292, false, 'osm', false, 'USD', 'America/New_York'),
  ('Novabox Karaoke', 'novabox-karaoke-40329', 'karaoke_bar', 'both', null, '4744 University Way Northeast', 'Seattle', null, 47.66441, -122.312929, false, 'osm', false, 'USD', 'America/New_York'),
  ('Boite a Karaoke (La)', 'boite-a-karaoke-la-49690', 'karaoke_bar', 'both', null, null, null, null, 45.491642, -73.582033, false, 'osm', false, 'USD', 'America/New_York'),
  ('Family Karaoke', 'family-karaoke-36848', 'karaoke_bar', 'both', '+1-303-564-9741', '2760 South Havana Street', 'Aurora, CO', 'https://www.yelp.com/biz/family-karaoke-aurora', 39.666336, -104.864396, false, 'osm', false, 'USD', 'America/New_York'),
  ('Pandora Karaoke Bar', 'pandora-karaoke-bar-35420', 'karaoke_bar', 'both', null, null, null, null, 37.784121, -122.410508, false, 'osm', false, 'USD', 'America/New_York'),
  ('Glitter Karaoke', 'glitter-karaoke-84121', 'karaoke_bar', 'both', null, '2621 Milam Street', 'Houston, TX', null, 29.745745, -95.376208, false, 'osm', false, 'USD', 'America/New_York'),
  ('Miki''s Karaoke Bar', 'miki-s-karaoke-bar-06300', 'karaoke_bar', 'both', null, '2230 Frankfort Avenue', 'Louisville, KY', null, 38.253344, -85.704826, false, 'osm', false, 'USD', 'America/New_York'),
  ('Mac''s Karaoke Bar', 'mac-s-karaoke-bar-91005', 'karaoke_bar', 'both', null, '828 Lane Allen Road', 'Lexington, KY', null, 38.029143, -84.541455, false, 'osm', false, 'USD', 'America/New_York'),
  ('Encore Karaoke', 'encore-karaoke-48154', 'karaoke_bar', 'both', null, '1550 Fl 2 California Street', 'San Francisco, CA', null, 37.790855, -122.420037, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke & Screen Golf', 'karaoke-screen-golf-46455', 'karaoke_bar', 'both', '+1-315-446-5852', '2743 Erie Boulevard East', 'Syracuse, NY', 'https://www.biwonsyracuse.com/palace-music-studio.html', 43.0553, -76.096596, false, 'osm', false, 'USD', 'America/New_York'),
  ('Ginza BBQ Lounge & Karaoke', 'ginza-bbq-lounge-karaoke-42699', 'karaoke_bar', 'both', null, '524 8th Street Southeast', 'Washington, DC', 'https://www.ginzaktv.com/', 38.881838, -76.994574, false, 'osm', false, 'USD', 'America/New_York'),
  ('Tasty Time 425 & KTV Karaoke Lounge', 'tasty-time-425-ktv-karaoke-lounge-68421', 'karaoke_bar', 'in_room', '+1-425-644-5000', null, null, null, 47.629914, -122.154797, false, 'osm', false, 'USD', 'America/New_York'),
  ('K-mix Karaoke & Bar', 'k-mix-karaoke-bar-25124', 'karaoke_bar', 'both', null, '3400 Westgate Drive', 'Durham, NC', null, 35.964936, -78.96217, false, 'osm', false, 'USD', 'America/New_York'),
  ('Studio 10 Karaoke Box', 'studio-10-karaoke-box-12837', 'karaoke_bar', 'both', '+1-503-746-5255', '9955 Southwest Beaverton Hillsdale Highway', 'Beaverton, OR', null, 45.486833, -122.780216, false, 'osm', false, 'USD', 'America/New_York'),
  ('La Frontera Steak House and Karaoke Bar', 'la-frontera-steak-house-and-karaoke-bar-56703', 'karaoke_bar', 'both', null, '4745 Federal Boulevard', 'Denver, CO', null, 39.782925, -105.02567, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke City', 'karaoke-city-12182', 'karaoke_bar', 'both', '+1 646-791-8318', '22 West 32nd Street', null, 'http://www.karaokecitynyc.com/', 40.747499, -73.986946, false, 'osm', false, 'USD', 'America/New_York'),
  ('Voice Karaoke Bar & Lounge', 'voice-karaoke-bar-lounge-01045', 'karaoke_bar', 'both', null, null, null, null, 29.892362, -95.684482, false, 'osm', false, 'USD', 'America/New_York'),
  ('YZ''s KTV Karaoke Cafe', 'yz-s-ktv-karaoke-cafe-59023', 'karaoke_bar', 'in_room', null, '1350 South Longmore', 'Mesa, AZ', null, 33.389044, -111.864668, false, 'osm', false, 'USD', 'America/New_York'),
  ('Offkey Karaoke Lounge & Suites', 'offkey-karaoke-lounge-suites-82718', 'karaoke_bar', 'both', null, null, null, null, 39.052671, -94.592179, false, 'osm', false, 'USD', 'America/New_York'),
  ('Voko Karaoke', 'voko-karaoke-60146', 'karaoke_bar', 'both', null, '14561 Red Hill Avenue', 'Tustin', null, 33.727366, -117.822689, false, 'osm', false, 'USD', 'America/New_York'),
  ('Friend''s Karaoke Bar', 'friend-s-karaoke-bar-24389', 'karaoke_bar', 'both', null, '1211 West Battlefield Road', 'Springfield, MO', null, 37.160805, -93.308328, false, 'osm', false, 'USD', 'America/New_York'),
  ('Millennium Karaoke', 'millennium-karaoke-45850', 'karaoke_bar', 'both', null, '4451 Number 3 Road', 'Richmond', null, 49.18121, -123.137011, false, 'osm', false, 'USD', 'America/New_York'),
  ('Rumours Karaoke Cafe', 'rumours-karaoke-cafe-90182', 'karaoke_bar', 'both', '+1-720-476-6360', '450 East 17th Avenue', 'Denver, CO', 'https://rumourskaraokecafe.com/', 39.743119, -104.981299, false, 'osm', false, 'USD', 'America/New_York'),
  ('Voicebox Karaoke Lounge', 'voicebox-karaoke-lounge-51571', 'karaoke_bar', 'both', null, '2601 Walnut Street', 'Denver, CO', null, 39.759554, -104.986317, false, 'osm', false, 'USD', 'America/New_York'),
  ('Mua Bui Karaoke', 'mua-bui-karaoke-00156', 'karaoke_bar', 'both', null, null, null, null, 43.669652, -79.483018, false, 'osm', false, 'USD', 'America/New_York'),
  ('Shout Karaoke', 'shout-karaoke-23661', 'karaoke_bar', 'both', null, null, null, null, 43.779471, -79.415925, false, 'osm', false, 'USD', 'America/New_York'),
  ('Lincoln Karaoke', 'lincoln-karaoke-36861', 'karaoke_bar', 'both', '+1-773-895-2299', '5526 North Lincoln Avenue', 'Chicago, IL', 'https://www.lincolnkaraokechicago.com/', 41.981885, -87.69361, false, 'osm', false, 'USD', 'America/New_York'),
  ('N Dolphin Karaoke', 'n-dolphin-karaoke-05316', 'karaoke_bar', 'both', null, null, null, null, 43.77843, -79.414815, false, 'osm', false, 'USD', 'America/New_York'),
  ('Vermont Karaoke and Billiards', 'vermont-karaoke-and-billiards-15773', 'karaoke_bar', 'both', '+1-213-385-3337', '191 South Vermont Avenue', 'Los Angeles, CA', null, 34.07045, -118.292005, false, 'osm', false, 'USD', 'America/New_York'),
  ('Revolution Karaoke', 'revolution-karaoke-53485', 'karaoke_bar', 'both', null, '400 Jefferson Road', 'Rochester, NY', null, 43.090721, -77.642395, false, 'osm', false, 'USD', 'America/New_York'),
  ('Greenlight Korean Pub & Karaoke', 'greenlight-korean-pub-karaoke-49074', 'karaoke_bar', 'both', '+1-872-806-2014', '2519 West Peterson Avenue', 'Chicago, IL', 'https://www.greenlightchicago.com/', 41.990226, -87.692936, false, 'osm', false, 'USD', 'America/New_York'),
  ('Sakura Karaoke Bar', 'sakura-karaoke-bar-26820', 'karaoke_bar', 'both', '+1-312-326-9168', '234 West Cermak Road', 'Chicago, IL', 'https://www.sakurakaraokebar.com/', 41.853146, -87.63316, false, 'osm', false, 'USD', 'America/New_York'),
  ('Rory Lake’s Karaoke Dreams', 'rory-lake-s-karaoke-dreams-81325', 'karaoke_bar', 'both', '+1-773-278-0093', '1824 West Cortland Street', 'Chicago, IL', 'https://www.rorylakepresents.com/', 41.916227, -87.673774, false, 'osm', false, 'USD', 'America/New_York'),
  ('No.18 Karaoke', 'no-18-karaoke-47995', 'karaoke_bar', 'both', '+1-312-600-9184', '2201 South Wentworth Avenue', 'Chicago, IL', 'https://www.no18karaoke.com/', 41.852633, -87.63174, false, 'osm', false, 'USD', 'America/New_York'),
  ('Gorhe Gorhe Karaoke', 'gorhe-gorhe-karaoke-27506', 'karaoke_bar', 'both', '+1-416-916-2720', null, null, null, 43.663811, -79.417759, false, 'osm', false, 'USD', 'America/New_York'),
  ('Tang Karaoke & BBQ', 'tang-karaoke-bbq-42633', 'karaoke_bar', 'both', '+1-860-477-1264', '33 Wilbur Cross Way', 'Storrs, CT', 'https://www.tangktvuconn.com/', 41.803703, -72.24134, false, 'osm', false, 'USD', 'America/New_York'),
  ('Inhabit karaoke lounge', 'inhabit-karaoke-lounge-34440', 'karaoke_bar', 'both', null, null, null, null, 40.715717, -73.993492, false, 'osm', false, 'USD', 'America/New_York'),
  ('Monster L Karaoke', 'monster-l-karaoke-89560', 'karaoke_bar', 'both', '+1-604-821-1800', '8400 Alexandra Road', 'Richmond', 'https://monster-l-karaoke.business.site/', 49.177717, -123.130541, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke', 'karaoke-65520', 'karaoke_bar', 'both', null, '418 South Military Avenue', 'Green Bay', null, 44.525846, -88.063248, false, 'osm', false, 'USD', 'America/New_York'),
  ('Marcelina''s Filipino Cuisine and Karaoke Bar', 'marcelina-s-filipino-cuisine-and-karaoke-bar-41459', 'karaoke_bar', 'both', '+1-647-350-1200', '355 Wilson Avenue', 'North York', 'https://marcelinasfilipinocuisine.com/', 43.736533, -79.436816, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke', 'karaoke-33030', 'karaoke_bar', 'both', null, '2980 Gallows Road', 'Fairfax, VA', null, 38.869783, -77.229232, false, 'osm', false, 'USD', 'America/New_York'),
  ('Starz Karaoke Lounge', 'starz-karaoke-lounge-32019', 'karaoke_bar', 'both', null, null, null, null, 33.411816, -86.663797, false, 'osm', false, 'USD', 'America/New_York'),
  ('Reno''s Karaoke and Pool', 'reno-s-karaoke-and-pool-80648', 'karaoke_bar', 'both', null, '20810 Gulf Freeway', 'Webster, TX', null, 29.523969, -95.129772, false, 'osm', false, 'USD', 'America/New_York'),
  ('Rehab Karaoke', 'rehab-karaoke-00188', 'karaoke_bar', 'both', null, '512 North Chaparral Street', 'Corpus Christi, TX', null, 27.796561, -97.393734, false, 'osm', false, 'USD', 'America/New_York'),
  ('EKO Karaoke Lounge', 'eko-karaoke-lounge-12689', 'karaoke_bar', 'both', null, null, null, null, 33.859768, -117.996963, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke-7 Nights', 'karaoke-7-nights-74751', 'karaoke_bar', 'both', null, null, null, null, 39.760375, -86.077109, false, 'osm', false, 'USD', 'America/New_York'),
  ('Spotlight Karaoke', 'spotlight-karaoke-57163', 'karaoke_bar', 'both', null, '5901 Westheimer Road', 'Houston, TX', null, 29.736921, -95.485428, false, 'osm', false, 'USD', 'America/New_York'),
  ('Spicy Palace Karaoke Bar', 'spicy-palace-karaoke-bar-78464', 'karaoke_bar', 'both', '+1-647-330-6848', null, null, null, 43.254582, -79.862946, false, 'osm', false, 'USD', 'America/New_York'),
  ('Knox Box Karaoke Bar', 'knox-box-karaoke-bar-48213', 'karaoke_bar', 'both', null, null, null, null, 35.964894, -83.917882, false, 'osm', false, 'USD', 'America/New_York'),
  ('Culver Karaoke', 'culver-karaoke-31019', 'karaoke_bar', 'both', null, null, null, null, 34.02157, -118.402568, false, 'osm', false, 'USD', 'America/New_York'),
  ('Zodiac Karaoke and Pub | 酒吧 夜店 KTV', 'zodiac-karaoke-and-pub-ktv-17301', 'karaoke_bar', 'in_room', '+1 604 428 9908', '8191 Alexandra Road', 'Richmond', null, 49.178496, -123.133352, false, 'osm', false, 'USD', 'America/New_York'),
  ('El Damazo Restaurant & Karaoke', 'el-damazo-restaurant-karaoke-42870', 'karaoke_bar', 'both', null, null, null, null, 38.729267, -77.473265, false, 'osm', false, 'USD', 'America/New_York'),
  ('Star Karaoke', 'star-karaoke-30838', 'karaoke_bar', 'both', '+1-217-574-5211', '1503 Lyndhurst Alley', 'Savoy, IL', 'https://www.orderstarkaraoke.com/', 40.073555, -88.250834, false, 'osm', false, 'USD', 'America/New_York'),
  ('K-ROK Korean BBQ & Karaoke', 'k-rok-korean-bbq-karaoke-65897', 'karaoke_bar', 'both', '+1-616-369-5765', '169 Louis Campau Promenade Northwest', 'Grand Rapids, MI', 'https://www.krokgr.com', 42.965504, -85.673091, false, 'osm', false, 'USD', 'America/New_York'),
  ('Tenjim Yokocho: Karaoke & Bar', 'tenjim-yokocho-karaoke-bar-47413', 'karaoke_bar', 'both', null, null, null, null, 43.665706, -79.35071, false, 'osm', false, 'USD', 'America/New_York'),
  ('Planet Rose Karaoke Bar', 'planet-rose-karaoke-bar-20380', 'karaoke_bar', 'both', null, '2801 Pacific Avenue', 'Atlantic City, NJ', null, 39.353346, -74.446027, false, 'osm', false, 'USD', 'America/New_York'),
  ('K-Pub Korean Cuisine & Karaoke', 'k-pub-korean-cuisine-karaoke-66275', 'karaoke_bar', 'both', null, '12233 Ranch Road 620 North', 'Austin, TX', null, 30.461513, -97.814999, false, 'osm', false, 'USD', 'America/New_York'),
  ('Beyond Karaoke', 'beyond-karaoke-53757', 'karaoke_bar', 'both', null, '530 4th Street', 'Bremerton, WA', 'beyond-karaoke.com', 47.565901, -122.627828, false, 'osm', false, 'USD', 'America/New_York'),
  ('Young St Karaoke Lounge', 'young-st-karaoke-lounge-70334', 'karaoke_bar', 'both', null, '1177 Burnhamthorpe Road West', null, null, 43.567511, -79.659515, false, 'osm', false, 'USD', 'America/New_York'),
  ('Night Kitty Karaoke Bar', 'night-kitty-karaoke-bar-07928', 'karaoke_bar', 'both', null, null, null, null, 38.044542, -84.506455, false, 'osm', false, 'USD', 'America/New_York'),
  ('Yesterday’s Karaoke', 'yesterday-s-karaoke-50612', 'karaoke_bar', 'both', null, '828 Lane Allen Road', 'Lexington, KY', null, 38.029339, -84.541337, false, 'osm', false, 'USD', 'America/New_York'),
  ('Knox Box Karaoke', 'knox-box-karaoke-19901', 'karaoke_bar', 'both', '+1-865-240-4183', '522 South Gay Street', null, 'https://knoxboxkaraoke.com/', 35.964697, -83.91772, false, 'osm', false, 'USD', 'America/New_York'),
  ('V Shine Karaoke Restaurant', 'v-shine-karaoke-restaurant-56801', 'karaoke_bar', 'both', null, 'Wyandotte Street West', null, null, 42.305842, -83.060943, false, 'osm', false, 'USD', 'America/New_York'),
  ('Jade Karaoke', 'jade-karaoke-20886', 'karaoke_bar', 'both', '+1-213-375-7210', '808 South Western Avenue', 'Los Angeles, CA', 'https://www.jade-la.com/', 34.056988, -118.308647, false, 'osm', false, 'USD', 'America/New_York'),
  ('Stone Karaoke and Lounge', 'stone-karaoke-and-lounge-11411', 'karaoke_bar', 'both', null, '1020 Bellevue Way Northeast', 'Bellevue, WA', null, 47.620191, -122.2012, false, 'osm', false, 'USD', 'America/New_York'),
  ('Sisters Karaoke Bar', 'sisters-karaoke-bar-65629', 'karaoke_bar', 'both', null, '105 Ladiga Street Southeast', 'Jacksonville, AL', null, 33.813267, -85.760846, false, 'osm', false, 'USD', 'America/New_York'),
  ('Big Box Karaoke', 'big-box-karaoke-12297', 'karaoke_bar', 'both', '+1 479 249 6295', '115 North Block Avenue', 'Fayetteville, AR', 'https://www.bigboxkaraoke.com/', 36.064265, -94.16085, false, 'osm', false, 'USD', 'America/New_York'),
  ('Tampa Karaoke Vip / TK Lounge', 'tampa-karaoke-vip-tk-lounge-01016', 'karaoke_bar', 'both', null, '930 East Fletcher Avenue', 'Tampa, FL', null, 28.069772, -82.449564, false, 'osm', false, 'USD', 'America/New_York'),
  ('Kevin Karaoke Sports Bar', 'kevin-karaoke-sports-bar-17473', 'karaoke_bar', 'both', null, '5001 Highway 22', 'Callaway', null, 30.153409, -85.59922, false, 'osm', false, 'USD', 'America/New_York'),
  ('Un Ha Su Restaurant & Karaoke', 'un-ha-su-restaurant-karaoke-64933', 'karaoke_bar', 'both', null, null, null, null, 33.45184, -82.038243, false, 'osm', false, 'USD', 'America/New_York'),
  ('Wanna B''s Karaoke Bar', 'wanna-b-s-karaoke-bar-32629', 'karaoke_bar', 'both', null, null, null, null, 36.161253, -86.776101, false, 'osm', false, 'USD', 'America/New_York'),
  ('Highway 40 Karaoke Barn', 'highway-40-karaoke-barn-11751', 'karaoke_bar', 'both', '+1 740-872-3429', '1450 West Union Road', 'Norwich, OH', null, 39.950811, -81.798734, false, 'osm', false, 'USD', 'America/New_York'),
  ('Amped Private Suite Karaoke Bar', 'amped-private-suite-karaoke-bar-22760', 'karaoke_bar', 'both', null, '910 West Juneau Avenue', 'Milwaukee, WI', null, 43.04595, -87.923372, false, 'osm', false, 'USD', 'America/New_York'),
  ('Icy Snow Karaoke', 'icy-snow-karaoke-56357', 'karaoke_bar', 'in_room', '+1-814-234-2000', '204 West College Avenue', 'State College, PA', null, 40.793349, -77.86284, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Mint Karaoke Lounge', 'the-mint-karaoke-lounge-93376', 'karaoke_bar', 'in_room', '+1-415-626-4726', '1942 Market Street', 'San Francisco, CA', 'https://themint.net', 37.770261, -122.425796, false, 'osm', false, 'USD', 'America/New_York'),
  ('The W Karaoke Lounge', 'the-w-karaoke-lounge-30351', 'karaoke_bar', 'in_room', '+1 314-376-4055', '6556 Delmar Boulevard', 'University City, MO', 'https://www.thewkaraoke.com', 38.656344, -90.307248, false, 'osm', false, 'USD', 'America/New_York'),
  ('Christmas Karaoke', 'christmas-karaoke-39127', 'karaoke_bar', 'in_room', null, '47-29 Bell Boulevard', 'Bayside, NY', 'https://www.karaokexmas.com/', 40.756091, -73.76712, false, 'osm', false, 'USD', 'America/New_York'),
  ('Happy Karaoke', 'happy-karaoke-57513', 'karaoke_bar', 'in_room', '+17188866886', '160-30A Northern Boulevard', 'Flushing, NY', 'https://www.happykaraokenyc1.com/', 40.762405, -73.804602, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke (noraebang)', 'karaoke-noraebang-85070', 'karaoke_bar', 'both', null, null, null, null, 34.005065, -84.084735, false, 'osm', false, 'USD', 'America/New_York'),
  ('Home Karaoke Ltd.', 'home-karaoke-ltd-46693', 'karaoke_bar', 'both', '+1-416-291-3121', null, null, null, 43.788377, -79.263452, false, 'osm', false, 'USD', 'America/New_York'),
  ('DN Karaoke', 'dn-karaoke-26928', 'karaoke_bar', 'both', null, '3005 Silver Creek Road', 'San Jose, CA', 'http://dnkaraoke.com/', 37.308429, -121.81401, false, 'osm', false, 'USD', 'America/New_York'),
  ('The Karaoke Spot', 'the-karaoke-spot-57730', 'karaoke_bar', 'in_room', null, '3895 Cherokee Street Northwest', 'Kennesaw, GA', 'https://www.thekaraokespot.com/', 34.048947, -84.600987, false, 'osm', false, 'USD', 'America/New_York'),
  ('Solo Karaoke', 'solo-karaoke-07237', 'karaoke_bar', 'in_room', '+1-604-438-7881', '6462 Kingsway', null, 'https://www.soloktv.ca/', 49.219184, -122.969668, false, 'osm', false, 'USD', 'America/New_York'),
  ('Mb Karaoke & Billard', 'mb-karaoke-billard-41812', 'karaoke_bar', 'in_room', null, null, null, null, 37.980831, -122.068493, false, 'osm', false, 'USD', 'America/New_York'),
  ('Heart & Seoul Karaoke', 'heart-seoul-karaoke-95573', 'karaoke_bar', 'both', '+1-385-325-1672', '52 West Center Street', 'Provo, UT', 'https://www.provokaraoke.com', 40.233944, -111.659704, false, 'osm', false, 'USD', 'America/New_York'),
  ('BarZunko Karaoke', 'barzunko-karaoke-34598', 'karaoke_bar', 'in_room', null, null, null, 'https://www.kkaraoke.ca/barjunko/', 43.668881, -79.386023, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke Shout', 'karaoke-shout-75824', 'karaoke_bar', 'in_room', '+1-718-569-0080', '32-46 Steinway Street', 'Astoria, NY', 'https://www.karaokeshout.com', 40.757883, -73.920096, false, 'osm', false, 'USD', 'America/New_York'),
  ('Live K Karaoke', 'live-k-karaoke-15181', 'karaoke_bar', 'in_room', null, null, null, null, 38.878906, -77.023486, false, 'osm', false, 'USD', 'America/New_York'),
  ('Echo Karaoke', 'echo-karaoke-49585', 'karaoke_bar', 'in_room', null, null, null, null, 43.663658, -79.417402, false, 'osm', false, 'USD', 'America/New_York'),
  ('Professional Karaoke', 'professional-karaoke-75123', 'karaoke_bar', 'both', null, '979 Story Road', 'San Jose, CA', null, 37.331491, -121.857376, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke Duet', 'karaoke-duet-81877', 'karaoke_bar', 'in_room', '+1-212-757-4676;+1-212-757-4748', '900 8th Avenue', 'New York, NY', 'https://www.karaokeduet.com', 40.764128, -73.984336, false, 'osm', false, 'USD', 'America/New_York'),
  ('CEO Karaoke', 'ceo-karaoke-17784', 'karaoke_bar', 'in_room', '+1-814-954-8688', '1617 North Atherton Street', 'State College, PA', 'http://ceokaraoke.com/', 40.809534, -77.894996, false, 'osm', false, 'USD', 'America/New_York'),
  ('Max Karaoke', 'max-karaoke-51389', 'karaoke_bar', 'in_room', null, '333 South Alameda Street', 'Los Angeles, CA', null, 34.045431, -118.23834, false, 'osm', false, 'USD', 'America/New_York'),
  ('First Avenue Karaoke Music Studio', 'first-avenue-karaoke-music-studio-81642', 'karaoke_bar', 'in_room', null, null, null, null, 47.321565, -122.312941, false, 'osm', false, 'USD', 'America/New_York'),
  ('The K Karaoke', 'the-k-karaoke-55489', 'karaoke_bar', 'in_room', '+1-416-371-4142', null, null, 'https://www.kkaraoke.ca/thekkaraoke.html', 43.663604, -79.417451, false, 'osm', false, 'USD', 'America/New_York'),
  ('Do Re Mi Karaoke', 'do-re-mi-karaoke-33591', 'karaoke_bar', 'in_room', null, null, null, null, 44.820654, -93.205162, false, 'osm', false, 'USD', 'America/New_York'),
  ('Stage Karaoke', 'stage-karaoke-99226', 'karaoke_bar', 'in_room', null, '138 Brighton Avenue', 'Allston, MA', 'https://stagekaraoke.com/', 42.352805, -71.131746, false, 'osm', false, 'USD', 'America/New_York'),
  ('K-Box Karaoke', 'k-box-karaoke-69241', 'karaoke_bar', 'in_room', '+1 628 9990183', '1660 Geary Boulevard', 'CA', 'https://www.k-box-karaoke.com/', 37.784874, -122.430493, false, 'osm', false, 'USD', 'America/New_York'),
  ('Glam Karaoke', 'glam-karaoke-40033', 'karaoke_bar', 'in_room', null, null, null, null, 38.829989, -77.187814, false, 'osm', false, 'USD', 'America/New_York'),
  ('Chubby''s Karaoke', 'chubby-s-karaoke-62663', 'karaoke_bar', 'in_room', null, null, null, null, 35.160259, -80.8494, false, 'osm', false, 'USD', 'America/New_York'),
  ('Passion Karaoke', 'passion-karaoke-99182', 'karaoke_bar', 'both', '+1-714-638-8399', '13900 Brookhurst Street', 'Garden Grove, CA', 'https://passion-karaoke.com/', 33.760826, -117.953324, false, 'osm', false, 'USD', 'America/New_York'),
  ('MICS Karaoke', 'mics-karaoke-14041', 'karaoke_bar', 'in_room', '+1 770 462 9999', '6035 Peachtree Road', 'Doraville, GA', null, 33.907669, -84.286998, false, 'osm', false, 'USD', 'America/New_York'),
  ('Noblesse Karaoke', 'noblesse-karaoke-62437', 'karaoke_bar', 'in_room', null, '149-38 41st Avenue', 'NY', null, 40.762318, -73.814426, false, 'osm', false, 'USD', 'America/New_York'),
  ('Pure Karaoke', 'pure-karaoke-20579', 'karaoke_bar', 'both', null, '1297 East Calaveras Boulevard', null, null, 37.435713, -121.884875, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke Duet', 'karaoke-duet-61482', 'karaoke_bar', 'in_room', '+1-646-473-0826;+1-646-473-0827', '53 West 35th Street', 'New York, NY', 'https://www.karaokeduet.com/', 40.750229, -73.986238, false, 'osm', false, 'USD', 'America/New_York'),
  ('Jaguar Karaoke', 'jaguar-karaoke-67016', 'karaoke_bar', 'in_room', null, '2516 Durant Avenue', null, null, 37.867701, -122.258122, false, 'osm', false, 'USD', 'America/New_York'),
  ('Pang Pang Karaoke', 'pang-pang-karaoke-65705', 'karaoke_bar', 'both', null, '1226 Rue Mackay', null, null, 45.495093, -73.575988, false, 'osm', false, 'USD', 'America/New_York'),
  ('Corner Spot Karaoke LeCafe', 'corner-spot-karaoke-lecafe-27447', 'karaoke_bar', 'in_room', null, '6432 Tupelo Drive', 'Citrus Heights, CA', null, 38.705671, -121.313801, false, 'osm', false, 'USD', 'America/New_York'),
  ('August Karaoke Box', 'august-karaoke-box-85229', 'karaoke_bar', 'in_room', '+1-480-590-1037', '1301 East University Drive', 'Tempe, AZ', 'https://8ktv.net/', 33.42113, -111.916747, false, 'osm', false, 'USD', 'America/New_York'),
  ('Ninja Karaoke', 'ninja-karaoke-05645', 'karaoke_bar', 'in_room', null, null, null, null, 36.125813, -115.211802, false, 'osm', false, 'USD', 'America/New_York'),
  ('iRock Karaoke Lounge', 'irock-karaoke-lounge-20542', 'karaoke_bar', 'in_room', null, null, null, null, 39.118104, -77.185092, false, 'osm', false, 'USD', 'America/New_York'),
  ('FAMFAM Karaoke', 'famfam-karaoke-81249', 'karaoke_bar', 'both', null, null, null, 'https://www.famfam.family/', 33.750981, -84.399318, false, 'osm', false, 'USD', 'America/New_York'),
  ('Echo Karaoke', 'echo-karaoke-90086', 'karaoke_bar', 'in_room', null, '1844 West Broadway Road', 'Mesa, AZ', null, 33.408787, -111.871554, false, 'osm', false, 'USD', 'America/New_York'),
  ('Sing Sing Karaoke', 'sing-sing-karaoke-81817', 'karaoke_bar', 'in_room', '+1-212-387-7800', null, null, 'https://karaokesingsing.com/', 40.729388, -73.989116, false, 'osm', false, 'USD', 'America/New_York'),
  ('Shout Karaoke', 'shout-karaoke-45347', 'karaoke_bar', 'in_room', null, null, null, null, 33.738735, -117.824874, false, 'osm', false, 'USD', 'America/New_York'),
  ('K-Fever Karaoke', 'k-fever-karaoke-71105', 'karaoke_bar', 'in_room', null, '8300 Capstan Way', 'Richmond', null, 49.187705, -123.131077, false, 'osm', false, 'USD', 'America/New_York'),
  ('Family Karaoke', 'family-karaoke-20287', 'karaoke_bar', 'in_room', null, null, null, null, 39.281001, -76.862797, false, 'osm', false, 'USD', 'America/New_York'),
  ('Soju Blues Korean Bar & Karaoke', 'soju-blues-korean-bar-karaoke-09503', 'karaoke_bar', 'in_room', null, null, null, null, 29.704944, -95.555719, false, 'osm', false, 'USD', 'America/New_York'),
  ('All In Karaoke', 'all-in-karaoke-75713', 'karaoke_bar', 'in_room', null, null, null, null, 40.84769, -73.970544, false, 'osm', false, 'USD', 'America/New_York'),
  ('Blue Moon Cafe and Karaoke', 'blue-moon-cafe-and-karaoke-75689', 'karaoke_bar', 'in_room', null, null, null, null, 38.528461, -121.496374, false, 'osm', false, 'USD', 'America/New_York'),
  ('Astro Karaoke', 'astro-karaoke-45949', 'karaoke_bar', 'both', null, null, null, null, 33.872623, -118.319145, false, 'osm', false, 'USD', 'America/New_York'),
  ('Muse Karaoke', 'muse-karaoke-30201', 'karaoke_bar', 'both', '+1-310-325-4408', '1555 Sepulveda Boulevard', null, null, 33.816224, -118.30514, false, 'osm', false, 'USD', 'America/New_York'),
  ('XSPACE Karaoke', 'xspace-karaoke-49961', 'karaoke_bar', 'in_room', '+1-614-530-8375', '5232 Bethel Center Mall', 'Columbus, OH', null, 40.06479, -83.06019, false, 'osm', false, 'USD', 'America/New_York'),
  ('Boom Karaoke', 'boom-karaoke-91214', 'karaoke_bar', 'in_room', '+1-647-458-2588', '577 Yonge Street', null, 'https://www.boomkaraoke.ca/', 43.665631, -79.384618, false, 'osm', false, 'USD', 'America/New_York'),
  ('SingBox Karaoke', 'singbox-karaoke-61463', 'karaoke_bar', 'in_room', null, null, null, null, 32.986439, -96.910878, false, 'osm', false, 'USD', 'America/New_York'),
  ('233 Starr Karaoke', '233-starr-karaoke-39604', 'karaoke_bar', 'in_room', '+1-929-210-8687', '233 Starr Street', null, 'https://www.233starrkaraoke.com', 40.705518, -73.922883, false, 'osm', false, 'USD', 'America/New_York'),
  ('D''Vine Karaoke', 'd-vine-karaoke-75413', 'karaoke_bar', 'in_room', null, '261 South Mission Drive', 'San Gabriel, CA', null, 34.09893, -118.109751, false, 'osm', false, 'USD', 'America/New_York'),
  ('Camino Karaoke', 'camino-karaoke-93198', 'karaoke_bar', 'in_room', null, '3378 El Camino Real', 'Santa Clara, CA', null, 37.352059, -121.988978, false, 'osm', false, 'USD', 'America/New_York'),
  ('K-House Karaoke and Arts Hub', 'k-house-karaoke-and-arts-hub-82071', 'karaoke_bar', 'in_room', '+1-607-339-8981', '121 West State Street', 'Ithaca, NY', 'https://www.khousekaraoke.com/', 42.439379, -76.499807, false, 'osm', false, 'USD', 'America/New_York'),
  ('Gono Karaoke', 'gono-karaoke-58680', 'karaoke_bar', 'in_room', null, '2156 Yonge Street', null, null, 43.703845, -79.397914, false, 'osm', false, 'USD', 'America/New_York'),
  ('Vox Karaoke', 'vox-karaoke-60125', 'karaoke_bar', 'both', null, null, null, null, 47.59818, -122.326193, false, 'osm', false, 'USD', 'America/New_York'),
  ('Duet Karaoke', 'duet-karaoke-69239', 'karaoke_bar', 'in_room', '+1 212-753-0030; +1 212-753-0031', '304 East 48th Street', null, 'https://www.karaokeduet.com/', 40.753384, -73.969133, false, 'osm', false, 'USD', 'America/New_York'),
  ('Bobos Karaoke', 'bobos-karaoke-84058', 'karaoke_bar', 'in_room', '+1 858-384-6436', '4698 Convoy Street', 'San Diego, CA', null, 32.826857, -117.155317, false, 'osm', false, 'USD', 'America/New_York'),
  ('Q Karaoke', 'q-karaoke-92206', 'karaoke_bar', 'in_room', '+1-407-476-8280', '4519 South Orange Blossom Trail', 'Orlando, FL', 'http://www.q-karaoke.com/', 28.498545, -81.396333, false, 'osm', false, 'USD', 'America/New_York'),
  ('Neway Karaoke', 'neway-karaoke-04234', 'karaoke_bar', 'in_room', null, '9889 Bellaire Boulevard', 'Houston, TX', 'https://www.neway239.com/', 29.703151, -95.553407, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke Court', 'karaoke-court-48158', 'karaoke_bar', 'both', null, null, null, null, 36.225783, -115.323285, false, 'osm', false, 'USD', 'America/New_York'),
  ('Ktop Karaoke & Asian Fusion Restaurant', 'ktop-karaoke-asian-fusion-restaurant-20190', 'karaoke_bar', 'both', null, 'Race Street', 'Philadelphia', null, 39.955453, -75.15482, false, 'osm', false, 'USD', 'America/New_York'),
  ('Happy Karaoke', 'happy-karaoke-78976', 'karaoke_bar', 'in_room', null, null, null, null, 33.899946, -84.277276, false, 'osm', false, 'USD', 'America/New_York'),
  ('Hanshin Karaoke', 'hanshin-karaoke-46423', 'karaoke_bar', 'in_room', '+1 334-593-2038', '2787 Bell Road', 'Montgomery, AL', null, 32.33935, -86.193771, false, 'osm', false, 'USD', 'America/New_York'),
  ('Karaoke Shelter', 'karaoke-shelter-48424', 'karaoke_bar', 'both', null, null, null, null, 43.604295, -89.784721, false, 'osm', false, 'USD', 'America/New_York'),
  ('Renos Karaoke', 'renos-karaoke-05386', 'karaoke_bar', 'in_room', '+1-402-884-3884', '3909 Farnam Street', 'Omaha, NE', 'https://www.renoskaraoke.com/', 41.257637, -95.972468, false, 'osm', false, 'USD', 'America/New_York')
on conflict (slug) do nothing;
