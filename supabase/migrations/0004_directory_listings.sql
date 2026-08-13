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
