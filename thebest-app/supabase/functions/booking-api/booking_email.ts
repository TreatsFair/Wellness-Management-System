const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export const BOOKING_EMAIL_LOGO_URL =
  "https://thebestwellness.my/pics/email-logo.png";
export const BOOKING_EMAIL_STAGING_LOGO_URL =
  "https://tbwtest.netlify.app/pics/email-logo.png?v=20260919-white-logo";
export const BOOKING_EMAIL_TERMS_URL =
  "https://thebestwellness.my/terms.html";
export const BOOKING_EMAIL_CONTACT_EMAIL = "thebestwellness@yahoo.com";
export const BOOKING_EMAIL_SUPPORT_PHONE = "012-287 2238";
export const BOOKING_EMAIL_WHATSAPP_URL = "https://wa.me/60122872238";

export type BookingEmailEnvironment = "sandbox" | "live";

export type BookingEmailSettings = {
  environment: BookingEmailEnvironment;
  enabled: boolean;
  resendApiKey: string;
  from: string;
  replyTo: string;
  testRecipient: string;
};

export type BookingConfirmationEmailPayload = {
  customerName: string;
  customerEmail: string;
  customerPhone: string;
  customerNotes: string;
  bookingReference: string;
  outletName: string;
  serviceLines: string[];
  appointmentDate: string;
  appointmentTime: string;
  guestCount: number;
  serviceTotal: string;
  promotionCode: string;
  promotionDiscount: string;
  amount: string;
  paymentMethod: string;
  logoUrl: string;
  termsUrl: string;
  contactEmail: string;
};

export type RenderedBookingEmail = {
  subject: string;
  html: string;
  text: string;
};

export type ResendEmailResult = { id: string };

export const EXPECTED_STAGING_BOOKING_EMAIL_FROM =
  "The Best Family Wellness <bookings@thebestwellness.my>";

export type ResendRequestDiagnostics = {
  from: string;
  fromExists: boolean;
  fromMatchesExpectedStagingValue: boolean;
  fromHasSurroundingLiteralQuotes: boolean;
  fromHasLineBreak: boolean;
  replyToField: "reply_to" | "omitted";
  replyToValid: boolean;
  testRecipientValid: boolean;
  recipient: string;
  subject: string;
  htmlPresent: boolean;
  textPresent: boolean;
  idempotencyKeyLength: number;
  authorizationScheme: "Bearer" | "missing";
};

export type ResendErrorDetails = {
  name: string | null;
  code: string | null;
  message: string | null;
};

export class BookingEmailDeliveryError extends Error {
  constructor(
    message: string,
    options: {
      retryable: boolean;
      retryAfterSeconds?: number | null;
      status?: number | null;
    },
  ) {
    super(message);
    this.name = "BookingEmailDeliveryError";
    this.retryable = options.retryable;
    this.retryAfterSeconds = options.retryAfterSeconds ?? null;
    this.status = options.status ?? null;
  }

  readonly retryable: boolean;
  readonly retryAfterSeconds: number | null;
  readonly status: number | null;
}

type EnvironmentReader = (name: string) => string | undefined;

function defaultEnvironmentReader(name: string): string | undefined {
  return Deno.env.get(name);
}

function trim(value: string | undefined): string {
  return (value ?? "").trim();
}

export function isBookingEmailAddress(value: string): boolean {
  return EMAIL_PATTERN.test(value.trim());
}

function maskEmail(value: string): string {
  const trimmed = value.trim();
  const at = trimmed.lastIndexOf("@");
  if (at <= 0 || at === trimmed.length - 1) return "[invalid recipient]";
  return `${trimmed.slice(0, 1)}***@${trimmed.slice(at + 1).toLowerCase()}`;
}

function sanitizeProviderMessage(value: unknown): string | null {
  const message = String(value ?? "")
    .replace(/\bre_[A-Za-z0-9_-]+\b/g, "[redacted-api-key]")
    .replace(/[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})/gi, "***@$1")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return message ? message.slice(0, 500) : null;
}

function safeProviderToken(value: unknown): string | null {
  const token = String(value ?? "").trim();
  if (!token) return null;
  return token.replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 80) || null;
}

