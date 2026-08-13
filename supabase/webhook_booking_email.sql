-- ============================================================================
-- Karaoke Bar Map — fire the booking-confirmation email on new appointments.
--
-- Alternative to a dashboard Database Webhook (which needs the webhooks feature /
-- `supabase_functions` schema enabled). This uses pg_net to POST the new row to
-- the deployed `send-booking-email` edge function. Paste into the SQL editor.
-- Safe to re-run.
-- ============================================================================

create extension if not exists pg_net;

create or replace function public.notify_booking_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url     := 'https://hjdycgzcfynijzqnbujq.supabase.co/functions/v1/send-booking-email',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 -- publishable (anon) key is public; the function is deployed --no-verify-jwt
                 'apikey', 'sb_publishable_wsci1jNeI_wGl5yX525Sfw_7s6q_YWn'
               ),
    body    := jsonb_build_object('record', to_jsonb(new))
  );
  return new;
end; $$;

drop trigger if exists trg_booking_email on public.appointments;
create trigger trg_booking_email
  after insert on public.appointments
  for each row execute function public.notify_booking_email();
