import { createClient } from "npm:@supabase/supabase-js@2";
import {
  fiuuHostedPaymentRequest,
  fiuuReversalRequest,
  fiuuResponseFromForm,
  fiuuResponseValidationIssue,
  fiuuStatusRequest,
  fiuuReturnProof,
  verifyFiuuReversalResponse,
  verifyFiuuReturnProof,
  verifyFiuuStatusResponse,
  type FiuuCredentials,
  type FiuuReversalResponse,
  type FiuuStatusResponse,
} from "./fiuu.ts";

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

// Public unpaid auto-confirm is permanently disabled. Paid conversion is only
// reached from a signature-verified gateway notification below.
const AUTO_CONFIRM = false;

// Never accept the gateway from a public request. The exact Supabase project
// selects Fiuu sandbox versus live; Billplz remains a dormant fallback.
const BOOKING_PAYMENT_GATEWAY = (Deno.env.get("BOOKING_PAYMENT_GATEWAY") ?? "billplz").trim();
const FIUU_SANDBOX_MERCHANT_ID = (Deno.env.get("FIUU_SANDBOX_MERCHANT_ID") ?? "").trim();
const FIUU_SANDBOX_VERIFY_KEY = (Deno.env.get("FIUU_SANDBOX_VERIFY_KEY") ?? "").trim();
const FIUU_SANDBOX_SECRET_KEY = (Deno.env.get("FIUU_SANDBOX_SECRET_KEY") ?? "").trim();
const FIUU_SANDBOX_EXTENDED_VCODE = (Deno.env.get("FIUU_SANDBOX_EXTENDED_VCODE") ?? "").trim();
const FIUU_LIVE_MERCHANT_ID = (Deno.env.get("FIUU_LIVE_MERCHANT_ID") ?? "").trim();
const FIUU_LIVE_VERIFY_KEY = (Deno.env.get("FIUU_LIVE_VERIFY_KEY") ?? "").trim();
const FIUU_LIVE_SECRET_KEY = (Deno.env.get("FIUU_LIVE_SECRET_KEY") ?? "").trim();
const FIUU_LIVE_EXTENDED_VCODE = (Deno.env.get("FIUU_LIVE_EXTENDED_VCODE") ?? "").trim();
const FIUU_SANDBOX_API_BASE_URL = (
  Deno.env.get("FIUU_SANDBOX_API_BASE_URL") ?? "https://sandbox-api.fiuu.com"
).trim();
const FIUU_LIVE_API_BASE_URL = (
  Deno.env.get("FIUU_LIVE_API_BASE_URL") ?? "https://api.fiuu.com"
).trim();

const STAGING_SUPABASE_ORIGIN = "https://hvyzexmsaxwendcexehx.supabase.co";
const PRODUCTION_SUPABASE_ORIGIN = "https://erjttzhownsxohpvzjbs.supabase.co";
type FiuuEnvironment = "sandbox" | "live";

function supabaseOrigin(): string {
  try {
    return new URL(supabaseUrl).origin.toLowerCase();
  } catch (_) {
    return "";
  }
}

function fiuuEnvironment(): FiuuEnvironment {
  const origin = supabaseOrigin();
  if (origin === STAGING_SUPABASE_ORIGIN) return "sandbox";
  if (origin === PRODUCTION_SUPABASE_ORIGIN) return "live";
  throw new Error("Fiuu is only configured for the named STAGING or PRODUCTION project");
}

function fiuuCredentials(): FiuuCredentials {
  const environment = fiuuEnvironment();
  const configured = environment === "sandbox"
    ? {
      merchantId: FIUU_SANDBOX_MERCHANT_ID,
      verifyKey: FIUU_SANDBOX_VERIFY_KEY,
      secretKey: FIUU_SANDBOX_SECRET_KEY,
      extendedVcode: FIUU_SANDBOX_EXTENDED_VCODE,
    }
    : {
      merchantId: FIUU_LIVE_MERCHANT_ID,
      verifyKey: FIUU_LIVE_VERIFY_KEY,
      secretKey: FIUU_LIVE_SECRET_KEY,
      extendedVcode: FIUU_LIVE_EXTENDED_VCODE,
    };
  const merchantMatchesEnvironment = environment === "sandbox"
    ? configured.merchantId.startsWith("SB_")
    : Boolean(configured.merchantId) && !configured.merchantId.startsWith("SB_");
  if (!merchantMatchesEnvironment || !configured.verifyKey ||
      !configured.secretKey || !["true", "false"].includes(configured.extendedVcode)) {
    throw new Error(`Fiuu ${environment} credentials are not configured for this project`);
  }
  return {
    merchantId: configured.merchantId,
    verifyKey: configured.verifyKey,
    secretKey: configured.secretKey,
    extendedVcode: configured.extendedVcode === "true",
  };
}

function fiuuConfigurationConfigured(): boolean {
  try {
    fiuuCredentials();
    fiuuApiBaseUrl();
    return true;
  } catch (_) {
    return false;
  }
}

function fiuuEnvironmentForHealth(): FiuuEnvironment | null {
  try {
    return fiuuEnvironment();
  } catch (_) {
    return null;
  }
}

function fiuuPaymentBaseUrl(): string {
  return fiuuEnvironment() === "sandbox"
    ? "https://sandbox-payment.fiuu.com"
    : "https://pay.fiuu.com";
}

function fiuuApiBaseUrl(): string {
  const environment = fiuuEnvironment();
  const raw = environment === "sandbox"
    ? FIUU_SANDBOX_API_BASE_URL
    : FIUU_LIVE_API_BASE_URL;
  const expectedHost = environment === "sandbox"
    ? "sandbox-api.fiuu.com"
    : "api.fiuu.com";
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "https:" || parsed.hostname.toLowerCase() !== expectedHost ||
        parsed.pathname !== "/" || parsed.search || parsed.hash) {
      throw new Error("invalid host");
    }
    return parsed.origin;
  } catch (_) {
    throw new Error(`Fiuu ${environment} API base URL is invalid`);
  }
}

// Billplz (sandbox or production, selected entirely by which base URL/keys are set).
// The configuration contract is the site origin; API paths are appended below.
function normalizeBillplzBaseUrl(value: string): string {
  return value
    .trim()
    .replace(/^=+\s*/, "")
    .replace(/\/+$/, "")
    .replace(/\/api$/i, "");
}

const BILLPLZ_BASE_URL = normalizeBillplzBaseUrl(
  Deno.env.get("BILLPLZ_BASE_URL") ?? "",
);
const BILLPLZ_API_KEY = (Deno.env.get("BILLPLZ_API_KEY") ?? "").trim();
const BILLPLZ_API_KEY_TAMAN_WAHYU = (
  Deno.env.get("BILLPLZ_API_KEY_TAMAN_WAHYU") ?? ""
).trim();
const BILLPLZ_COLLECTION_ID = (Deno.env.get("BILLPLZ_COLLECTION_ID") ?? "").trim();
const BILLPLZ_COLLECTION_ID_TAMAN_WAHYU = (
  Deno.env.get("BILLPLZ_COLLECTION_ID_TAMAN_WAHYU") ?? ""
).trim();
const BILLPLZ_COLLECTION_ID_PV128 = (
  Deno.env.get("BILLPLZ_COLLECTION_ID_PV128") ?? ""
).trim();
const BILLPLZ_X_SIGNATURE_KEY = (Deno.env.get("BILLPLZ_X_SIGNATURE_KEY") ?? "").trim();
const BILLPLZ_X_SIGNATURE_KEY_TAMAN_WAHYU = (
  Deno.env.get("BILLPLZ_X_SIGNATURE_KEY_TAMAN_WAHYU") ?? ""
).trim();
const BOOKING_CLEANUP_SECRET = (Deno.env.get("BOOKING_CLEANUP_SECRET") ?? "").trim();
const BILLPLZ_OUTLET_COLLECTION_MODE = Boolean(
  BILLPLZ_COLLECTION_ID_TAMAN_WAHYU || BILLPLZ_COLLECTION_ID_PV128,
);

type BillplzCredentials = {
  apiKey: string;
  collectionId: string;
  xSignatureKey: string;
};

function billplzCredentials(outletCode: string): BillplzCredentials {
  if (!BILLPLZ_OUTLET_COLLECTION_MODE) {
    if (BILLPLZ_API_KEY && BILLPLZ_COLLECTION_ID && BILLPLZ_X_SIGNATURE_KEY) {
      return {
        apiKey: BILLPLZ_API_KEY,
        collectionId: BILLPLZ_COLLECTION_ID,
        xSignatureKey: BILLPLZ_X_SIGNATURE_KEY,
      };
    }
    throw new Error("Payment credentials are not configured");
  }
  const credentials = outletCode === "taman-wahyu"
    ? {
      apiKey: BILLPLZ_API_KEY_TAMAN_WAHYU,
      collectionId: BILLPLZ_COLLECTION_ID_TAMAN_WAHYU,
      xSignatureKey: BILLPLZ_X_SIGNATURE_KEY_TAMAN_WAHYU,
    }
    : outletCode === "pv128"
    ? {
      apiKey: BILLPLZ_API_KEY,
      collectionId: BILLPLZ_COLLECTION_ID_PV128,
      xSignatureKey: BILLPLZ_X_SIGNATURE_KEY,
    }
    : null;
  if (
    !credentials?.apiKey || !credentials.collectionId ||
    !credentials.xSignatureKey
  ) {
    throw new Error("Payment credentials are not configured for this outlet");
  }
  return credentials;
}