export function parseResendErrorBody(value: string): ResendErrorDetails {
  let body: unknown = null;
  try {
    body = JSON.parse(value);
  } catch {
    return { name: null, code: null, message: sanitizeProviderMessage(value) };
  }
  const record = body && typeof body === "object"
    ? body as Record<string, unknown>
    : null;
  const nested = record?.error && typeof record.error === "object"
    ? record.error as Record<string, unknown>
    : null;
  return {
    name: safeProviderToken(record?.name ?? nested?.name),
    code: safeProviderToken(record?.code ?? nested?.code),
    message: sanitizeProviderMessage(record?.message ?? nested?.message),
  };
}

export function resendRequestDiagnostics(
  settings: BookingEmailSettings,
  payload: BookingConfirmationEmailPayload,
  recipient: string,
  idempotencyKey: string,
): ResendRequestDiagnostics {
  const rendered = renderBookingConfirmationEmail(payload);
  const from = settings.from;
  const first = from.charAt(0);
  const last = from.charAt(from.length - 1);
  return {
    from,
    fromExists: Boolean(from),
    fromMatchesExpectedStagingValue:
      settings.environment !== "sandbox" ||
      from === EXPECTED_STAGING_BOOKING_EMAIL_FROM,
    fromHasSurroundingLiteralQuotes:
      (first === '"' && last === '"') || (first === "'" && last === "'"),
    fromHasLineBreak: /[\r\n]/.test(from),
    replyToField: settings.replyTo ? "reply_to" : "omitted",
    replyToValid: !settings.replyTo || isBookingEmailAddress(settings.replyTo),
    testRecipientValid:
      settings.environment !== "sandbox" ||
      isBookingEmailAddress(settings.testRecipient),
    recipient: maskEmail(recipient),
    subject: rendered.subject,
    htmlPresent: Boolean(rendered.html),
    textPresent: Boolean(rendered.text),
    idempotencyKeyLength: idempotencyKey.length,
    authorizationScheme: settings.resendApiKey ? "Bearer" : "missing",
  };
}

export function bookingEmailSettings(
  environment: BookingEmailEnvironment,
  readEnvironment: EnvironmentReader = defaultEnvironmentReader,
): BookingEmailSettings {
  return {
    environment,
    enabled: trim(readEnvironment("BOOKING_EMAIL_ENABLED")).toLowerCase() === "true",
    resendApiKey: trim(readEnvironment("RESEND_API_KEY")),
    from: trim(readEnvironment("BOOKING_EMAIL_FROM")),
    replyTo: trim(readEnvironment("BOOKING_EMAIL_REPLY_TO")),
    testRecipient: trim(readEnvironment("BOOKING_EMAIL_TEST_RECIPIENT")),
  };
}

export function bookingEmailRecipient(
  settings: BookingEmailSettings,
  customerEmail: string,
): string | null {
  const recipient = settings.environment === "sandbox"
    ? settings.testRecipient
    : customerEmail;
  return isBookingEmailAddress(recipient) ? recipient.trim() : null;
}

export function bookingEmailConfigurationIssue(
  settings: BookingEmailSettings,
  customerEmail: string,
): string | null {
  if (!settings.enabled) return null;
  if (!settings.resendApiKey) return "Resend is not configured";
  if (!settings.from) return "Booking email sender is not configured";
  if (settings.replyTo && !isBookingEmailAddress(settings.replyTo)) {
    return "Booking email reply address is invalid";
  }
  if (
    settings.environment === "sandbox" &&
    !isBookingEmailAddress(settings.testRecipient)
  ) {
    return "Booking email test recipient is not configured";
  }
  if (!bookingEmailRecipient(settings, customerEmail)) {
    return settings.environment === "sandbox"
      ? "Booking email test recipient is invalid"
      : "Customer email is missing or invalid";
  }
  return null;
}

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function bookingEmailPaymentMethod(channel: string): string {
  const value = channel.trim().toLowerCase();
  if (value.includes("tng") || value.includes("touch")) return "Touch 'n Go eWallet";
  if (value.includes("duit") || value.includes("rpp")) return "DuitNow QR";
  if (value.includes("grab")) return "GrabPay";
  if (value.includes("shopee")) return "ShopeePay";
  if (
    value === "credit" || value.includes("card") || value.includes("visa") ||
    value.includes("master")
  ) {
    return "Card payment";
  }
  if (value.includes("fpx") || value.includes("online")) return "Online banking";
  return "Online payment";
}

export function bookingEmailDisplayReference(orderId: string): string {
  const reference = orderId.trim();
  return reference || "Not available";
}

