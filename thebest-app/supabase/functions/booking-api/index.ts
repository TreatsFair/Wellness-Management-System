import { createClient } from "npm:@supabase/supabase-js@2";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const PREFERENCES = new Set(["none", "female", "male"]);

function secretKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const encoded = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!encoded) throw new Error("Supabase secret key is not configured");
  const keys = JSON.parse(encoded) as Record<string, unknown>;
  const key = keys.default ?? Object.values(keys)[0];
  if (typeof key !== "string" || !key) throw new Error("Supabase secret key is not configured");
  return key;
}

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabase = createClient(supabaseUrl, secretKey(), { auth: { persistSession: false, autoRefreshToken: false } });

// Pre-Billplz test switch: when enabled, a hold can be confirmed into an appointment
// immediately (simulating an instant successful payment). Off unless explicitly set.
const AUTO_CONFIRM = (Deno.env.get("BOOKING_TEST_AUTOCONFIRM") ?? "").trim() === "true";

// Billplz (sandbox or production, selected entirely by which base URL/keys are set).
const BILLPLZ_BASE_URL = (Deno.env.get("BILLPLZ_BASE_URL") ?? "").trim().replace(/\/$/, "");
const BILLPLZ_API_KEY = (Deno.env.get("BILLPLZ_API_KEY") ?? "").trim();
const BILLPLZ_COLLECTION_ID = (Deno.env.get("BILLPLZ_COLLECTION_ID") ?? "").trim();
const BILLPLZ_X_SIGNATURE_KEY = (Deno.env.get("BILLPLZ_X_SIGNATURE_KEY") ?? "").trim();
const BILLPLZ_CONFIGURED = Boolean(
  BILLPLZ_BASE_URL && BILLPLZ_API_KEY && BILLPLZ_COLLECTION_ID && BILLPLZ_X_SIGNATURE_KEY,
);
// Where to send the customer's browser back to after paying. Falls back to the
// first configured site origin (used for CORS) so a dedicated var isn't required.
const BOOKING_REDIRECT_BASE = (
  Deno.env.get("BOOKING_REDIRECT_URL") ??
  (Deno.env.get("BOOKING_SITE_ORIGINS") ?? "").split(",")[0] ??
  ""
).trim().replace(/\/$/, "");

// Exact key order Billplz's own signature examples use for webhook callbacks.
// Signature = HMAC-SHA256("amount<v>|collection_id<v>|due_at<v>|email<v>|id<v>|mobile<v>|name<v>|paid_amount<v>|paid_at<v>|paid<v>|state<v>|url<v>", X_SIGNATURE_KEY)
const BILLPLZ_CALLBACK_SIGNED_KEYS = [
  "amount", "collection_id", "due_at", "email", "id", "mobile",
  "name", "paid_amount", "paid_at", "paid", "state", "url",
] as const;

