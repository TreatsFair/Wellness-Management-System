import {
  automaticRetryDelaySeconds,
  bookingEmailConfigurationIssue,
  bookingEmailDisplayReference,
  bookingEmailPaymentMethod,
  bookingEmailRecipient,
  bookingEmailSettings,
  BookingEmailDeliveryError,
  escapeHtml,
  EXPECTED_STAGING_BOOKING_EMAIL_FROM,
  maskedBookingPhone,
  parseRetryAfter,
  parseResendErrorBody,
  renderBookingConfirmationEmail,
  resendRequestDiagnostics,
  sendBookingConfirmationEmail,
  type BookingConfirmationEmailPayload,
} from "./booking_email.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const payload: BookingConfirmationEmailPayload = {
  customerName: "A <Customer>",
  customerEmail: "customer@example.com",
  customerPhone: "60123456789",
  customerNotes: "Use side entrance <please>",
  bookingReference: "FIUU-W123",
  outletName: "Taman Wahyu",
  serviceLines: ["Foot massage 60 min"],
  appointmentDate: "17 Sep 2026",
  appointmentTime: "11:00 am",
  guestCount: 1,
  serviceTotal: "RM 1.20",
  promotionCode: "",
  promotionDiscount: "",
  amount: "RM 1.20",
  paymentMethod: "Touch 'n Go eWallet",
  logoUrl: "https://thebestwellness.my/pics/email-logo.png",
  termsUrl: "https://thebestwellness.my/terms.html",
  contactEmail: "thebestwellness@yahoo.com",
};

function reader(values: Record<string, string>): (name: string) => string | undefined {
  return (name) => values[name];
}

Deno.test("staging booking email uses the configured test recipient", () => {
  const settings = bookingEmailSettings("sandbox", reader({
    BOOKING_EMAIL_ENABLED: "true",
    RESEND_API_KEY: "re_test",
    BOOKING_EMAIL_FROM: "The Best Wellness <bookings@example.com>",
    BOOKING_EMAIL_TEST_RECIPIENT: "qa@example.com",
  }));
  assert(bookingEmailRecipient(settings, payload.customerEmail) === "qa@example.com", "staging recipient was not overridden");
  assert(bookingEmailConfigurationIssue(settings, payload.customerEmail) === null, "valid staging email configuration was rejected");
});

Deno.test("staging booking email fails closed without a test recipient", () => {
  const settings = bookingEmailSettings("sandbox", reader({
    BOOKING_EMAIL_ENABLED: "true",
    RESEND_API_KEY: "re_test",
    BOOKING_EMAIL_FROM: "The Best Wellness <bookings@example.com>",
  }));
  assert(bookingEmailRecipient(settings, payload.customerEmail) === null, "staging fell back to the customer recipient");
  assert(
    bookingEmailConfigurationIssue(settings, payload.customerEmail) ===
      "Booking email test recipient is not configured",
    "missing staging test recipient did not fail closed",
  );
});

Deno.test("live booking email keeps the customer recipient", () => {
  const settings = bookingEmailSettings("live", reader({
    BOOKING_EMAIL_ENABLED: "true",
    RESEND_API_KEY: "re_live",
    BOOKING_EMAIL_FROM: "The Best Wellness <bookings@example.com>",
  }));
  assert(bookingEmailRecipient(settings, payload.customerEmail) === payload.customerEmail, "live recipient was replaced");
  assert(bookingEmailRecipient(settings, "not-an-email") === null, "invalid live recipient was accepted");
});

Deno.test("booking confirmation HTML escapes customer-controlled text", () => {
  const rendered = renderBookingConfirmationEmail(payload);
  assert(rendered.subject.includes("The Best Family Wellness"), "subject is not branded");
  assert(rendered.html.includes("A &lt;Customer&gt;"), "customer name was not escaped");
  assert(!rendered.html.includes("A <Customer>"), "raw customer markup leaked into HTML");
  assert(rendered.html.includes(payload.logoUrl), "logo URL is missing");
  assert(rendered.html.includes(payload.termsUrl), "terms URL is missing");
  assert(rendered.html.includes("60****6789"), "customer phone was not masked with Malaysia code and final four digits");
  assert(!rendered.html.includes(payload.customerPhone), "full customer phone leaked into HTML");
  assert(rendered.html.includes("Use side entrance &lt;please&gt;"), "customer notes were not escaped");
  assert(rendered.html.includes("Not your booking? Please ignore this email."), "simple recipient disclaimer is missing");
  assert(!rendered.html.includes("Malaysia time"), "redundant timezone label remains");
});

