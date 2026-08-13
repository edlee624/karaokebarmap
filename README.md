# Karaoke Bar Map

An interactive map + directory of **karaoke bars, KTV rooms and karaoke DJs** across the US.
Target domain: **karaokebarmap.com**.

Built on the Glowbook (salon-crm) template — a **static HTML/CSS/JS single-page app**
in `public/`, talking directly to **Supabase** (Postgres + Auth) from the browser,
deployed to **Vercel** from GitHub. No build step.

Two faces, one app:
- **Public map/directory** (homepage) — anyone browses karaoke bars & DJs by city,
  on a list or a Leaflet map. No login needed.
- **Host dashboard** (login) — a bar or DJ claims/creates its listing and takes
  bookings: reserve a private karaoke room, or hire a DJ for an event.

## Listing model

Everything is a listing (internally still the `salons` table). Each row has a
`kind`:
- `kind = 'venue'` — a karaoke bar / KTV spot (address, geo, rooms, hours).
- `kind = 'dj'`    — a karaoke DJ, with a distinct **`dj_profiles`** row
  (genres, travel radius, hourly rate, gear, mixes). See `0014_karaoke_and_djs.sql`.

Both are bookable through the same appointments engine inherited from the template.

## Data seed

`data/` holds the pipeline that seeds the directory with **real US karaoke venues**
pulled from OpenStreetMap (Overpass API):
- `overpass_karaoke*.ql` — the Overpass queries.
- `clean_osm.py` — merges/dedupes the pulls, filters to the US → `venues.csv` (~225 rows).
- `make_seed.py` — turns `venues.csv` into `seed_venues.sql` (unclaimed listings,
  `source='osm'`, with lat/lon for map pins).

Re-pull anytime by re-running the Overpass queries, then `clean_osm.py` + `make_seed.py`.

## Run locally

```bash
npm install
npm run dev          # serves public/ at http://localhost:3000
```

## Connect Supabase (required for data)

1. Create a **new** Supabase project (do NOT reuse Glowbook's).
2. Run every file in `supabase/migrations/` **in order** (SQL Editor or `supabase db push`).
3. Run `data/seed_venues.sql` to load the karaoke venues.
4. Paste your Project URL + anon key into `public/config.js`.

## Status

- [x] Repo scaffolded from template, rebranded (theme, copy, meta)
- [x] Schema: 3 categories + `karaoke_type` + distinct `dj_profiles` (migrations 0014–0015)
- [x] Real US karaoke-venue seed (OSM → CSV → SQL)
- [x] Public directory/map wired to `business_type` (filter, cards, pins)
- [x] Performer (DJ/KJ) profile editor + public page
- [ ] Booking flow relabeled (rooms / DJ sets vs "service")
- [ ] Legal pages re-themed (still salon-marketplace terms)
- [ ] Deploy to Vercel + point karaokebarmap.com

## Keep the Supabase database awake

Free-tier Supabase projects **pause after 7 days of no activity**. Pre-launch
(low traffic) that will happen. `.github/workflows/supabase-keepalive.yml` pings
the REST API every 3 days to keep it active. To switch it on:

1. Create the Supabase project + run the migrations (above).
2. Push this repo to GitHub.
3. Repo → Settings → Secrets and variables → Actions → add `SUPABASE_URL` and
   `SUPABASE_ANON_KEY`.

It also runs on demand from the Actions tab ("Run workflow"). Note: GitHub pauses
*scheduled* workflows after 60 days with no commits — any commit re-arms it.

## Deploy (Vercel)

Not deployed yet — there is no linked Vercel project. To create one:

```bash
npm i -g vercel
vercel            # link/create the "karaokebarmap" project
vercel --prod     # deploy
```

Then add the `karaokebarmap.com` domain in the Vercel dashboard. `vercel.json`
already serves `public/` as a static SPA with the security headers.