async function hmacSha256Hex(message: string, key: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(message));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function billplzRequest(path: string, body: Record<string, string>) {
  const response = await fetch(`${BILLPLZ_BASE_URL}${path}`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${BILLPLZ_API_KEY}:`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(body),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    console.error("Billplz API error", response.status, JSON.stringify(payload));
    const detail = billplzErrorDetail(payload);
    throw new Error(`Billplz request failed (${response.status})${detail ? `: ${detail}` : ""}`);
  }
  return payload as Record<string, unknown>;
}

// Billplz error bodies are typically { error: { message: ["..."] } } or { error: "..." }.
function billplzErrorDetail(payload: Record<string, unknown>): string {
  const err = payload.error;
  if (typeof err === "string") return err;
  if (err && typeof err === "object") {
    const message = (err as Record<string, unknown>).message;
    if (Array.isArray(message)) return message.join(", ");
    if (typeof message === "string") return message;
  }
  return "";
}

// Private-network / Tailscale CGNAT ranges, for testing the site from a phone
// or other device during development. Safe to allow broadly: this API has no
// cookie/session auth (publishable key only) and re-validates everything
// server-side, so a wider CORS allowlist doesn't widen what an attacker can do.
const LOCAL_TESTING_ORIGIN = new RegExp(
  "^https?://(" +
    "localhost|127\\.0\\.0\\.1|" +
    "10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}|" +
    "172\\.(1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3}|" +
    "192\\.168\\.\\d{1,3}\\.\\d{1,3}|" +
    "100\\.(6[4-9]|[7-9]\\d|1[01]\\d|12[0-7])\\.\\d{1,3}\\.\\d{1,3}" +
  ")(:\\d+)?$",
  "i",
);

function origin(request: Request): string {
  const value = request.headers.get("origin") ?? "";
  const configured = (Deno.env.get("BOOKING_SITE_ORIGINS") ?? "").split(",").map((item) => item.trim()).filter(Boolean);
  if (!value) return "*";
  if (configured.includes("*") || configured.includes(value)) return value;
  if (LOCAL_TESTING_ORIGIN.test(value)) return value;
  return configured[0] ?? value;
}

function responseHeaders(request: Request): HeadersInit {
  return {
    "Access-Control-Allow-Origin": origin(request),
    "Access-Control-Allow-Headers": "apikey, authorization, content-type, x-client-info",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Content-Type": "application/json; charset=utf-8",
    Vary: "Origin",
  };
}

function json(request: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders(request) });
}
function fail(request: Request, message: string, status = 400): Response { return json(request, { error: message }, status); }
function pathOf(request: Request): string {
  const path = new URL(request.url).pathname;
  const index = path.indexOf("/booking-api");
  return index < 0 ? path : path.slice(index + 12) || "/";
}
function uuid(value: unknown): string | null { const text = String(value ?? "").trim(); return UUID.test(text) ? text : null; }
function preference(value: unknown): string { const text = String(value ?? "none").toLowerCase(); return PREFERENCES.has(text) ? text : "none"; }

// Mirrors public.normalize_my_phone() in 040_past_time_slots_and_phone_normalization.sql.
// Billplz's sandbox/live API expects a clean "60XXXXXXXXX" mobile number; the booking
// form's free-typed phone (spaces, dashes, "+", leading 0 vs 60) was being sent through
// unchanged, which is a likely cause of Billplz rejecting bill creation (502s).
function normalizeMyPhone(value: string): string {
  const digits = value.replace(/\D/g, "");
  if (!digits) return digits;
  if (digits.startsWith("60")) return digits;
  if (digits.startsWith("0")) return `6${digits}`;
  return `60${digits}`;
}

async function fingerprint(request: Request): Promise<string> {
  const address = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || request.headers.get("x-real-ip") || "unknown";
  const salt = Deno.env.get("BOOKING_RATE_LIMIT_SALT") || supabaseUrl;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}|${address}`));
  return [...new Uint8Array(digest)].map((value) => value.toString(16).padStart(2, "0")).join("");
}

async function rpc(name: string, args: Record<string, unknown> = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data ?? [];
}

// For RPCs that return a single scalar (not `returns table`), where a real
// `null` result (e.g. "no matching row") must stay distinguishable from [].
async function rpcScalar(name: string, args: Record<string, unknown> = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data as string | null;
}