export function bookingEmailLogoUrl(
  environment: BookingEmailEnvironment,
): string {
  return environment === "sandbox"
    ? BOOKING_EMAIL_STAGING_LOGO_URL
    : BOOKING_EMAIL_LOGO_URL;
}

function serviceRows(payload: BookingConfirmationEmailPayload): string {
  const lines = payload.serviceLines.length > 0
    ? payload.serviceLines
    : ["Booked wellness service"];
  return lines.map((line, index) => `
    <tr>
      <td style="padding:${index === 0 ? "0" : "10px 0 0"};vertical-align:top;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;">
          <tr>
            <td width="30" valign="top" style="width:30px;padding:0 8px 0 0;vertical-align:top;">
              <span style="display:block;width:22px;height:22px;line-height:22px;text-align:center;border-radius:11px;background:#f2e4d4;color:#7d4b25;font-size:12px;font-weight:700;">${index + 1}</span>
            </td>
            <td valign="top" style="padding:1px 0 0;color:#4f4541;font-size:14px;line-height:1.55;vertical-align:top;word-break:normal;overflow-wrap:anywhere;">${escapeHtml(line)}</td>
          </tr>
        </table>
      </td>
    </tr>`).join("");
}

function serviceText(payload: BookingConfirmationEmailPayload): string {
  const lines = payload.serviceLines.length > 0
    ? payload.serviceLines
    : ["Booked wellness service"];
  return lines.map((line) => `- ${line}`).join("\n");
}

function detailRow(label: string, value: string, strong = false): string {
  return `<tr>
    <th scope="row" width="118" align="left" style="width:118px;padding:7px 12px 7px 0;color:#7c6d66;font-weight:600;vertical-align:top;">${escapeHtml(label)}</th>
    <td style="padding:7px 0;color:#4f4541;vertical-align:top;word-break:break-word;${strong ? "font-weight:700;" : ""}">${escapeHtml(value)}</td>
  </tr>`;
}

function optionalDetailRow(label: string, value: string): string {
  const trimmed = value.trim();
  return trimmed ? detailRow(label, trimmed) : "";
}

function paymentSummaryRow(
  label: string,
  value: string,
  strong = false,
): string {
  return `<tr>
    <td style="padding:6px 0;color:#625652;font-size:13px;vertical-align:top;">${escapeHtml(label)}</td>
    <td align="right" style="padding:6px 0;color:#2b211e;font-size:13px;vertical-align:top;white-space:nowrap;${strong ? "font-weight:700;" : ""}">${escapeHtml(value)}</td>
  </tr>`;
}

export function maskedBookingPhone(value: string): string {
  const digits = value.replace(/\D/g, "");
  if (!digits) return "";
  const visible = digits.slice(-4);
  return `60****${visible}`;
}