Deno.test("multi-guest receipt uses aligned rows and complete service labels", () => {
  const rendered = renderBookingConfirmationEmail({
    ...payload,
    bookingReference: bookingEmailDisplayReference("Wb04b5a3eed044187bcaed05345f051d3"),
    guestCount: 2,
    serviceLines: [
      "Guest 1 — (Online Exclusive) Foot Massage · 60 min",
      "Guest 2 — (Online Exclusive) Foot Massage · 60 min",
    ],
  });
  assert(rendered.html.includes(">Guests<"), "guest count row is missing");
  assert(rendered.html.includes("Guest 1 — (Online Exclusive) Foot Massage · 60 min"), "first full service label is missing");
  assert(rendered.html.includes("Guest 2 — (Online Exclusive) Foot Massage · 60 min"), "second full service label is missing");
  assert(rendered.html.includes("Wb04b5a3eed044187bcaed05345f051d3"), "full order number is missing or changed");
});

Deno.test("phone masking shows Malaysia code and only the final four digits", () => {
  assert(maskedBookingPhone("+60 12-287 2238") === "60****2238", "phone mask is incorrect");
  assert(maskedBookingPhone("") === "", "empty phone should remain empty");
});

Deno.test("verified Fiuu channels use customer-facing payment names", () => {
  assert(bookingEmailPaymentMethod("TNG-EWALLET") === "Touch 'n Go eWallet", "TNG channel was not mapped");
  assert(bookingEmailPaymentMethod("RPP_DuitNowQR") === "DuitNow QR", "DuitNow channel was not mapped");
  assert(bookingEmailPaymentMethod("GrabPay") === "GrabPay", "GrabPay channel was not mapped");
  assert(bookingEmailPaymentMethod("ShopeePay") === "ShopeePay", "ShopeePay channel was not mapped");
  assert(bookingEmailPaymentMethod("credit") === "Card payment", "credit channel was not mapped");
});

Deno.test("automatic retry delay is bounded and honors Retry-After", () => {
  assert(automaticRetryDelaySeconds(1) === 60, "first retry delay is not one minute");
  assert(automaticRetryDelaySeconds(5) === 960, "exponential retry delay is incorrect");
  assert(automaticRetryDelaySeconds(6) === 1800, "retry delay did not respect the thirty-minute cap");
  assert(automaticRetryDelaySeconds(1, 10) === 60, "short Retry-After bypassed exponential backoff");
  assert(automaticRetryDelaySeconds(6, 3600) === 3600, "long Retry-After was not respected");
  assert(automaticRetryDelaySeconds(2, Number.NaN) === 120, "invalid Retry-After changed exponential backoff");
  assert(parseRetryAfter("12") === 12, "seconds Retry-After was not parsed");
  const now = Date.parse("2026-09-17T00:00:00Z");
  assert(parseRetryAfter("Thu, 17 Sep 2026 00:00:30 GMT", now) === 30, "date Retry-After was not parsed");
});

