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

function origin(request: Request): string {
  const value = request.headers.get("origin") ?? "";
  const configured = (Deno.env.get("BOOKING_SITE_ORIGINS") ?? "").split(",").map((item) => item.trim()).filter(Boolean);
  if (!value) return "*";
  if (configured.includes("*") || configured.includes(value)) return value;
  if (/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i.test(value)) return value;
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

async function route(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const path = pathOf(request);
  if (request.method === "GET" && path === "/health") return json(request, { ok: true, payment_enabled: false });
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