async function route(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const path = pathOf(request);
  if (request.method === "GET" && path === "/health") return json(request, { ok: true, payment_enabled: BILLPLZ_CONFIGURED, auto_confirm: AUTO_CONFIRM });
  if (request.method === "GET" && path === "/outlets") {
    return json(request, { outlets: await rpc("list_public_booking_outlets") });
  }
  if (request.method === "GET" && path === "/catalogue") {
    const outlet = String(url.searchParams.get("outlet") ?? "").trim().toLowerCase();
    if (!/^[a-z0-9-]{2,50}$/.test(outlet)) return fail(request, "A valid outlet is required");
    const rows = await rpc("list_public_booking_catalogue", { p_outlet_code: outlet }) as Array<Record<string, unknown>>;
    return json(request, { services: rows.map((row) => ({
      catalogue_id: row.catalogue_id,
      public_name: row.public_name,
      short_description: row.short_description,
      public_image_url: row.public_image_url,
      display_price: row.display_price,
      show_price: row.show_price,
      duration_minutes: row.duration_minutes,
      display_order: row.display_order,
    })) });
  }
  if (request.method === "GET" && path === "/availability/dates") {
    const catalogueId = uuid(url.searchParams.get("catalogue_id"));
    if (!catalogueId) return fail(request, "A valid treatment is required");
    return json(request, { dates: await rpc("get_public_booking_dates_v2", {
      p_catalogue_id: catalogueId, p_therapist_preference: preference(url.searchParams.get("therapist_preference")),
    }) });
  }
  if (request.method === "GET" && path === "/availability/times") {
    const catalogueId = uuid(url.searchParams.get("catalogue_id"));
    const date = String(url.searchParams.get("date") ?? "");
    if (!catalogueId || !DATE.test(date)) return fail(request, "Treatment and date are required");
    return json(request, { slots: await rpc("get_public_booking_slots_v2", {
      p_catalogue_id: catalogueId, p_date: date,
      p_therapist_preference: preference(url.searchParams.get("therapist_preference")),
    }) });
  }
  if (request.method === "POST" && path === "/booking-holds") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || typeof body !== "object" || String(body.website ?? "").trim()) return fail(request, "Invalid booking request");
    const catalogueId = uuid(body.catalogue_id);
    const startAt = String(body.start_at ?? "").trim();
    if (!catalogueId || !startAt) return fail(request, "Treatment and time are required");
    try {
      const rows = await rpc("create_public_booking_hold_v2", {
        p_catalogue_id: catalogueId, p_start_at: startAt,
        p_therapist_preference: preference(body.therapist_preference),
        p_customer_name: String(body.customer_name ?? ""), p_customer_phone: String(body.customer_phone ?? ""),
        p_customer_email: String(body.customer_email ?? ""), p_therapist_request: String(body.therapist_request ?? ""),
        p_notes: String(body.notes ?? ""), p_request_fingerprint: await fingerprint(request),
      }) as Array<Record<string, unknown>>;
      const hold = rows[0];
      if (!hold) return fail(request, "Unable to reserve this time", 500);
      return json(request, { hold: {
        token: hold.hold_token, expires_at: hold.hold_expires_at,
        total_price: Number(hold.total_price),
        duration_minutes: Number(hold.duration_minutes), status: "pending_payment",
      } }, 201);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (/no longer available/i.test(message)) return fail(request, "That time was just taken. Please choose another time.", 409);
      throw error;
    }
  }
  if (request.method === "POST" && path === "/booking-holds/pay") {
    if (!BILLPLZ_CONFIGURED) return fail(request, "Payment is not configured yet.", 503);
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const token = uuid(body?.token);
    if (!token) return fail(request, "A valid booking reference is required");
    try {
      const rows = await rpc("get_booking_hold_for_payment", { p_token: token }) as Array<Record<string, unknown>>;
      const hold = rows[0];
      if (!hold) return fail(request, "Booking reference not found", 404);
      if (hold.status !== "pending_payment" || new Date(String(hold.expires_at)) <= new Date()) {
        return fail(request, "This booking hold has expired. Please start again.", 409);
      }

      const amountCents = Math.round(Number(hold.total_amount) * 100);
      const callbackUrl = `${supabaseUrl}/functions/v1/booking-api/billplz/callback`;
      const billParams: Record<string, string> = {
        collection_id: BILLPLZ_COLLECTION_ID,
        email: String(hold.customer_email ?? ""),
        mobile: normalizeMyPhone(String(hold.customer_phone ?? "")),
        name: String(hold.customer_name ?? ""),
        amount: String(amountCents),
        callback_url: callbackUrl,
        description: `The Best Wellness online booking ${token.slice(0, 8).toUpperCase()}`,
      };
      if (BOOKING_REDIRECT_BASE) {
        billParams.redirect_url = `${BOOKING_REDIRECT_BASE}/booking.html?bp_token=${token}`;
      }

      const bill = await billplzRequest("/api/v3/bills", billParams);
      const billId = String(bill.id ?? "");
      const billUrl = String(bill.url ?? "");
      if (!billId || !billUrl) return fail(request, "Unable to start payment. Please try again.", 502);

      await rpc("record_billplz_bill", { p_token: token, p_bill_id: billId });
      return json(request, { url: billUrl }, 201);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (/no longer accept payment/i.test(message)) return fail(request, "This booking hold has expired. Please start again.", 409);
      if (/not found/i.test(message)) return fail(request, "Booking reference not found", 404);
      // Surface the actual Billplz/network failure instead of a generic 500 —
      // the caller sees exactly why payment couldn't start (bad credentials,
      // bad collection id, DNS/base-URL typo, etc.).
      console.error("Unable to start Billplz payment", message);
      return fail(request, `Unable to start payment: ${message}`, 502);
    }
  }
  if (request.method === "POST" && path === "/billplz/callback") {
    // Billplz expects a fast 200 and posts application/x-www-form-urlencoded fields.
    const form = await request.formData().catch(() => null);
    if (!form) return fail(request, "Invalid callback payload", 400);
    const get = (key: string) => String(form.get(key) ?? "");
    const signature = get("x_signature");
    const billId = get("id");
    if (!signature || !billId) return fail(request, "Invalid callback payload", 400);

    const signedString = BILLPLZ_CALLBACK_SIGNED_KEYS
      .map((key) => `${key}${get(key)}`)
      .join("|");
    const expectedSignature = await hmacSha256Hex(signedString, BILLPLZ_X_SIGNATURE_KEY);
    if (!timingSafeEqual(expectedSignature, signature)) {
      console.error("Billplz callback signature mismatch", billId);
      return fail(request, "Invalid signature", 400);
    }

    const token = await rpcScalar("get_booking_hold_token_by_bill", { p_bill_id: billId });
    if (!token) {
      // Unknown bill id — nothing to do, but acknowledge so Billplz doesn't retry forever.
      return json(request, { ok: true });
    }

    const paid = get("paid") === "true";
    try {
      if (paid) {
        await rpc("confirm_public_booking_hold", { p_token: token });
        await rpc("record_online_booking_payment", { p_token: token });
      } else {
        await rpc("mark_booking_hold_payment_failed", { p_token: token });
      }
    } catch (error) {
      console.error("Billplz callback processing failed", error);
      // Ask Billplz to retry instead of silently leaving a paid booking without
      // its transaction/payment status if confirmation or payment recording fails.
      return fail(request, "Callback processing failed", 500);
    }
    return json(request, { ok: true });
  }
  if (request.method === "POST" && path === "/booking-holds/confirm") {
    if (!AUTO_CONFIRM) return fail(request, "Confirmation is not enabled", 403);
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const token = uuid(body?.token);
    if (!token) return fail(request, "A valid booking reference is required");
    try {
      const rows = await rpc("confirm_public_booking_hold", { p_token: token }) as Array<Record<string, unknown>>;
      const appointment = rows[0];
      if (!appointment) return fail(request, "Unable to confirm this booking", 500);
      return json(request, { appointment: {
        id: appointment.appointment_id,
        status: appointment.status,
        start_at: appointment.start_at,
        end_at: appointment.end_at,
      } }, 201);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (/no longer be confirmed/i.test(message)) return fail(request, "This booking can no longer be confirmed.", 409);
      if (/not found/i.test(message)) return fail(request, "Booking reference not found", 404);
      throw error;
    }
  }
  if (request.method === "GET" && path === "/booking-holds/status") {
    const token = uuid(url.searchParams.get("token"));
    if (!token) return fail(request, "A valid booking reference is required");
    await rpc("expire_stale_booking_holds");
    const rows = await rpc("get_public_booking_hold_status_v2", { p_token: token }) as Array<Record<string, unknown>>;
    if (!rows[0]) return fail(request, "Booking reference not found", 404);
    const hold = rows[0];
    return json(request, { hold: {
      token: hold.token,
      status: hold.status,
      expires_at: hold.expires_at,
      total_price: Number(hold.total_price),
      start_at: hold.start_at,
      end_at: hold.end_at,
    } });
  }
  return fail(request, "Not found", 404);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: responseHeaders(request) });
  try { return await route(request); }
  catch (error) { console.error(error); return fail(request, "The booking service is temporarily unavailable", 500); }
});
