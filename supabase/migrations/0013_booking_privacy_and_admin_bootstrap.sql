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
