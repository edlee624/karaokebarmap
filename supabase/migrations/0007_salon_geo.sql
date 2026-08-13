-- ============================================================================
-- Glowup Book — salon coordinates (for the directory map view)
-- Backfilled for the NYC seed from NY Open Data; geocoded for new salons later.
-- ============================================================================

alter table public.salons add column if not exists lat double precision;
alter table public.salons add column if not exists lon double precision;
create index if not exists salons_geo_idx on public.salons (lat, lon);
