-- ============================================================================
-- Glowup Book — track when a reminder email was sent (dedupe reminders).
-- ============================================================================
alter table public.appointments add column if not exists reminded_at timestamptz;