function billplzCredentialsForCollection(collectionId: string): BillplzCredentials {
  if (!BILLPLZ_OUTLET_COLLECTION_MODE) {
    const credentials = billplzCredentials("");
    if (collectionId === credentials.collectionId) return credentials;
  } else if (collectionId === BILLPLZ_COLLECTION_ID_TAMAN_WAHYU) {
    return billplzCredentials("taman-wahyu");
  } else if (collectionId === BILLPLZ_COLLECTION_ID_PV128) {
    return billplzCredentials("pv128");
  }
  throw new Error("Payment callback collection is not configured");
}

function billplzOutletConfigured(outletCode: string): boolean {
  try {
    billplzCredentials(outletCode);
    return true;
  } catch (_) {
    return false;
  }
}

const BILLPLZ_CONFIGURED = Boolean(
  BILLPLZ_BASE_URL && (
    BILLPLZ_OUTLET_COLLECTION_MODE
      ? billplzOutletConfigured("taman-wahyu") && billplzOutletConfigured("pv128")
      : billplzOutletConfigured("")
  ),
);

function billplzUrl(path: string): string {
  return `${BILLPLZ_BASE_URL}/${path.replace(/^\/+/, "")}`;
}
// Where to send the customer's browser back to after paying. Falls back to the
// first configured site origin (used for CORS) so a dedicated var isn't required.
const BOOKING_REDIRECT_BASE = (
  Deno.env.get("BOOKING_REDIRECT_URL") ??
  (Deno.env.get("BOOKING_SITE_ORIGINS") ?? "").split(",")[0] ??
  ""
).trim().replace(/\/$/, "");
const BOOKING_RETURN_PATHS = new Set([
  "/booking",
  "/booking-taman-wahyu",
  "/booking-pv128",
]);

function bookingRedirectUrl(token: string, requestedPath: unknown): string | null {
  if (!BOOKING_REDIRECT_BASE) return null;
  const base = new URL(BOOKING_REDIRECT_BASE);
  const path = typeof requestedPath === "string" && BOOKING_RETURN_PATHS.has(requestedPath)
    ? requestedPath
    : null;
  // A configured non-root URL is already a complete destination. An explicit
  // allowlisted outlet path may replace it, but no suffix is ever appended.
  const redirect = path ? new URL(path, `${base.origin}/`) : new URL(base.toString());
  redirect.searchParams.set("bp_token", token);
  return redirect.toString();
}

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

async function billplzRequest(
  path: string,
  body: Record<string, string>,
  credentials: BillplzCredentials,
) {
  const response = await fetch(billplzUrl(path), {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${credentials.apiKey}:`)}`,
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

function billplzBillUrl(billId: string): string {
  return billplzUrl(`/bills/${encodeURIComponent(billId)}`);
}

async function deleteBillplzBill(
  billId: string,
  credentials: BillplzCredentials,
): Promise<void> {
  if (!billId) return;
  const response = await fetch(
    billplzUrl(`/api/v3/bills/${encodeURIComponent(billId)}`),
    {
      method: "DELETE",
      headers: { Authorization: `Basic ${btoa(`${credentials.apiKey}:`)}` },
    },
  );
  if (response.ok || response.status === 404) return;
  const payload = await response.json().catch(() => ({})) as Record<string, unknown>;
  const detail = billplzErrorDetail(payload);
  throw new Error(
    `Unable to cancel Billplz bill (${response.status})${detail ? `: ${detail}` : ""}`,
  );
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

function responseHeaders(request: Request): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": origin(request),
    "Access-Control-Allow-Headers": "apikey, authorization, content-type, x-client-info, x-booking-cleanup-secret",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Expose-Headers": "Retry-After",
    "Content-Type": "application/json; charset=utf-8",
    Vary: "Origin",
  };
}

function json(
  request: Request,
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...responseHeaders(request), ...extraHeaders },
  });
}
function fail(
  request: Request,
  message: string,
  status = 400,
  code?: string,
): Response {
  return json(request, { error: message, ...(code ? { code } : {}) }, status);
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object") {
    const message = (error as Record<string, unknown>).message;
    if (typeof message === "string") return message;
  }
  return String(error);
}

function rpcErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object") return null;
  const record = error as Record<string, unknown>;
  for (const value of [record.details, record.hint, record.message]) {
    const match = String(value ?? "").match(/\b((?:PROMOTION|HOLD)_[A-Z0-9_]+)\b/);
    if (match) return match[1];
  }
  return null;
}

function isPromotionError(error: unknown): boolean {
  const code = rpcErrorCode(error);
  return Boolean(code?.startsWith("PROMOTION_"));
}

function operationalErrorLabel(error: unknown): string {
  return rpcErrorCode(error) ?? (error instanceof Error ? error.name : "UnknownError");
}

const GENERIC_PROMOTION_ERROR_CODES = new Set([
  "PROMOTION_INVALID",
  "PROMOTION_NOT_FOUND",
  "PROMOTION_INACTIVE",
  "PROMOTION_EXPIRED",
  "PROMOTION_FULLY_REDEEMED",
  "PROMOTION_ALREADY_REDEEMED",
]);
const GENERIC_PROMOTION_ERROR_MESSAGE = "The promotional code is invalid.";
const FULLY_REDEEMED_PROMOTION_MESSAGE = "This promotion has been fully redeemed.";

function publicPromotionFailure(
  request: Request,
  message: string,
  status: number,
  internalCode: string | null | undefined,
  promotionUsageType: string | null = null,
): Response {
  const code = String(internalCode ?? "");
  if (code === "PROMOTION_FULLY_REDEEMED" && promotionUsageType === "multi_use") {
    return fail(request, FULLY_REDEEMED_PROMOTION_MESSAGE, status, code);
  }
  if (GENERIC_PROMOTION_ERROR_CODES.has(code)) {
    return fail(request, GENERIC_PROMOTION_ERROR_MESSAGE, status, "PROMOTION_INVALID");
  }
  return fail(request, message, status, code || "PROMOTION_INVALID");
}

type PublicBookingPricing = {
  subtotal_amount: number;
  discount_amount: number;
  final_amount: number;
  promotion_id: string | null;
  promotion_code: string | null;
  benefit_type: string | null;
  benefit_value: number | null;
  maximum_discount?: number | null;
  free_addon_service_name: string | null;
};