export function renderBookingConfirmationEmail(
  payload: BookingConfirmationEmailPayload,
): RenderedBookingEmail {
  const guestLine = payload.guestCount > 1
    ? detailRow("Guests", String(payload.guestCount))
    : "";
  const guestText = payload.guestCount > 1
    ? `Guests: ${payload.guestCount}\n`
    : "";
  const safeLogoUrl = escapeHtml(payload.logoUrl);
  const safeTermsUrl = escapeHtml(payload.termsUrl);
  const safeContactEmail = escapeHtml(payload.contactEmail);
  const safeWhatsAppUrl = escapeHtml(BOOKING_EMAIL_WHATSAPP_URL);
  const safeSupportPhone = escapeHtml(BOOKING_EMAIL_SUPPORT_PHONE);
  const maskedPhone = maskedBookingPhone(payload.customerPhone);
  const customerPhoneRow = optionalDetailRow("Phone", maskedPhone);
  const customerNotesRow = optionalDetailRow("Notes", payload.customerNotes);
  const promotionRow = payload.promotionDiscount
    ? paymentSummaryRow("Promotion", payload.promotionDiscount)
    : "";
  const promotionCodeHtml = payload.promotionCode
    ? `<p style="margin:8px 0 0;color:#756660;font-size:12px;line-height:1.5;">Promotion code: <strong>${escapeHtml(payload.promotionCode)}</strong></p>`
    : "";
  const promotionText = payload.promotionDiscount
    ? `Promotion: ${payload.promotionDiscount}\n`
    : "";
  const promotionCodeText = payload.promotionCode
    ? `Promotion code: ${payload.promotionCode}\n`
    : "";

  return {
    subject: "Your booking is confirmed — The Best Family Wellness",
    html: `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light only">
    <meta name="supported-color-schemes" content="light only">
    <title>Booking confirmed</title>
    <style>
      :root { color-scheme: light only; supported-color-schemes: light only; }
      .brand-header { background-color:#4f2d25 !important; background-image:linear-gradient(#4f2d25,#4f2d25) !important; }
      .email-logo { width:225px !important; max-width:225px !important; height:auto !important; }
      .email-footer { font-size:13px !important; line-height:1.6 !important; }
      .email-footer-title { font-size:14px !important; }
      .email-footer-note { font-size:12px !important; line-height:1.6 !important; }
      .contact-address, .contact-address a, a[x-apple-data-detectors] { color:#756660 !important; text-decoration:none !important; border-bottom:0 !important; }
      @media (prefers-color-scheme: dark) {
        .brand-header { background-color:#4f2d25 !important; background-image:linear-gradient(#4f2d25,#4f2d25) !important; }
      }
      @media only screen and (max-width:480px) {
        .email-logo { width:160px !important; max-width:160px !important; }
        .email-wrapper { padding:18px 8px !important; }
        .email-content { padding-left:18px !important; padding-right:18px !important; }
        .email-heading { font-size:22px !important; }
        .email-intro { font-size:14px !important; }
        .email-section-title { font-size:14px !important; }
        .email-detail-table th, .email-detail-table td,
        .email-payment-table td { font-size:12px !important; line-height:1.4 !important; }
        .email-service-list td { font-size:12px !important; line-height:1.45 !important; }
        .email-footer { font-size:11px !important; line-height:1.5 !important; }
        .email-footer-title { font-size:12px !important; }
        .email-footer-note { font-size:10px !important; line-height:1.5 !important; }
      }
    </style>
  </head>
  <body bgcolor="#f8f3ec" style="margin:0;background:#f8f3ec;color:#2b211e;font-family:Arial,Helvetica,sans-serif;">
    <div style="display:none;max-height:0;overflow:hidden;opacity:0;">
      Your appointment with The Best Family Wellness is confirmed.
    </div>
    <table class="email-wrapper" role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#f8f3ec" style="background:#f8f3ec;padding:22px 10px;">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="max-width:660px;background:#ffffff;border:1px solid #eadfd2;border-radius:18px;overflow:hidden;">
          <tr><td class="brand-header email-content" bgcolor="#4f2d25" style="padding:12px 20px;text-align:center;background-color:#4f2d25;background-image:linear-gradient(#4f2d25,#4f2d25);">
            <a href="https://thebestwellness.my/" target="_blank" style="display:inline-block;border:0;outline:none;text-decoration:none;">
              <img class="email-logo" src="${safeLogoUrl}" width="225" alt="The Best Family Wellness" style="display:block;width:225px;max-width:225px;height:auto;border:0;outline:none;text-decoration:none;">
            </a>
          </td></tr>
          <tr><td class="email-content" style="padding:24px 24px 8px;">
            <p style="margin:0 0 7px;color:#a66b24;font-size:11px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;">Booking confirmed</p>
            <h1 class="email-heading" style="margin:0;color:#2b211e;font-size:25px;line-height:1.2;">Thank you for your booking.</h1>
            <p class="email-intro" style="margin:12px 0 0;color:#625652;font-size:15px;line-height:1.5;">Your appointment has been confirmed and paid successfully.</p>
          </td></tr>
          <tr><td class="email-content" style="padding:14px 24px 6px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;background:#fbf8f4;border:1px solid #eadfd2;border-radius:12px;">
              <tr><td style="padding:15px 15px 6px;">
                <h2 class="email-section-title" style="margin:0 0 10px;font-size:15px;color:#2b211e;">Appointment details</h2>
                <table class="email-detail-table" role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;color:#4f4541;font-size:13px;line-height:1.45;">
                  ${detailRow("Reference", payload.bookingReference)}
                  ${detailRow("Outlet", payload.outletName)}
                  ${detailRow("Date", payload.appointmentDate)}
                  ${detailRow("Time", payload.appointmentTime)}
                  ${guestLine}
                </table>
              </td></tr>
              <tr><td style="padding:6px 15px 15px;">
                <h3 class="email-section-title" style="margin:0 0 8px;font-size:13px;color:#2b211e;">Services booked</h3>
                <table class="email-service-list" role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">${serviceRows(payload)}</table>
              </td></tr>
            </table>
          </td></tr>
          <tr><td class="email-content" style="padding:10px 24px 6px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;background:#ffffff;border:1px solid #eadfd2;border-radius:12px;">
              <tr><td style="padding:15px;">
                <h2 class="email-section-title" style="margin:0 0 8px;font-size:15px;color:#2b211e;">Payment summary</h2>
                <table class="email-payment-table" role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
                  ${paymentSummaryRow("Service total", payload.serviceTotal)}
                  ${promotionRow}
                  <tr><td colspan="2" style="padding:4px 0 2px;"><div style="border-top:1px solid #d8cbc0;"></div></td></tr>
                  ${paymentSummaryRow("Total paid", payload.amount, true)}
                </table>
                <p style="margin:8px 0 0;color:#756660;font-size:12px;line-height:1.5;">Inclusive of applicable SST</p>
                ${promotionCodeHtml}
                <table class="email-payment-table" role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:10px;border-collapse:collapse;">
                  ${paymentSummaryRow("Payment method", payload.paymentMethod)}
                  ${paymentSummaryRow("Payment status", "Paid")}
                </table>
              </td></tr>
            </table>
          </td></tr>
          <tr><td class="email-content" style="padding:10px 24px 6px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;background:#ffffff;border:1px solid #eadfd2;border-radius:12px;color:#4f4541;font-size:14px;line-height:1.5;">
              <tr><td style="padding:15px;">
                <h2 class="email-section-title" style="margin:0 0 8px;font-size:15px;color:#2b211e;">Customer details</h2>
                <table class="email-detail-table" role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;color:#4f4541;font-size:13px;line-height:1.45;">
                  ${detailRow("Name", payload.customerName || "Customer")}
                  ${customerPhoneRow}
                  ${detailRow("Email", payload.customerEmail)}
                  ${customerNotesRow}
                </table>
              </td></tr>
            </table>
          </td></tr>
          <tr><td class="email-content" style="padding:12px 24px 6px;">
            <p style="margin:0;color:#4f4541;font-size:13px;line-height:1.5;"><strong>Arrival reminder:</strong> Please arrive about 10 minutes before your appointment.</p>
          </td></tr>
          <tr><td class="email-footer email-content" style="padding:16px 24px 22px;color:#756660;font-size:11px;line-height:1.55;">
            <p class="email-footer-title" style="margin:0 0 7px;color:#4f4541;font-size:12px;font-weight:700;">Contact Information</p>
            <p style="margin:0;"><strong>Company Name:</strong> The Best Wellness Sdn. Bhd. (202401019413)</p>
            <p class="contact-address" style="margin:4px 0 0;color:#756660;text-decoration:none;"><strong>Address:</strong> <span style="color:#756660;text-decoration:none;">50G, Jalan Seri Utara 1, Taman Wahyu, 68100 Kuala Lumpur, Wilayah Persekutuan Kuala Lumpur, Malaysia</span></p>
            <p style="margin:4px 0 0;"><strong>Contact Number:</strong> <a href="${safeWhatsAppUrl}" style="color:#7d4b25;">${safeSupportPhone}</a></p>
            <p style="margin:4px 0 0;">For any enquiries, email us at <a href="mailto:${safeContactEmail}" style="color:#7d4b25;font-weight:700;">${safeContactEmail}</a>.</p>
            <p style="margin:14px 0 0;">Please keep this email for your records. Booking changes and refund requests are subject to our <a href="${safeTermsUrl}" style="color:#7d4b25;">Booking Terms &amp; Conditions</a>.</p>
            <div class="email-footer-note" style="margin-top:14px;padding-top:12px;border-top:1px solid #eadfd2;color:#978780;font-size:11px;line-height:1.55;">Not your booking? Please ignore this email.</div>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`,
    text: `Booking confirmed — The Best Family Wellness

Thank you for your booking. Your appointment has been confirmed and paid successfully.

Reference: ${payload.bookingReference}
Outlet: ${payload.outletName}
Date: ${payload.appointmentDate}
Time: ${payload.appointmentTime}
${guestText}

Services:
${serviceText(payload)}

Payment summary:
Service total: ${payload.serviceTotal}
${promotionText}Total paid: ${payload.amount}
Inclusive of applicable SST
${promotionCodeText}Payment method: ${payload.paymentMethod}
Payment status: Paid

Customer details:
Name: ${payload.customerName || "Customer"}
Phone: ${maskedPhone || "Not provided"}
Email: ${payload.customerEmail}
${payload.customerNotes.trim() ? `Notes: ${payload.customerNotes.trim()}\n` : ""}

Arrival reminder: Please arrive about 10 minutes before your appointment.

Contact Information
Company Name: The Best Wellness Sdn. Bhd. (202401019413)
Address: 50G, Jalan Seri Utara 1, Taman Wahyu, 68100 Kuala Lumpur, Wilayah Persekutuan Kuala Lumpur, Malaysia
Contact Number: ${BOOKING_EMAIL_SUPPORT_PHONE} (${BOOKING_EMAIL_WHATSAPP_URL})
For any enquiries, email us at ${payload.contactEmail}.

Please keep this email for your records. Booking changes and refund requests are subject to our Booking Terms & Conditions: ${payload.termsUrl}

Not your booking? Please ignore this email.`,
  };
}