Deno.test("Resend request uses the supplied idempotency key", async () => {
  const settings = bookingEmailSettings("live", reader({
    BOOKING_EMAIL_ENABLED: "true",
    RESEND_API_KEY: "re_test",
    BOOKING_EMAIL_FROM: "The Best Wellness <bookings@example.com>",
  }));
  let capturedHeaders = new Headers();
  const result = await sendBookingConfirmationEmail(
    payload,
    settings,
    "manual-delivery-id-1",
    async (_input, init) => {
      capturedHeaders = new Headers(init?.headers);
      return new Response(JSON.stringify({ id: "email_123" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  );
  assert(result.id === "email_123", "Resend id was not returned");
  assert(capturedHeaders.get("Idempotency-Key") === "manual-delivery-id-1", "idempotency key was not sent");
});

Deno.test("Resend request diagnostics are sanitized and verify staging configuration", () => {
  const settings = bookingEmailSettings("sandbox", reader({
    BOOKING_EMAIL_ENABLED: "true",
    RESEND_API_KEY: "re_test_secret",
    BOOKING_EMAIL_FROM: `  ${EXPECTED_STAGING_BOOKING_EMAIL_FROM}  `,
    BOOKING_EMAIL_REPLY_TO: "support@example.com",
    BOOKING_EMAIL_TEST_RECIPIENT: "qa@example.com",
  }));
  const diagnostics = resendRequestDiagnostics(
    settings,
    payload,
    "qa@example.com",
    "00000000-0000-4000-8000-000000000000",
  );
  assert(diagnostics.from === EXPECTED_STAGING_BOOKING_EMAIL_FROM, "sender was not trimmed");
  assert(diagnostics.fromMatchesExpectedStagingValue, "staging sender did not match expected value");
  assert(!diagnostics.fromHasSurroundingLiteralQuotes, "sender retained literal quotes");
  assert(!diagnostics.fromHasLineBreak, "sender contains a line break");
  assert(diagnostics.replyToField === "reply_to", "wrong Reply-To field name was reported");
  assert(diagnostics.replyToValid, "valid Reply-To address was rejected");
  assert(diagnostics.testRecipientValid, "valid test recipient was rejected");
  assert(diagnostics.recipient === "q***@example.com", "recipient was not masked");
  assert(diagnostics.htmlPresent && diagnostics.textPresent, "email bodies were not reported");
  assert(diagnostics.idempotencyKeyLength === 36, "idempotency key length is wrong");
  assert(diagnostics.authorizationScheme === "Bearer", "authorization scheme is wrong");
  assert(!JSON.stringify(diagnostics).includes("re_test_secret"), "API key leaked into diagnostics");
});

Deno.test("Resend structured errors are sanitized", () => {
  const details = parseResendErrorBody(JSON.stringify({
    name: "validation_error",
    code: "invalid_from",
    message: "Invalid sender customer@example.com using re_private_value\r\nPlease fix it",
  }));
  assert(details.name === "validation_error", "provider error name was not retained");
  assert(details.code === "invalid_from", "provider error code was not retained");
  assert(details.message?.includes("***@example.com"), "email address was not masked");
  assert(!details.message?.includes("customer@example.com"), "full email leaked");
  assert(!details.message?.includes("re_private_value"), "API key leaked");
  assert(!details.message?.includes("\n"), "provider message retained a newline");
});

Deno.test("429 is retryable and a permanent 400 is not", async () => {
  const settings = bookingEmailSettings("live", reader({
    BOOKING_EMAIL_ENABLED: "true",
    RESEND_API_KEY: "re_test",
    BOOKING_EMAIL_FROM: "The Best Wellness <bookings@example.com>",
  }));
  let retryError: unknown;
  try {
    await sendBookingConfirmationEmail(
      payload,
      settings,
      "automatic-delivery-id-1",
      async () => new Response("rate limited", {
        status: 429,
        headers: { "retry-after": "17" },
      }),
    );
  } catch (error) {
    retryError = error;
  }
  assert(retryError instanceof BookingEmailDeliveryError, "429 did not produce a delivery error");
  assert(retryError.retryable, "429 was not marked retryable");
  assert(retryError.retryAfterSeconds === 17, "Retry-After was not retained");

  let permanentError: unknown;
  try {
    await sendBookingConfirmationEmail(
      payload,
      settings,
      "automatic-delivery-id-2",
      async () => new Response("invalid recipient", { status: 400 }),
    );
  } catch (error) {
    permanentError = error;
  }
  assert(permanentError instanceof BookingEmailDeliveryError, "400 did not produce a delivery error");
  assert(!permanentError.retryable, "400 was incorrectly marked retryable");
  assert(permanentError.message.includes("invalid recipient"), "400 response body was not retained");
});

Deno.test("disabled delivery is rejected before any Resend request", async () => {
  const settings = bookingEmailSettings("live", reader({
    BOOKING_EMAIL_ENABLED: "false",
    RESEND_API_KEY: "re_test",
    BOOKING_EMAIL_FROM: "The Best Wellness <bookings@example.com>",
  }));
  let called = false;
  let error: unknown;
  try {
    await sendBookingConfirmationEmail(
      payload,
      settings,
      "disabled-delivery-id",
      async () => {
        called = true;
        return new Response(JSON.stringify({ id: "unexpected" }), { status: 200 });
      },
    );
  } catch (caught) {
    error = caught;
  }
  assert(error instanceof BookingEmailDeliveryError, "disabled delivery did not fail closed");
  assert(!called, "disabled delivery attempted a network request");
  assert(escapeHtml("<&>\"'") === "&lt;&amp;&gt;&quot;&#39;", "HTML escaping regression");
});