function optionalNumber(value: unknown): number | null {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function maximumDiscountFromRow(row: Record<string, unknown>): number | null | undefined {
  if (Object.prototype.hasOwnProperty.call(row, "maximum_discount")) {
    return optionalNumber(row.maximum_discount);
  }
  const snapshot = row.pricing_snapshot && typeof row.pricing_snapshot === "object"
    ? row.pricing_snapshot as Record<string, unknown>
    : null;
  if (snapshot && Object.prototype.hasOwnProperty.call(snapshot, "maximum_discount")) {
    return optionalNumber(snapshot.maximum_discount);
  }
  return undefined;
}

function publicBookingPricingRow(row: Record<string, unknown>): PublicBookingPricing {
  return {
    subtotal_amount: Number(row.subtotal_amount ?? 0),
    discount_amount: Number(row.discount_amount ?? 0),
    final_amount: Number(row.final_amount ?? 0),
    promotion_id: row.promotion_id ? String(row.promotion_id) : null,
    promotion_code: row.promotion_code ? String(row.promotion_code) : null,
    benefit_type: row.benefit_type ? String(row.benefit_type) : null,
    benefit_value: row.benefit_value == null ? null : Number(row.benefit_value),
    maximum_discount: maximumDiscountFromRow(row),
    free_addon_service_name: row.free_addon_service_name ? String(row.free_addon_service_name) : null,
  };
}
function pathOf(request: Request): string {
  const path = new URL(request.url).pathname;
  const index = path.indexOf("/booking-api");
  return index < 0 ? path : path.slice(index + 12) || "/";
}
function uuid(value: unknown): string | null { const text = String(value ?? "").trim(); return UUID.test(text) ? text : null; }
function preference(value: unknown): string { const text = String(value ?? "none").toLowerCase(); return PREFERENCES.has(text) ? text : "none"; }

type GroupAllocation = {
  catalogue_id: string;
  therapist_preference: string;
  therapist_request: string;
  guest_name: string;
};

function groupAllocations(value: unknown): GroupAllocation[] | null {
  if (!Array.isArray(value) || value.length < 1 || value.length > 6) return null;
  const rows: GroupAllocation[] = [];
  for (let index = 0; index < value.length; index++) {
    const item = value[index] as Record<string, unknown> | null;
    const catalogueId = uuid(item?.catalogue_id);
    if (!catalogueId) return null;
    rows.push({
      catalogue_id: catalogueId,
      therapist_preference: preference(item?.therapist_preference),
      therapist_request: String(item?.therapist_request ?? "").trim().slice(0, 200),
      guest_name: String(item?.guest_name ?? `Guest ${index + 1}`).trim().slice(0, 80) || `Guest ${index + 1}`,
    });
  }
  return rows;
}

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

// Billplz caps the bill description at 200 characters and shows it verbatim on the
// payment page and on its own receipt, so it is the only place we can tell the
// customer what they actually paid for. Fields come from
// get_booking_hold_for_payment / get_booking_group_for_payment (090, 091); each one
// is optional so an older deployed RPC degrades to the previous short reference
// instead of printing "undefined" on a live receipt.
//
// Deliberately omitted, both confirmed against a real rendered bill page:
//  - Guest name/email/mobile: Billplz already shows these as their own fields.
//  - A booking reference: Billplz already shows its own "Bill ID", which (prefixed
//    "BP-") is exactly the receipt_number the app displays once paid. A second,
//    different-looking reference here (sliced from our token, since Billplz hasn't
//    assigned its id yet when this text is built) only reads as a mismatch next to
//    Billplz's real one — see get_booking_hold_for_payment / _group_for_payment
//    (092) for where the matching app reference is actually surfaced, on our own
//    site's post-payment confirmation.
const BILLPLZ_DESCRIPTION_LIMIT = 200;

// Billplz renders the description as one unbroken line, so " | " plus a label per
// segment ("Date:", "Notes:") is what gives it visible structure — real line
// breaks aren't an option on a page we don't control.
function billDescription(hold: Record<string, unknown>): string {
  const text = (value: unknown) => String(value ?? "").trim();
  // Notes are free-typed by the customer; strip characters that would fake another
  // segment or break the line the receipt renders as.
  const sanitize = (value: string) => value.replace(/[\r\n|]+/g, " ").replace(/\s+/g, " ").trim();

  const outlet = text(hold.outlet_name);
  const service = text(hold.service_summary);
  const pax = Number(hold.pax_count);
  let serviceLine = service;
  if (service) {
    // The group summary already carries its own per-guest counts and durations.
    const minutes = Number(hold.duration_minutes);
    serviceLine = Number.isFinite(minutes) && minutes > 0 && !/\dmin/.test(service)
      ? `${service} ${minutes}min`
      : service;
    if (Number.isFinite(pax) && pax > 1) serviceLine += ` for ${pax} pax`;
  }

  let whenLine = "";
  const startAt = text(hold.start_at);
  if (startAt) {
    const when = new Date(startAt);
    if (!Number.isNaN(when.getTime())) {
      // Guests read the receipt in Malaysian time, not the server's UTC.
      whenLine = new Intl.DateTimeFormat("en-MY", {
        timeZone: "Asia/Kuala_Lumpur",
        weekday: "short", day: "numeric", month: "short",
        hour: "numeric", minute: "2-digit", hour12: true,
      }).format(when).replace(/\s+/g, " ");
    }
  }

  // Always short, always kept in full and in this order.
  const before = [
    outlet ? `The Best Wellness ${outlet}` : "The Best Wellness",
    serviceLine,
    whenLine ? `Date: ${whenLine}` : "",
  ].filter(Boolean);

  const notes = sanitize(text(hold.notes));
  if (!notes) return before.join(" | ");

  // Notes are open-ended text, so they're the only segment that can overflow the
  // limit — trim the note itself rather than truncating the core details above.
  const fixedLength = before.join(" | ").length;
  const budget = BILLPLZ_DESCRIPTION_LIMIT - fixedLength - " | Notes: ".length;
  if (budget < 10) return before.join(" | ");
  const notesLine = notes.length <= budget ? notes : `${notes.slice(0, budget - 1).trimEnd()}…`;
  return [...before, `Notes: ${notesLine}`].join(" | ");
}

async function hashedRateLimitSubject(value: string): Promise<string> {
  const salt = Deno.env.get("BOOKING_RATE_LIMIT_SALT") || supabaseUrl;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}|${value}`));
  return [...new Uint8Array(digest)].map((value) => value.toString(16).padStart(2, "0")).join("");
}

async function fingerprint(request: Request): Promise<string> {
  // Supabase's public function endpoint is fronted by Cloudflare. Cloudflare
  // writes CF-Connecting-IP from the client connection; do not trust a caller's
  // left-most X-Forwarded-For value for either abuse controls or hold quotas.
  const address = request.headers.get("cf-connecting-ip")?.trim();
  if (!address || address.length > 64 || !/^[0-9a-f:.]+$/i.test(address)) {
    throw new Error("Trusted client address is unavailable");
  }
  return hashedRateLimitSubject(`ip:${address}`);
}

type RateLimitRow = {
  allowed: boolean;
  retry_after_seconds: number;
  remaining: number;
};

async function consumeRateLimit(
  subjectHash: string,
  routeKey: string,
  limit: number,
  windowSeconds: number,
): Promise<RateLimitRow> {
  const rows = await rpc("consume_booking_rate_limit", {
    p_subject_hash: subjectHash,
    p_route_key: routeKey,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  }) as RateLimitRow[];
  if (!rows[0]) throw new Error("Rate limiter did not return a result");
  return rows[0];
}

function rateLimited(request: Request, retryAfter: number): Response {
  return json(
    request,
    { error: "Too many requests. Please try again later." },
    429,
    { "Retry-After": String(Math.max(1, Math.ceil(retryAfter))) },
  );
}

async function enforceIpRateLimit(
  request: Request,
  path: string,
): Promise<Response | null> {
  let rule: [string, number, number] | null = null;
  if (request.method === "GET" && (path === "/outlets" || path === "/catalogue")) {
    rule = ["catalogue", 60, 60];
  } else if (path.startsWith("/availability/")) {
    rule = ["availability", 120, 60];
  } else if (
    request.method === "POST" &&
    (path === "/booking-holds" || path === "/booking-groups")
  ) {
    rule = ["hold", 12, 3600];
  } else if (
    request.method === "POST" &&
    (path === "/booking-holds/promotion" || path === "/booking-holds/promotion/remove")
  ) {
    rule = ["promotion", 20, 600];
  } else if (request.method === "POST" && path === "/booking-holds/pay") {
    rule = ["payment", 10, 600];
  } else if (request.method === "GET" && path === "/booking-holds/status") {
    rule = ["status", 60, 60];
  }
  if (!rule) return null;

  let subjectHash: string;
  try {
    subjectHash = await fingerprint(request);
  } catch (error) {
    console.error("Rate limiting rejected an untrusted client address", error);
    return fail(request, "Unable to verify the client address", 503);
  }

  const result = await consumeRateLimit(subjectHash, rule[0], rule[1], rule[2]);
  if (!result.allowed) return rateLimited(request, result.retry_after_seconds);

  if (rule[0] === "hold") {
    const burst = await consumeRateLimit(subjectHash, "hold_burst", 4, 120);
    if (!burst.allowed) return rateLimited(request, burst.retry_after_seconds);
  }
  return null;
}

async function enforceTokenRateLimit(
  request: Request,
  token: string,
  routeKey: string,
  limit: number,
  windowSeconds: number,
): Promise<Response | null> {
  const subjectHash = await hashedRateLimitSubject(`booking:${token}`);
  const result = await consumeRateLimit(subjectHash, routeKey, limit, windowSeconds);
  return result.allowed ? null : rateLimited(request, result.retry_after_seconds);
}

async function rpc(name: string, args: Record<string, unknown> = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data ?? [];
}

async function publicBookingOutlets() {
  const [publicRows, outletResult, hoursResult] = await Promise.all([
    rpc("list_public_booking_outlets_v2") as Promise<
      Array<Record<string, unknown>>
    >,
    supabase.from("outlets").select("id,code").eq("is_active", true),
    supabase.from("business_settings").select("outlet_id,open_time,close_time"),
  ]);
  if (outletResult.error) throw outletResult.error;
  if (hoursResult.error) throw hoursResult.error;

  const codeByOutletId = new Map(
    (outletResult.data ?? []).map((row) => [String(row.id), String(row.code)]),
  );
  const hoursByCode = new Map(
    (hoursResult.data ?? []).map((row) => [
      codeByOutletId.get(String(row.outlet_id)),
      { open_time: row.open_time, close_time: row.close_time },
    ]),
  );
  return publicRows.map((row) => ({
    ...row,
    ...(hoursByCode.get(String(row.code)) ?? {}),
  }));
}

// For RPCs that return a single scalar (not `returns table`), where a real
// `null` result (e.g. "no matching row") must stay distinguishable from [].
async function rpcScalar<T = string>(
  name: string,
  args: Record<string, unknown> = {},
): Promise<T | null> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data as T | null;
}

type BookingPromotionMetadata = {
  usage_type?: unknown;
  maximum_discount?: unknown;
};

async function bookingPromotionMetadata(args: {
  promotionId?: string | null;
  code?: string | null;
}): Promise<BookingPromotionMetadata | null> {
  const { data, error } = await supabase.rpc("get_booking_promotion_metadata", {
    p_promotion_id: args.promotionId ?? null,
    p_code: args.code ?? null,
  });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  return row && typeof row === "object" ? row as BookingPromotionMetadata : null;
}

// This lookup only decides whether a fully redeemed code is reusable or
// single-use. It is deliberately silent on failure and never logs the code.
async function promotionUsageTypeForCode(code: string): Promise<string | null> {
  const normalizedCode = code.trim().toUpperCase();
  if (!normalizedCode) return null;
  try {
    const metadata = await bookingPromotionMetadata({ code: normalizedCode });
    const usageType = String(metadata?.usage_type ?? "");
    return usageType || null;
  } catch (_) {
    return null;
  }
}

const promotionMaximumDiscountCache = new Map<
  string,
  { value: number | null; expiresAt: number }
>();
const PROMOTION_METADATA_CACHE_MS = 60_000;

async function promotionMaximumDiscount(promotionId: string): Promise<number | null> {
  const cached = promotionMaximumDiscountCache.get(promotionId);
  if (cached && cached.expiresAt > Date.now()) return cached.value;

  const metadata = await bookingPromotionMetadata({ promotionId });
  const value = optionalNumber(metadata?.maximum_discount);
  promotionMaximumDiscountCache.set(promotionId, {
    value,
    expiresAt: Date.now() + PROMOTION_METADATA_CACHE_MS,
  });
  return value;
}

async function publicBookingPricing(token: string): Promise<PublicBookingPricing | null> {
  const rows = await rpc("get_public_booking_pricing", { p_token: token }) as Array<Record<string, unknown>>;
  const pricing = rows[0] ? publicBookingPricingRow(rows[0]) : null;
  if (
    pricing?.promotion_id &&
    pricing.benefit_type === "percentage_discount" &&
    pricing.maximum_discount == null
  ) {
    try {
      pricing.maximum_discount = await promotionMaximumDiscount(pricing.promotion_id);
    } catch (error) {
      // The cap is display metadata only; never let an optional lookup break
      // server-authoritative pricing or an otherwise valid booking.
      console.error("Unable to load optional promotion display metadata", error);
      pricing.maximum_discount = null;
    }
  }
  return pricing;
}

function publicPricingPayload(pricing: PublicBookingPricing | null): Record<string, unknown> | null {
  if (!pricing) return null;
  return {
    subtotal_amount: pricing.subtotal_amount,
    discount_amount: pricing.discount_amount,
    final_amount: pricing.final_amount,
    promotion_code: pricing.promotion_code,
    benefit_type: pricing.benefit_type,
    benefit_value: pricing.benefit_value,
    maximum_discount: pricing.maximum_discount ?? null,
    free_addon_service_name: pricing.free_addon_service_name,
  };
}

function promotionPayload(pricing: PublicBookingPricing | null): Record<string, unknown> | null {
  if (!pricing?.promotion_code) return null;
  return {
    code: pricing.promotion_code,
    benefit_type: pricing.benefit_type,
    benefit_value: pricing.benefit_value,
    maximum_discount: pricing.maximum_discount ?? null,
    free_addon_service_name: pricing.free_addon_service_name,
  };
}

type BookingBillBinding = {
  public_token: string;
  booking_group_token: string | null;
  guest_index: number | null;
  outlet_id: string;
  billplz_bill_id: string | null;
  status: string;
  expires_at: string;
};

type FiuuAttempt = {
  id: string;
  hold_token: string;
  outlet_id: string;
  merchant_id: string;
  order_id: string;
  amount: number;
  expires_at: string;
  status: string;
  gateway_transaction_id: string | null;
};

const FIUU_ORDER_ID = /^W[a-f0-9]{32}$/;

async function fiuuAttemptByOrder(orderId: string): Promise<FiuuAttempt | null> {
  if (!FIUU_ORDER_ID.test(orderId)) return null;
  const result = await supabase.from("booking_payment_attempts")
    .select("id,hold_token,outlet_id,merchant_id,order_id,amount,expires_at,status,gateway_transaction_id")
    .eq("order_id", orderId).maybeSingle();
  if (result.error) throw result.error;
  return result.data as FiuuAttempt | null;
}

async function startFiuuPayment(
  request: Request,
  token: string,
  requestedPath: unknown,
): Promise<Response> {
  const credentials = fiuuCredentials();
  if (!BOOKING_REDIRECT_BASE) return fail(request, "Payment return is not configured.", 503);
  const binding = await bookingBillBinding(token);
  if (!binding) return fail(request, "Booking reference not found", 404);
  if (binding.status !== "pending_payment" || bindingIsExpired(binding)) {
    return fail(request, "This booking hold has expired. Please start again.", 409);
  }
  if (binding.billplz_bill_id) {
    return fail(request, "This booking already has a different payment link.", 409);
  }
  const outletCode = await bookingOutletCode(binding);
  if (!new Set(["taman-wahyu", "pv128"]).has(outletCode)) {
    return fail(request, "Payment is not configured for this outlet.", 503);
  }
  let rows = await rpc("get_booking_group_for_payment", { p_token: token }) as Array<Record<string, unknown>>;
  if (!rows[0]) rows = await rpc("get_booking_hold_for_payment", { p_token: token }) as Array<Record<string, unknown>>;
  const hold = rows[0];
  if (!hold || String(hold.status) !== "pending_payment" ||
      new Date(String(hold.expires_at)).getTime() <= Date.now()) {
    return fail(request, "This booking hold has expired. Please start again.", 409);
  }
  const amount = Number(hold.total_amount);
  if (!Number.isFinite(amount) || amount <= 0) {
    return fail(request, "The booking price is unavailable.", 409);
  }
  const orderId = `W${crypto.randomUUID().replaceAll("-", "")}`;
  const attempt = await rpcScalar<FiuuAttempt>("claim_fiuu_payment_attempt", {
    p_token: token,
    p_order_id: orderId,
    p_merchant_id: credentials.merchantId,
    p_amount: Number(amount.toFixed(2)),
    p_expires_at: hold.expires_at,
  });
  if (!attempt || !["created", "pending"].includes(attempt.status)) {
    return fail(request, "This booking can no longer accept payment.", 409);
  }
  const returnUrl = new URL(`${supabaseUrl}/functions/v1/booking-api/fiuu/return`);
  returnUrl.searchParams.set("order", attempt.order_id);
  returnUrl.searchParams.set("proof", fiuuReturnProof(attempt.order_id, credentials.secretKey));
  const cancelUrl = bookingRedirectUrl(token, requestedPath);
  if (!cancelUrl) return fail(request, "Payment return is not configured.", 503);
  const waitTimeSeconds = Math.max(
    1,
    Math.floor((new Date(attempt.expires_at).getTime() - Date.now()) / 1000),
  );
  const checkout = fiuuHostedPaymentRequest({
    environment: fiuuEnvironment(),
    credentials,
    orderId: attempt.order_id,
    amount: Number(attempt.amount).toFixed(2),
    customerName: String(hold.customer_name ?? ""),
    customerEmail: String(hold.customer_email ?? ""),
    customerMobile: normalizeMyPhone(String(hold.customer_phone ?? "")),
    description: billDescription(hold),
    expiresAt: new Date(attempt.expires_at),
    waitTimeSeconds,
    returnUrl: returnUrl.toString(),
    callbackUrl: `${supabaseUrl}/functions/v1/booking-api/fiuu/callback`,
    cancelUrl,
  });
  return json(request, {
    action: checkout.action,
    fields: checkout.fields,
    reused: attempt.order_id !== orderId,
  },
    attempt.order_id === orderId ? 201 : 200);
}

async function acknowledgeFiuuIpn(form: FormData): Promise<boolean> {
  const ack = new URLSearchParams();
  for (const [name, value] of form.entries()) {
    if (typeof value !== "string") return false;
    ack.append(name, value);
  }
  ack.set("treq", "1");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000);
  try {
    const result = await fetch(
      `${fiuuPaymentBaseUrl()}/RMS/API/chkstat/returnipn.php`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: ack.toString(),
        signal: controller.signal,
      },
    );
    return result.ok;
  } catch (_) {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

async function fiuuReturnRedirect(attempt: FiuuAttempt): Promise<Response> {
  // The shared booking route loads the confirmed booking from its hold token.
  // Older staging deployments do not yet expose the outlet-specific aliases.
  const redirect = bookingRedirectUrl(attempt.hold_token, "/booking");
  if (!redirect) return new Response("Payment return is not configured", { status: 503 });
  return new Response(null, {
    status: 303,
    headers: { Location: redirect, "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer" },
  });
}

async function handleFiuuNotification(
  request: Request,
  kind: "return" | "notification" | "callback",
): Promise<Response> {
  const credentials = fiuuCredentials();
  const form = await request.formData().catch(() => null);
  if (kind === "return" && (!form || !["skey", "tranID", "status", "amount"]
    .some((name) => String(form.get(name) ?? "").length > 0))) {
    // Fiuu can POST an empty browser-return form. A signed URL may restore
    // navigation, but this path must never mark the payment as paid.
    const url = new URL(request.url);
    const orderId = url.searchParams.get("order") ?? "";
    const proof = url.searchParams.get("proof") ?? "";
    if (!verifyFiuuReturnProof(orderId, proof, credentials.secretKey)) {
      return fail(request, "Invalid payment return", 400);
    }
    const attempt = await fiuuAttemptByOrder(orderId);
    if (!attempt || attempt.merchant_id !== credentials.merchantId) {
      return fail(request, "Invalid payment return", 400);
    }
    console.warn("Fiuu browser return contained no payment fields");
    return fiuuReturnRedirect(attempt);
  }
  if (!form) {
    console.warn("Fiuu response rejected", kind, "form_parse");
    return fail(request, "Invalid payment response", 400);
  }
  // An e-wallet can omit appcode; the signature still covers its empty value.
  const invalidFields = ["amount", "orderid", "tranID", "domain", "status",
    "skey", "currency", "paydate"]
    .filter((name) => form.getAll(name).length !== 1);
  if (form.getAll("appcode").length > 1) invalidFields.push("appcode");
  if (invalidFields.length) {
    console.warn("Fiuu response rejected", kind, "field_count", invalidFields);
    return fail(request, "Invalid payment response", 400);
  }
  const response = fiuuResponseFromForm(form);
  const attempt = await fiuuAttemptByOrder(response.orderid);
  if (!attempt) {
    console.warn("Fiuu response rejected", kind, "unknown_order");
    return fail(request, "Invalid payment response", 400);
  }
  const issue = fiuuResponseValidationIssue(response, {
    credentials,
    orderId: attempt.order_id,
    amount: Number(attempt.amount).toFixed(2),
  });
  if (issue) {
    console.warn("Fiuu response rejected", kind, issue);
    return fail(request, "Invalid payment response", 400);
  }

  if (kind === "return") {
    // A signed browser return is not independent payment evidence. The site
    // continues polling until a verified server notification records it.
    if (!(await acknowledgeFiuuIpn(form))) {
      console.warn("Fiuu return IPN acknowledgement failed");
    }
    return fiuuReturnRedirect(attempt);
  }

  const outcome = await rpcScalar<string>("process_verified_fiuu_payment", {
    p_order_id: response.orderid,
    p_merchant_id: response.domain,
    p_amount: Number(response.amount),
    p_transaction_id: response.tranID,
    p_status: response.status,
    p_channel: response.channel || null,
  });
  if (!outcome) return fail(request, "Payment notification was not recorded", 500);
  if (outcome === "refund_required") {
    const queued = await rpcScalar<FiuuRefund>("queue_fiuu_refund_reconciliation", {
      p_order_id: response.orderid,
      p_transaction_id: response.tranID,
    });
    if (!queued) return fail(request, "Payment refund was not queued", 500);
    console.warn("Fiuu late payment queued for refund reconciliation", response.orderid);
  } else if (outcome === "review_different_transaction") {
    console.warn("Fiuu payment needs reconciliation", response.orderid, outcome);
  }

  if (kind === "callback") {
    return new Response("CBTOKEN:MPSTATOK", {
      status: 200,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }

  // Notification URL IPN also needs the POST-back acknowledgement.
  if (!(await acknowledgeFiuuIpn(form))) {
    return fail(request, "Payment acknowledgement failed", 503);
  }
  return new Response("OK", {
    status: 200,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}

type FiuuRefund = {
  id: string;
  attempt_id: string;
  gateway_transaction_id: string;
  amount: number;
  status: string;
  claim_token: string | null;
  gateway_refund_id: string | null;
  requested_at: string | null;
};

function fiuuReversalUrl(): string {
  return `${fiuuApiBaseUrl()}/RMS/API/refundAPI/refund.php`;
}

function fiuuStatusUrl(): string {
  return `${fiuuApiBaseUrl()}/RMS/API/gate-query/index.php`;
}

async function postFiuuJson(
  url: string,
  fields: Record<string, string>,
): Promise<Record<string, unknown>> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(fields).toString(),
      signal: controller.signal,
    });
    const body = await response.text();
    if (!response.ok) throw new Error(`Fiuu API returned HTTP ${response.status}`);
    try {
      return JSON.parse(body) as Record<string, unknown>;
    } catch (_) {
      throw new Error("Fiuu API returned an invalid response");
    }
  } finally {
    clearTimeout(timeout);
  }
}

function fiuuReversalResponseFromPayload(
  payload: Record<string, unknown>,
): FiuuReversalResponse {
  return {
    TranID: String(payload.TranID ?? ""),
    Domain: String(payload.Domain ?? ""),
    VrfKey: String(payload.VrfKey ?? ""),
    StatCode: String(payload.StatCode ?? ""),
    StatDate: String(payload.StatDate ?? ""),
    refundID: String(payload.refundID ?? ""),
  };
}

function fiuuStatusResponseFromPayload(
  payload: Record<string, unknown>,
): FiuuStatusResponse {
  return {
    Amount: String(payload.Amount ?? ""),
    TranID: String(payload.TranID ?? ""),
    Domain: String(payload.Domain ?? ""),
    Channel: String(payload.Channel ?? ""),
    VrfKey: String(payload.VrfKey ?? ""),
    StatCode: String(payload.StatCode ?? ""),
    StatName: String(payload.StatName ?? ""),
    Currency: String(payload.Currency ?? ""),
    ErrorCode: String(payload.ErrorCode ?? ""),
    ErrorDesc: String(payload.ErrorDesc ?? ""),
  };
}

async function checkNextFiuuRefundStatus(): Promise<Record<string, unknown> | null> {
  const refund = await rpcScalar<FiuuRefund>("claim_fiuu_refund_status_check");
  // PostgREST can represent a null composite returned by PostgreSQL as an
  // object whose fields are all null. Treat that as the documented "no work"
  // result instead of turning every idle maintenance run into HTTP 500.
  if (!refund || !refund.id) return null;
  if (!refund.claim_token) throw new Error("Fiuu refund status claim is incomplete");
  const credentials = fiuuCredentials();
  const amount = Number(refund.amount).toFixed(2);
  try {
    const request = fiuuStatusRequest(
      refund.gateway_transaction_id,
      amount,
      credentials,
    );
    const payload = await postFiuuJson(fiuuStatusUrl(), request.fields);
    const response = fiuuStatusResponseFromPayload(payload);
    if (!verifyFiuuStatusResponse(
      response,
      refund.gateway_transaction_id,
      amount,
      credentials,
    )) {
      await rpcScalar<boolean>("fail_fiuu_refund_status_check", {
        p_claim_token: refund.claim_token,
        p_error: "Fiuu status response signature was invalid",
        p_needs_review: true,
      });
      return { action: "status_check", outcome: "needs_review" };
    }
    const outcome = await rpcScalar<string>("complete_fiuu_refund_status_check", {
      p_claim_token: refund.claim_token,
      p_gateway_status: response.StatCode,
      p_status_name: response.StatName,
      p_error_code: response.ErrorCode,
      p_error: response.ErrorDesc,
    });
    return { action: "status_check", outcome: outcome ?? "unknown" };
  } catch (error) {
    await rpcScalar<boolean>("fail_fiuu_refund_status_check", {
      p_claim_token: refund.claim_token,
      p_error: errorMessage(error),
      p_needs_review: false,
    });
    return { action: "status_check", outcome: "retry_scheduled" };
  }
}

async function submitNextFiuuRefund(): Promise<Record<string, unknown> | null> {
  const refund = await rpcScalar<FiuuRefund>("claim_fiuu_refund_submission");
  if (!refund || !refund.id) return null;
  if (!refund.claim_token) throw new Error("Fiuu refund submission claim is incomplete");
  const credentials = fiuuCredentials();
  try {
    const request = fiuuReversalRequest(
      refund.gateway_transaction_id,
      credentials,
    );
    const payload = await postFiuuJson(fiuuReversalUrl(), request.fields);
    if (typeof payload.error_code === "string") {
      const outcome = await rpcScalar<string>("complete_fiuu_refund_submission", {
        p_claim_token: refund.claim_token,
        p_gateway_refund_id: null,
        p_gateway_status: null,
        p_accepted: false,
        p_error_code: String(payload.error_code),
        p_error: String(payload.error_desc ?? "Fiuu rejected the refund request"),
      });
      return { action: "refund_submission", outcome: outcome ?? "needs_review" };
    }
    const response = fiuuReversalResponseFromPayload(payload);
    if (!verifyFiuuReversalResponse(
      response,
      refund.gateway_transaction_id,
      credentials,
    )) {
      await rpcScalar<boolean>("fail_fiuu_refund_submission", {
        p_claim_token: refund.claim_token,
        p_error: "Fiuu refund response signature was invalid",
      });
      return { action: "refund_submission", outcome: "needs_review" };
    }
    const outcome = await rpcScalar<string>("complete_fiuu_refund_submission", {
      p_claim_token: refund.claim_token,
      p_gateway_refund_id: response.refundID,
      p_gateway_status: response.StatCode,
      p_accepted: response.StatCode === "00",
      p_error_code: response.StatCode === "00" ? null : response.StatCode,
      p_error: response.StatCode === "00" ? null : "Fiuu rejected the refund request",
    });
    return { action: "refund_submission", outcome: outcome ?? "unknown" };
  } catch (error) {
    await rpcScalar<boolean>("fail_fiuu_refund_submission", {
      p_claim_token: refund.claim_token,
      p_error: errorMessage(error),
    });
    return { action: "refund_submission", outcome: "needs_review" };
  }
}

async function maintainFiuuRefunds(): Promise<Record<string, unknown>> {
  const staleSubmissions = await rpcScalar<number>(
    "mark_stale_fiuu_refund_submissions_for_review",
  ) ?? 0;
  // Fiuu documents a maximum query frequency. Process at most one gateway API
  // request per maintenance call, checking its own expiry/refund result first.
  const statusResult = await checkNextFiuuRefundStatus();
  const result = statusResult ?? await submitNextFiuuRefund();
  return {
    stale_refund_submissions: staleSubmissions,
    refund_action: result,
  };
}

type BillCancellationClaim = {
  hold_id: string | null;
  bill_id: string | null;
  cancellation_claim_token: string | null;
  claim_acquired?: boolean;
  already_cancelled?: boolean;
  resulting_status?: string;
};

const BILL_BINDING_COLUMNS =
  "public_token,booking_group_token,guest_index,outlet_id,billplz_bill_id,status,expires_at";

async function bookingBillBinding(token: string): Promise<BookingBillBinding | null> {
  const groupResult = await supabase
    .from("booking_holds")
    .select(BILL_BINDING_COLUMNS)
    .eq("booking_group_token", token)
    .order("guest_index", { ascending: true })
    .limit(1);
  if (groupResult.error) throw groupResult.error;
  if (groupResult.data?.[0]) return groupResult.data[0] as BookingBillBinding;

  const singleResult = await supabase
    .from("booking_holds")
    .select(BILL_BINDING_COLUMNS)
    .eq("public_token", token)
    .limit(1);
  if (singleResult.error) throw singleResult.error;
  return (singleResult.data?.[0] as BookingBillBinding | undefined) ?? null;
}

async function outletCodeForId(outletId: string): Promise<string> {
  const result = await supabase
    .from("outlets")
    .select("code")
    .eq("id", outletId)
    .maybeSingle();
  if (result.error) throw result.error;
  const code = String(result.data?.code ?? "").trim().toLowerCase();
  if (!code) throw new Error("Booking outlet was not found");
  return code;
}

function bookingOutletCode(binding: BookingBillBinding): Promise<string> {
  return outletCodeForId(binding.outlet_id);
}

async function billplzCredentialsForHoldId(
  holdId: string,
): Promise<BillplzCredentials> {
  const result = await supabase
    .from("booking_holds")
    .select("outlet_id")
    .eq("id", holdId)
    .maybeSingle();
  if (result.error) throw result.error;
  const outletId = String(result.data?.outlet_id ?? "");
  if (!outletId) throw new Error("Booking hold outlet was not found");
  return billplzCredentials(await outletCodeForId(outletId));
}

function bindingIsExpired(binding: BookingBillBinding): boolean {
  return new Date(binding.expires_at).getTime() <= Date.now();
}

async function closeBookingHold(
  token: string,
  status: "cancelled" | "expired",
): Promise<void> {
  const rows = await rpc("claim_booking_bill_cancellation", {
    p_token: token,
    p_target_status: status,
  }) as BillCancellationClaim[];
  const claim = rows[0];
  if (!claim) throw new Error("Booking reference not found");
  if (!claim.bill_id || claim.already_cancelled) return;
  if (
    !claim.claim_acquired ||
    !claim.hold_id ||
    !claim.cancellation_claim_token
  ) {
    // Another cleanup worker owns the short claim lease. It will either finish
    // or release the claim for retry; never issue a duplicate external delete.
    return;
  }

  try {
    const credentials = await billplzCredentialsForHoldId(claim.hold_id);
    await deleteBillplzBill(claim.bill_id, credentials);
    const completed = await rpcScalar<boolean>("complete_billplz_cancellation", {
      p_hold_id: claim.hold_id,
      p_claim_token: claim.cancellation_claim_token,
    });
    if (completed !== true) {
      throw new Error("Billplz cancellation claim was no longer current");
    }
  } catch (error) {
    await rpcScalar<boolean>("fail_billplz_cancellation", {
      p_hold_id: claim.hold_id,
      p_claim_token: claim.cancellation_claim_token,
      p_error: errorMessage(error),
    }).catch((recordError) => {
      console.error(
        "Unable to record Billplz cancellation failure",
        claim.bill_id,
        errorMessage(recordError),
      );
    });
    throw error;
  }
}

async function claimBillplzBill(
  binding: BookingBillBinding,
  billId: string,
  credentials: BillplzCredentials,
): Promise<string> {
  let winner: string | null;
  try {
    winner = await rpcScalar<string>("claim_billplz_bill_v2", {
      p_token: binding.booking_group_token ?? binding.public_token,
      p_bill_id: billId,
    });
  } catch (error) {
    await deleteBillplzBill(billId, credentials).catch((deleteError) => {
      console.error(
        "Unable to delete unclaimed Billplz bill",
        billId,
        errorMessage(deleteError),
      );
    });
    throw error;
  }
  if (!winner) {
    await deleteBillplzBill(billId, credentials);
    throw new Error("This booking hold can no longer accept payment");
  }
  if (winner !== billId) await deleteBillplzBill(billId, credentials);
  return winner;
}

async function cleanupExpiredPaymentHolds(): Promise<{
  deleted_bills: number;
  expired_holds: number;
  failures: number;
}> {
  const claims = await rpc("claim_expired_billplz_cancellations", {
    p_limit: 100,
  }) as BillCancellationClaim[];

  let deletedBills = 0;
  let failures = 0;
  for (const claim of claims) {
    if (
      !claim.hold_id ||
      !claim.bill_id ||
      !claim.cancellation_claim_token
    ) continue;
    try {
      const credentials = await billplzCredentialsForHoldId(claim.hold_id);
      await deleteBillplzBill(claim.bill_id, credentials);
      const completed = await rpcScalar<boolean>("complete_billplz_cancellation", {
        p_hold_id: claim.hold_id,
        p_claim_token: claim.cancellation_claim_token,
      });
      if (completed !== true) {
        throw new Error("Billplz cancellation claim was no longer current");
      }
      deletedBills += 1;
    } catch (error) {
      failures += 1;
      await rpcScalar<boolean>("fail_billplz_cancellation", {
        p_hold_id: claim.hold_id,
        p_claim_token: claim.cancellation_claim_token,
        p_error: errorMessage(error),
      }).catch((recordError) => {
        console.error(
          "Unable to record Billplz cancellation failure",
          claim.bill_id,
          errorMessage(recordError),
        );
      });
      console.error(
        "Unable to cancel expired Billplz bill",
        claim.bill_id,
        errorMessage(error),
      );
    }
  }

  return {
    deleted_bills: deletedBills,
    expired_holds: claims.length,
    failures,
  };
}

async function route(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const path = pathOf(request);
  if (request.method === "GET" && path === "/health") {
    const fiuuEnvironmentForResponse = BOOKING_PAYMENT_GATEWAY === "fiuu"
      ? fiuuEnvironmentForHealth()
      : null;
    return json(request, {
      ok: true,
      payment_enabled: BOOKING_PAYMENT_GATEWAY === "fiuu"
        ? fiuuConfigurationConfigured()
        : BILLPLZ_CONFIGURED,
      payment_gateway: BOOKING_PAYMENT_GATEWAY,
      payment_environment: fiuuEnvironmentForResponse,
      payment_collection_mode: BILLPLZ_OUTLET_COLLECTION_MODE
        ? "per_organization"
        : "legacy_single",
      payment_outlets_configured: BILLPLZ_OUTLET_COLLECTION_MODE
        ? [
          ...(billplzOutletConfigured("taman-wahyu") ? ["taman-wahyu"] : []),
          ...(billplzOutletConfigured("pv128") ? ["pv128"] : []),
        ]
        : [],
      payment_cleanup_enabled: Boolean(BOOKING_CLEANUP_SECRET),
      fiuu_refund_reconciliation_enabled:
        BOOKING_PAYMENT_GATEWAY === "fiuu" && Boolean(BOOKING_CLEANUP_SECRET),
      auto_confirm: AUTO_CONFIRM,
    });
  }
  if (request.method === "POST" && path === "/maintenance/expire-payment-holds") {
    if (!BOOKING_CLEANUP_SECRET) {
      return fail(request, "Payment cleanup is not configured", 503);
    }
    const supplied = request.headers.get("x-booking-cleanup-secret") ?? "";
    if (!timingSafeEqual(supplied, BOOKING_CLEANUP_SECRET)) {
      return fail(request, "Forbidden", 403);
    }
    if (BOOKING_PAYMENT_GATEWAY === "fiuu") {
      return json(request, { ok: true, ...(await maintainFiuuRefunds()) });
    }
    return json(request, { ok: true, ...(await cleanupExpiredPaymentHolds()) });
  }
  const rateLimitResponse = await enforceIpRateLimit(request, path);
  if (rateLimitResponse) return rateLimitResponse;
  if (request.method === "POST" && path === "/fiuu/return") {
    return handleFiuuNotification(request, "return");
  }
  if (request.method === "POST" && path === "/fiuu/notification") {
    return handleFiuuNotification(request, "notification");
  }
  if (request.method === "POST" && path === "/fiuu/callback") {
    return handleFiuuNotification(request, "callback");
  }
  if (request.method === "GET" && path === "/outlets") {
    return json(request, { outlets: await publicBookingOutlets() });
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
  if (request.method === "POST" && path === "/availability/group-dates") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const allocations = groupAllocations(body?.allocations);
    if (!allocations) return fail(request, "Choose one valid treatment for every guest");
    const dateRange = await rpc("get_public_booking_group_date_range_v1", {
      p_allocations: allocations,
    }) as Array<Record<string, unknown>>;
    // Exact combined availability is checked when a date is selected. The
    // hold RPC validates it again before reserving resources.
    const dates = dateRange.map((row) => ({
      booking_date: String(row.booking_date ?? ""),
      available: true,
    }));
    return json(request, { dates });
  }
  if (request.method === "POST" && path === "/availability/group-times") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const allocations = groupAllocations(body?.allocations);
    const date = String(body?.date ?? "");
    if (!allocations || !DATE.test(date)) return fail(request, "Treatments and date are required");
    const slots = await rpc("get_public_booking_group_slot_status_v1", {
      p_allocations: allocations,
      p_date: date,
    }) as Array<Record<string, unknown>>;
    return json(request, { slots: slots.map((row) => ({
      start_at: row.start_at,
      end_at: row.end_at,
      status: row.status,
    })) });
  }
  if (request.method === "POST" && path === "/booking-groups") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || String(body.website ?? "").trim()) return fail(request, "Invalid booking request");
    const allocations = groupAllocations(body.allocations);
    const startAt = String(body.start_at ?? "").trim();
    if (!allocations || !startAt) return fail(request, "Treatments and time are required");
    const promotionCode = String(body.promotion_code ?? "").trim().slice(0, 80);
    try {
      const commonArgs = {
        p_allocations: allocations,
        p_start_at: startAt,
        p_customer_name: String(body.customer_name ?? ""),
        p_customer_phone: String(body.customer_phone ?? ""),
        p_customer_email: String(body.customer_email ?? ""),
        p_notes: String(body.notes ?? ""),
        p_request_fingerprint: await fingerprint(request),
      };
      const rows = promotionCode
        ? await rpc("create_public_booking_group_hold_with_promotion_v1", {
          ...commonArgs,
          p_promotion_code: promotionCode,
        }) as Array<Record<string, unknown>>
        : await rpc("create_public_booking_group_hold_v1", commonArgs) as Array<Record<string, unknown>>;
      const hold = rows[0];
      if (!hold) return fail(request, "Unable to reserve this group time", 500);
      const paymentRows = await rpc("get_booking_group_for_payment", {
        p_token: hold.group_token,
      }) as Array<Record<string, unknown>>;
      const payment = paymentRows[0];
      const pricing = await publicBookingPricing(String(hold.group_token));
      return json(request, { hold: {
        token: hold.group_token,
        expires_at: hold.hold_expires_at,
        total_price: Number(pricing?.final_amount ?? payment?.total_amount ?? hold.total_price),
        guest_count: Number(hold.guest_count),
        status: "pending_payment",
        pricing: publicPricingPayload(pricing),
        promotion: promotionPayload(pricing),
      } }, 201);
    } catch (error) {
      const message = errorMessage(error);
      if (isPromotionError(error)) {
        const failureCode = rpcErrorCode(error);
        const usageType = failureCode === "PROMOTION_FULLY_REDEEMED"
          ? await promotionUsageTypeForCode(promotionCode)
          : null;
        return publicPromotionFailure(request, message, 422, failureCode, usageType);
      }
      if (/no longer available|already booked|capacity/i.test(message)) {
        return fail(request, "That time can no longer fit the whole group — there may not be enough masseurs matching everyone's preference. Please pick another time.", 409);
      }
      throw error;
    }
  }
  if (request.method === "POST" && path === "/booking-holds") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || typeof body !== "object" || String(body.website ?? "").trim()) return fail(request, "Invalid booking request");
    const catalogueId = uuid(body.catalogue_id);
    const startAt = String(body.start_at ?? "").trim();
    if (!catalogueId || !startAt) return fail(request, "Treatment and time are required");
    const promotionCode = String(body.promotion_code ?? "").trim().slice(0, 80);
    try {
      const commonArgs = {
        p_catalogue_id: catalogueId, p_start_at: startAt,
        p_therapist_preference: preference(body.therapist_preference),
        p_customer_name: String(body.customer_name ?? ""), p_customer_phone: String(body.customer_phone ?? ""),
        p_customer_email: String(body.customer_email ?? ""), p_therapist_request: String(body.therapist_request ?? ""),
        p_notes: String(body.notes ?? ""), p_request_fingerprint: await fingerprint(request),
      };
      const rows = promotionCode
        ? await rpc("create_public_booking_hold_with_promotion_v1", {
          ...commonArgs,
          p_promotion_code: promotionCode,
        }) as Array<Record<string, unknown>>
        : await rpc("create_public_booking_hold_v2", commonArgs) as Array<Record<string, unknown>>;
      const hold = rows[0];
      if (!hold) return fail(request, "Unable to reserve this time", 500);
      const paymentRows = await rpc("get_booking_hold_for_payment", {
        p_token: hold.hold_token,
      }) as Array<Record<string, unknown>>;
      const payment = paymentRows[0];
      const pricing = await publicBookingPricing(String(hold.hold_token));
      return json(request, { hold: {
        token: hold.hold_token, expires_at: hold.hold_expires_at,
        total_price: Number(pricing?.final_amount ?? payment?.total_amount ?? hold.total_price),
        duration_minutes: Number(hold.duration_minutes), status: "pending_payment",
        pricing: publicPricingPayload(pricing),
        promotion: promotionPayload(pricing),
      } }, 201);
    } catch (error) {
      const message = errorMessage(error);
      if (isPromotionError(error)) {
        const failureCode = rpcErrorCode(error);
        const usageType = failureCode === "PROMOTION_FULLY_REDEEMED"
          ? await promotionUsageTypeForCode(promotionCode)
          : null;
        return publicPromotionFailure(request, message, 422, failureCode, usageType);
      }
      if (/no longer available/i.test(message)) return fail(request, "That time was just taken. Please choose another time.", 409);
      throw error;
    }
  }
  if (request.method === "POST" && path === "/booking-holds/promotion") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const token = uuid(body?.token);
    const code = String(body?.code ?? "").trim().slice(0, 80);
    if (!token) return fail(request, "A valid booking reference is required");
    if (!code) return fail(request, "Enter a promotion code first.", 422, "PROMOTION_CODE_REQUIRED");
    const tokenRateLimit = await enforceTokenRateLimit(request, token, "promotion_per_hold", 12, 600);
    if (tokenRateLimit) return tokenRateLimit;
    try {
      const rows = await rpc("reserve_public_booking_promotion", {
        p_token: token,
        p_code: code,
        p_customer_id: null,
      }) as Array<Record<string, unknown>>;
      const result = rows[0];
      if (!result?.success) {
        const failureCode = String(result?.error_code ?? "PROMOTION_INVALID");
        const usageType = failureCode === "PROMOTION_FULLY_REDEEMED"
          ? await promotionUsageTypeForCode(code)
          : null;
        return publicPromotionFailure(
          request,
          String(result?.error_message ?? "Promotion could not be applied."),
          422,
          failureCode,
          usageType,
        );
      }
      const pricing = await publicBookingPricing(token);
      return json(request, {
        promotion: promotionPayload(pricing),
        pricing: publicPricingPayload(pricing),
      });
    } catch (error) {
      if (isPromotionError(error)) {
        const failureCode = rpcErrorCode(error);
        const usageType = failureCode === "PROMOTION_FULLY_REDEEMED"
          ? await promotionUsageTypeForCode(code)
          : null;
        return publicPromotionFailure(request, errorMessage(error), 422, failureCode, usageType);
      }
      throw error;
    }
  }
  if (request.method === "POST" && path === "/booking-holds/promotion/remove") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const token = uuid(body?.token);
    if (!token) return fail(request, "A valid booking reference is required");
    const tokenRateLimit = await enforceTokenRateLimit(request, token, "promotion_per_hold", 12, 600);
    if (tokenRateLimit) return tokenRateLimit;
    const rows = await rpc("remove_public_booking_promotion", { p_token: token }) as Array<Record<string, unknown>>;
    const result = rows[0];
    if (!result?.success) {
      return publicPromotionFailure(
        request,
        String(result?.error_message ?? "Promotion could not be removed."),
        422,
        String(result?.error_code ?? "PROMOTION_INVALID"),
      );
    }
    const pricing = await publicBookingPricing(token);
    return json(request, { pricing: publicPricingPayload(pricing), promotion: null });
  }
  if (request.method === "POST" && path === "/booking-holds/pay") {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const token = uuid(body?.token);
    if (!token) return fail(request, "A valid booking reference is required");
    const tokenRateLimit = await enforceTokenRateLimit(
      request,
      token,
      "payment_per_hold",
      3,
      600,
    );
    if (tokenRateLimit) return tokenRateLimit;
    if (BOOKING_PAYMENT_GATEWAY === "fiuu") {
      return startFiuuPayment(request, token, body?.return_path);
    }
    if (BOOKING_PAYMENT_GATEWAY !== "billplz" || !BILLPLZ_CONFIGURED) {
      return fail(request, "Payment is not configured yet.", 503);
    }
    try {
      const fiuuAttempt = await supabase.from("booking_payment_attempts")
        .select("id").eq("hold_token", token).limit(1);
      if (fiuuAttempt.error) throw fiuuAttempt.error;
      if (fiuuAttempt.data?.length) {
        return fail(request, "This booking already has a different payment link.", 409);
      }
      const binding = await bookingBillBinding(token);
      if (!binding) return fail(request, "Booking reference not found", 404);
      if (bindingIsExpired(binding)) {
        await closeBookingHold(token, "expired");
        return fail(request, "This booking hold has expired. Please start again.", 409);
      }
      if (binding.status !== "pending_payment") {
        return fail(request, "This booking hold can no longer accept payment.", 409);
      }
      if (binding.billplz_bill_id) {
        return json(request, { url: billplzBillUrl(binding.billplz_bill_id), reused: true });
      }

      let rows = await rpc("get_booking_group_for_payment", { p_token: token }) as Array<Record<string, unknown>>;
      if (!rows[0]) {
        rows = await rpc("get_booking_hold_for_payment", { p_token: token }) as Array<Record<string, unknown>>;
      }
      const hold = rows[0];
      if (!hold) return fail(request, "Booking reference not found", 404);
      if (hold.status !== "pending_payment" || new Date(String(hold.expires_at)) <= new Date()) {
        return fail(request, "This booking hold has expired. Please start again.", 409);
      }

      const amountCents = Math.round(Number(hold.total_amount) * 100);
      const outletCode = await bookingOutletCode(binding);
      const credentials = billplzCredentials(outletCode);
      const callbackUrl = `${supabaseUrl}/functions/v1/booking-api/billplz/callback`;
      const billParams: Record<string, string> = {
        collection_id: credentials.collectionId,
        email: String(hold.customer_email ?? ""),
        mobile: normalizeMyPhone(String(hold.customer_phone ?? "")),
        name: String(hold.customer_name ?? ""),
        amount: String(amountCents),
        callback_url: callbackUrl,
        description: billDescription(hold),
      };
      const redirectUrl = bookingRedirectUrl(token, body?.return_path);
      if (redirectUrl) billParams.redirect_url = redirectUrl;

      const bill = await billplzRequest("/api/v3/bills", billParams, credentials);
      const billId = String(bill.id ?? "");
      const billUrl = String(bill.url ?? "");
      if (!billId || !billUrl) return fail(request, "Unable to start payment. Please try again.", 502);
      const claimedBillId = await claimBillplzBill(binding, billId, credentials);
      return json(request, {
        url: claimedBillId === billId ? billUrl : billplzBillUrl(claimedBillId),
        reused: claimedBillId !== billId,
      }, claimedBillId === billId ? 201 : 200);
    } catch (error) {
      const message = errorMessage(error);
      if (/no longer accept payment/i.test(message)) return fail(request, "This booking hold has expired. Please start again.", 409);
      if (/paid booking cannot be cancelled/i.test(message)) {
        return fail(request, "This booking has already been paid and confirmed.", 409);
      }
      if (/not found/i.test(message)) return fail(request, "Booking reference not found", 404);
      // Surface the actual Billplz/network failure instead of a generic 500 —
      // the caller sees exactly why payment couldn't start (bad credentials,
      // bad collection id, DNS/base-URL typo, etc.).
      console.error("Unable to start Billplz payment", message);
      return fail(request, `Unable to start payment: ${message}`, 502);
    }
  }
  if (
    request.method === "POST" &&
    (path === "/booking-holds/cancel" || path === "/booking-holds/expire")
  ) {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const token = uuid(body?.token);
    if (!token) return fail(request, "A valid booking reference is required");
    const binding = await bookingBillBinding(token);
    if (!binding) return fail(request, "Booking reference not found", 404);
    if (binding.status === "confirmed" || binding.status === "paid") {
      return fail(request, "This booking has already been paid and confirmed.", 409);
    }
    try {
      await closeBookingHold(
        token,
        path === "/booking-holds/cancel" ? "cancelled" : "expired",
      );
    } catch (error) {
      if (/paid booking cannot be cancelled/i.test(errorMessage(error))) {
        return fail(request, "This booking has already been paid and confirmed.", 409);
      }
      throw error;
    }
    return json(request, { ok: true });
  }
  if (request.method === "POST" && path === "/billplz/callback") {
    if (!BILLPLZ_CONFIGURED) {
      return fail(request, "Payment callback is not configured", 503);
    }
    // Billplz expects a fast 200 and posts application/x-www-form-urlencoded fields.
    const form = await request.formData().catch(() => null);
    if (!form) return fail(request, "Invalid callback payload", 400);
    const get = (key: string) => String(form.get(key) ?? "");
    const signature = get("x_signature");
    const billId = get("id");
    const collectionId = get("collection_id");
    if (!signature || !billId || !collectionId) {
      return fail(request, "Invalid callback payload", 400);
    }

    let credentials: BillplzCredentials;
    try {
      credentials = billplzCredentialsForCollection(collectionId);
    } catch (error) {
      console.error("Billplz callback used an unknown collection", collectionId, error);
      return fail(request, "Invalid callback collection", 400);
    }

    const signedString = BILLPLZ_CALLBACK_SIGNED_KEYS
      .map((key) => `${key}${get(key)}`)
      .join("|");
    const expectedSignature = await hmacSha256Hex(
      signedString,
      credentials.xSignatureKey,
    );
    if (!timingSafeEqual(expectedSignature, signature)) {
      console.error("Billplz callback signature mismatch", billId);
      return fail(request, "Invalid signature", 400);
    }

    let groupPayment = true;
    let token = await rpcScalar("get_booking_group_token_by_bill", { p_bill_id: billId });
    if (!token) {
      groupPayment = false;
      token = await rpcScalar("get_booking_hold_token_by_bill", { p_bill_id: billId });
    }
    if (!token) {
      // Unknown bill id — nothing to do, but acknowledge so Billplz doesn't retry forever.
      return json(request, { ok: true });
    }

    const paid = get("paid") === "true";
    try {
      if (paid) {
        await rpc(
          groupPayment
            ? "process_paid_public_booking_group"
            : "process_paid_public_booking_hold",
          { p_token: token, p_bill_id: billId },
        );
      } else {
        await rpc(groupPayment ? "mark_booking_group_payment_failed" : "mark_booking_hold_payment_failed", { p_token: token });
      }
    } catch (error) {
      const message = errorMessage(error);
      if (/paid callback arrived after booking hold expired/i.test(message)) {
        console.warn("Late Billplz callback was acknowledged without conversion", billId);
        return json(request, { ok: true, outcome: "late_payment" });
      }
      console.error("Billplz callback processing failed", error);
      // Ask Billplz to retry instead of silently leaving a paid booking without
      // its transaction/payment status if confirmation or payment recording fails.
      return fail(request, "Callback processing failed", 500);
    }
    return json(request, { ok: true });
  }
  if (request.method === "POST" && path === "/booking-holds/confirm") {
    return fail(request, "Route not found", 404);
  }
  if (request.method === "GET" && path === "/booking-holds/status") {
    const token = uuid(url.searchParams.get("token"));
    if (!token) return fail(request, "A valid booking reference is required");
    const tokenRateLimit = await enforceTokenRateLimit(
      request,
      token,
      "status_per_hold",
      30,
      60,
    );
    if (tokenRateLimit) return tokenRateLimit;
    const binding = await bookingBillBinding(token);
    if (!binding) return fail(request, "Booking reference not found", 404);
    if (
      bindingIsExpired(binding) &&
      binding.status !== "confirmed" &&
      binding.status !== "paid"
    ) {
      try {
        await closeBookingHold(token, "expired");
      } catch (error) {
        if (!/paid booking cannot be cancelled/i.test(errorMessage(error))) {
          throw error;
        }
      }
    }
    let groupBooking = true;
    let rows = await rpc("get_public_booking_group_status_v1", { p_token: token }) as Array<Record<string, unknown>>;
    if (!rows[0]) {
      groupBooking = false;
      rows = await rpc("get_public_booking_hold_status_v2", { p_token: token }) as Array<Record<string, unknown>>;
    }
    if (!rows[0]) return fail(request, "Booking reference not found", 404);
    const hold = rows[0];
    const paymentRows = await rpc(
      groupBooking ? "get_booking_group_for_payment" : "get_booking_hold_for_payment",
      { p_token: token },
    ) as Array<Record<string, unknown>>;
    const payment = paymentRows[0];
    const pricing = await publicBookingPricing(token);
    return json(request, { hold: {
      token: hold.token,
      status: hold.status,
      expires_at: hold.expires_at,
      total_price: Number(pricing?.final_amount ?? payment?.total_amount ?? hold.total_price),
      start_at: hold.start_at,
      end_at: hold.end_at,
      guest_count: Number(hold.guest_count ?? 1),
      pricing: publicPricingPayload(pricing),
      promotion: promotionPayload(pricing),
      // Same receipt_number staff see in the app's transaction record — null until
      // the Billplz webhook has confirmed payment and created that row.
      receipt_number: payment?.receipt_number ?? null,
    } });
  }
  return fail(request, "Not found", 404);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: responseHeaders(request) });
  try { return await route(request); }
  catch (error) {
    // Do not serialize request bodies or arbitrary database errors: public
    // promo codes must never become an accidental log field.
    console.error("Booking service request failed", operationalErrorLabel(error));
    return fail(request, "The booking service is temporarily unavailable", 500);
  }
});
