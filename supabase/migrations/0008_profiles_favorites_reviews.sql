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
