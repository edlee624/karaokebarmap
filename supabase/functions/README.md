# Glowup Book — Email Edge Functions (Resend)

Two Supabase Edge Functions that send email via Resend:

- **send-booking-email** — booking confirmation (with a "confirm your appointment" link). Fired by a Database Webhook when a row is inserted into `public.appointments`.
- **send-reminders** — ~24h reminder. Run on a schedule (Supabase Cron).

## Prerequisites
1. Run migrations through **0011** (adds `appointments.reminded_at`).
2. In **Resend** (Glowup Book account): verify `glowupbook.com` (done) and create an **API key**.
3. Create a `bookings@glowupbook.com` sender is fine — it just needs to be on the verified domain.

## 1. Set secrets
Supabase Dashboard → **Edge Functions → Secrets** (or CLI `supabase secrets set`):

```
RESEND_API_KEY = re_xxxxxxxx
EMAIL_FROM     = Glowup Book <bookings@glowupbook.com>
SITE_URL       = https://glowupbook.com
```
(`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.)

## 2. Deploy the functions
**Option A — Dashboard:** Edge Functions → *Deploy a new function* → paste each `index.ts`. Turn **"Verify JWT" OFF** for `send-booking-email` (so the Database Webhook can call it) and for `send-reminders` (cron calls it).

**Option B — CLI:**
```bash
supabase functions deploy send-booking-email --no-verify-jwt
supabase functions deploy send-reminders --no-verify-jwt
```

## 3. Fire confirmation on booking (Database Webhook)
Database → **Webhooks** → *Create*:
- Table: `public.appointments`, Events: **Insert**
- Type: **Supabase Edge Function** → `send-booking-email`
The webhook posts `{ record: <new appointment> }`, which the function reads.

## 4. Schedule reminders (Cron)
Integrations → **Cron** → new job, e.g. hourly:
```sql
select cron.schedule('glowup-reminders', '0 * * * *', $$
  select net.http_post(
    url    := 'https://<PROJECT_REF>.functions.supabase.co/send-reminders',
    headers:= jsonb_build_object('Content-Type','application/json')
  );
$$);
```
(Or use the Cron UI to invoke the `send-reminders` function directly.)

## Notes
- Emails only send to customers who provided an email.
- The confirm link is `https://glowupbook.com/confirm/<token>` (handled by the SPA).
- Test one booking end-to-end after deploy; check Resend's dashboard logs for delivery.
