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
