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
