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
