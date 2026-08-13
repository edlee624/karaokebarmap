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