export function parseRetryAfter(value: string | null, now = Date.now()): number | null {
  if (!value) return null;
  const seconds = Number(value.trim());
  if (Number.isFinite(seconds) && seconds >= 0) return Math.ceil(seconds);
  const date = Date.parse(value);
  if (!Number.isFinite(date)) return null;
  return Math.max(0, Math.ceil((date - now) / 1000));
}

export function automaticRetryDelaySeconds(
  attemptCount: number,
  retryAfterSeconds: number | null = null,
): number {
  const boundedAttempt = Math.max(1, Math.min(Math.floor(attemptCount), 6));
  const exponential = Math.min(30 * 60, 60 * 2 ** (boundedAttempt - 1));
  if (retryAfterSeconds == null || !Number.isFinite(retryAfterSeconds)) {
    return exponential;
  }
  // Retry-After is a provider lower bound, not a value to cap. Waiting longer
  // than our bounded exponential schedule is required when Resend asks us to.
  return Math.max(exponential, Math.max(0, Math.ceil(retryAfterSeconds)));
}

export async function sendBookingConfirmationEmail(
  payload: BookingConfirmationEmailPayload,
  settings: BookingEmailSettings,
  idempotencyKey: string,
  fetcher: typeof fetch = fetch,
): Promise<ResendEmailResult> {
  if (!settings.enabled) {
    throw new BookingEmailDeliveryError("Booking email delivery is disabled", {
      retryable: false,
    });
  }
  const issue = bookingEmailConfigurationIssue(settings, payload.customerEmail);
  if (issue) {
    throw new BookingEmailDeliveryError(issue, { retryable: false });
  }
  const recipient = bookingEmailRecipient(settings, payload.customerEmail);
  if (!recipient) {
    throw new BookingEmailDeliveryError("Email recipient is missing", { retryable: false });
  }
  const rendered = renderBookingConfirmationEmail(payload);
  const requestBody = {
    from: settings.from,
    to: [recipient],
    ...(settings.replyTo ? { reply_to: settings.replyTo } : {}),
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
  };
  const diagnostics = resendRequestDiagnostics(
    settings,
    payload,
    recipient,
    idempotencyKey,
  );
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    let response: Response;
    try {
      response = await fetcher("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${settings.resendApiKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": idempotencyKey,
        },
        body: JSON.stringify(requestBody),
        signal: controller.signal,
      });
    } catch (error) {
      const message = error instanceof DOMException && error.name === "AbortError"
        ? "Resend request timed out"
        : "Resend request could not be completed";
      throw new BookingEmailDeliveryError(message, { retryable: true });
    }

    if (!response.ok) {
      const retryAfter = parseRetryAfter(response.headers.get("retry-after"));
      const retryable = response.status === 429 || response.status >= 500;
      const details = parseResendErrorBody(await response.text());
      const providerParts = [
        details.name ? `name=${details.name}` : "",
        details.code ? `code=${details.code}` : "",
        details.message ? `message=${details.message}` : "",
      ].filter(Boolean).join(", ");
      throw new BookingEmailDeliveryError(
        `Resend rejected the email (HTTP ${response.status}${
          providerParts ? `; ${providerParts}` : ""
        }); request=${JSON.stringify(diagnostics)}`,
        { retryable, retryAfterSeconds: retryAfter, status: response.status },
      );
    }
    const body = await response.json().catch(() => null) as Record<string, unknown> | null;
    const id = typeof body?.id === "string" ? body.id.trim() : "";
    if (!id) {
      throw new BookingEmailDeliveryError("Resend returned no email id", { retryable: true });
    }
    return { id };
  } finally {
    clearTimeout(timeout);
  }
}
