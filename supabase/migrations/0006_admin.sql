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
