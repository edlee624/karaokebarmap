// ============================================================================
// Glowup Book — send-reminders (Supabase Edge Function)
//
// Run on a schedule (hourly or daily via Supabase Cron). Emails a reminder for
// appointments starting ~24h from now that haven't been reminded yet, and marks
// reminded_at so each is reminded once. Sent via Resend.
//
// Secrets: RESEND_API_KEY, EMAIL_FROM, SITE_URL (see send-booking-email).
// Requires migration 0011 (appointments.reminded_at).
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE_URL = Deno.env.get("SITE_URL") ?? "https://glowupbook.com";
const FROM = Deno.env.get("EMAIL_FROM") ?? "Glowup Book <bookings@glowupbook.com>";

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async () => {
  const supa = createClient(SUPABASE_URL, SERVICE_KEY);
  const fromT = new Date(Date.now() + 23 * 3600 * 1000).toISOString();
  const toT = new Date(Date.now() + 25 * 3600 * 1000).toISOString();

  const { data: appts, error } = await supa
    .from("appointments")
    .select("id, starts_at, confirm_token, customer:customers(name,email), salon:salons(name,timezone), service:services(name)")
    .in("status", ["booked", "confirmed"]).is("reminded_at", null)
    .gte("starts_at", fromT).lte("starts_at", toT);

  // Surface the failure instead of silently reporting {"sent":0} forever
  // (e.g. if migration 0011 / reminded_at isn't applied).
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { "Content-Type": "application/json" } });

  let sent = 0;
  for (const a of appts ?? []) {
    const email = a.customer?.email;
    if (!email) continue;
    // Atomically claim this reminder first so overlapping runs can't double-send.
    const { data: claimed } = await supa
      .from("appointments")
      .update({ reminded_at: new Date().toISOString() })
      .eq("id", a.id).is("reminded_at", null).select("id");
    if (!claimed || claimed.length === 0) continue;
    const tz = a.salon?.timezone ?? "UTC";
    const when = esc(new Date(a.starts_at).toLocaleString("en-US", { timeZone: tz, dateStyle: "full", timeStyle: "short" }));
    const salonName = esc(a.salon?.name ?? "your salon");
    const html = `
      <div style="font-family:Inter,Arial,sans-serif;max-width:520px;margin:0 auto;color:#1d1b2e">
        <h2 style="font-family:Georgia,serif">Reminder: your appointment tomorrow</h2>
        <p>Hi ${esc(a.customer?.name ?? "there")}, a reminder for <strong>${esc(a.service?.name ?? "your appointment")}</strong> at ${salonName}:</p>
        <p style="font-size:16px">${when}</p>
        <p><a href="${SITE_URL}/confirm/${encodeURIComponent(a.confirm_token)}" style="background:#6C4AB6;color:#fff;padding:12px 22px;border-radius:10px;text-decoration:none;font-weight:600;display:inline-block">Confirm you're coming</a></p>
      </div>`;
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to: email, subject: `Reminder: ${salonName} appointment tomorrow`, html }),
    });
    if (res.ok) { sent++; }
    // Release the claim so a failed send retries on the next run.
    else { await supa.from("appointments").update({ reminded_at: null }).eq("id", a.id); }
  }
  return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
});
