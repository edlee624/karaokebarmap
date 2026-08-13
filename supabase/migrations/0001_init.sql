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
