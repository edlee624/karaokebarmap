// ============================================================================
// Glowup Book — send-booking-email
//
// Sends the customer an email via Resend. Modes:
//   • "booking"          — confirmation when an appointment is created (DB trigger)
//   • "confirm-request"  — "please confirm you're still coming" (owner button)
//   • "cancelled"        — appointment cancellation notice (owner cancels)
//
// Body: { record: <appointment> }                         (DB trigger)  OR
//       { id: <uuid>, mode: "confirm-request" }            (Request confirmation) OR
//       { id: <uuid>, mode: "cancelled", message: "..." }  (Cancel appointment)
//
// Secrets: RESEND_API_KEY, EMAIL_FROM, SITE_URL (SUPABASE_URL + SERVICE key auto).
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE_URL = Deno.env.get("SITE_URL") ?? "https://glowupbook.com";
const FROM = Deno.env.get("EMAIL_FROM") ?? "Glowup Book <bookings@glowupbook.com>";

// Escape strings before interpolating into the HTML email so attacker-chosen
// values (customer name at booking, cancellation message, salon/service names)
// cannot inject markup into a message sent from our verified sending domain.
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const record = body.record ?? body;
    const apptId = record?.id;
    const mode = body.mode ?? record?.mode ?? "booking";
    const message = (body.message ?? "").toString().trim();
    if (!apptId) return new Response("no appointment id", { status: 400 });

    const supa = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: a, error: fetchErr } = await supa
      .from("appointments")
      .select("id, starts_at, confirm_token, customer:customers(name,email), salon:salons(name,timezone,slug), service:services(name)")
      .eq("id", apptId).maybeSingle();
    if (fetchErr) return new Response(`lookup failed: ${fetchErr.message}`, { status: 500 });
    if (!a) return new Response("appointment not found", { status: 404 });
    if (!a?.customer?.email) return new Response("no recipient email on file", { status: 422 });

    const tz = a.salon?.timezone ?? "UTC";
    const when = esc(new Date(a.starts_at).toLocaleString("en-US", { timeZone: tz, dateStyle: "full", timeStyle: "short" }));
    const confirmUrl = `${SITE_URL}/confirm/${encodeURIComponent(a.confirm_token)}`;
    const salonName = esc(a.salon?.name ?? "the salon");
    const rebookUrl = a.salon?.slug ? `${SITE_URL}/${encodeURIComponent(a.salon.slug)}` : SITE_URL;
    const name = esc(a.customer?.name ?? "there");
    const service = esc(a.service?.name ?? "Appointment");
    const safeMessage = esc(message);

    let subject: string, html: string;
    const shell = (inner: string) =>
      `<div style="font-family:Inter,Arial,sans-serif;max-width:520px;margin:0 auto;color:#1d1b2e">${inner}<p style="color:#8B8898;font-size:12px">Sent via Glowup Book</p></div>`;
    const btn = (href: string, label: string) =>
      `<p><a href="${href}" style="background:#6C4AB6;color:#fff;padding:12px 22px;border-radius:10px;text-decoration:none;font-weight:600;display:inline-block">${label}</a></p>`;

    if (mode === "cancelled") {
      subject = `Your appointment at ${salonName} was cancelled`;
      html = shell(`
        <h2 style="font-family:Georgia,serif">Your appointment has been cancelled</h2>
        <p>Hi ${name}, your appointment for <strong>${service}</strong> on ${when} at ${salonName} has been cancelled.</p>
        ${safeMessage ? `<p style="background:#F0ECE6;border-radius:10px;padding:12px 14px;margin:14px 0">${safeMessage}</p>` : ""}
        <p>You can rebook any time:</p>
        ${btn(rebookUrl, "Book again")}`);
    } else if (mode === "confirm-request") {
      subject = `Please confirm your appointment at ${salonName}`;
      html = shell(`
        <h2 style="font-family:Georgia,serif">Please confirm your appointment</h2>
        <p>Hi ${name}, ${salonName} would like to confirm you're still coming to your appointment:</p>
        <p style="font-size:16px"><strong>${service}</strong><br>${when}</p>
        ${btn(confirmUrl, "Yes, I'll be there")}
        <p style="color:#8B8898;font-size:13px">Can't make it? Please contact ${salonName} to reschedule.</p>`);
    } else {
      subject = `Your booking at ${salonName}`;
      html = shell(`
        <h2 style="font-family:Georgia,serif">You're booked at ${salonName} 🎉</h2>
        <p>Hi ${name}, here are your appointment details:</p>
        <p style="font-size:16px"><strong>${service}</strong><br>${when}</p>
        ${btn(confirmUrl, "Confirm my appointment")}
        <p style="color:#8B8898;font-size:13px">We'll send a reminder before your visit.</p>`);
    }

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to: a.customer.email, subject, html }),
    });
    return new Response(await res.text(), { status: res.ok ? 200 : 500 });
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
