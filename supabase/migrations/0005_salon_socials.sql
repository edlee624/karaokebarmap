-- ============================================================================
-- Glowup Book — social links on a salon profile
-- Each business profile now carries Instagram / Facebook / TikTok / website,
-- alongside the existing name, address, phone, email. These also become the
-- source for the homepage inspiration carousel once businesses connect their
-- social accounts.
-- ============================================================================

alter table public.salons add column if not exists instagram text;
alter table public.salons add column if not exists facebook  text;
alter table public.salons add column if not exists tiktok    text;
alter table public.salons add column if not exists website   text;
