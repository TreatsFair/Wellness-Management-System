import { test } from "node:test";
import { createHash } from "node:crypto";
import {
  fiuuHostedPaymentRequest,
  fiuuResponseFromForm,
  fiuuResponseValidationIssue,
  fiuuReturnProof,
  fiuuReversalRequest,
  fiuuStatusRequest,
  fiuuVcode,
  verifyFiuuReversalResponse,
  verifyFiuuStatusResponse,
  verifyFiuuReturnProof,
  verifyFiuuResponse,
  type FiuuCredentials,
  type FiuuPaymentResponse,
} from "./fiuu.ts";

const credentials: FiuuCredentials = {
  merchantId: "SB_TEST",
  verifyKey: "VERIFY_TEST_KEY",
  secretKey: "SECRET_TEST_KEY",
  extendedVcode: true,
};

const response: FiuuPaymentResponse = {
  amount: "27.60",
  orderid: "ORD-123",
  tranID: "1234567890",
  domain: "SB_TEST",
  status: "00",
  appcode: "APP123",
  skey: "773e77f2f97a8fdefde6865ee44db17f",
  currency: "MYR",
  paydate: "2030-01-01 12:00:00",
  channel: "TNG-EWALLET",
};

test("Fiuu extended vcode matches the published example", () => {
  const documentedCredentials: FiuuCredentials = {
    ...credentials,
    merchantId: "ACME",
    verifyKey: "f5bb0c8de146c67b44babbf4e6584cc0",
  };
  if (fiuuVcode("27.60", "OD8842", documentedCredentials) !==
      "5bf33e6500a53830d4f80087b67e13de") {
    throw new Error("Fiuu vcode did not match its documented test vector");
  }
});

test("Fiuu sandbox checkout sends the original UTC deadline", () => {
  const request = fiuuHostedPaymentRequest({
    environment: "sandbox",
    credentials,
    orderId: "ORD-123",
    amount: "27.60",
    customerName: "Example Guest",
    customerEmail: "guest@example.com",
    customerMobile: "0123456789",
    description: "Booking payment",
    expiresAt: new Date("2030-01-01T04:00:00Z"),
    waitTimeSeconds: 420,
    channel: "TNG-EWALLET",
    returnUrl: "https://example.test/fiuu/return",
    callbackUrl: "https://example.test/fiuu/callback",
    cancelUrl: "https://example.test/booking?bp_token=test",
  });
  if (request.action !== "https://sandbox-payment.fiuu.com/RMS/pay/SB_TEST/" ||
      request.fields.PaymentExpirationTime !== "2030-01-01T04:00:00Z" ||
      request.fields.waittime !== "420" ||
      request.fields.channel !== "TNG-EWALLET" ||
      request.fields.returnurl !== "https://example.test/fiuu/return" ||
      request.fields.callbackurl !== "https://example.test/fiuu/callback" ||
      request.fields.cancelurl !== "https://example.test/booking?bp_token=test" ||
      "verifyKey" in request.fields || "secretKey" in request.fields) {
    throw new Error("Fiuu hosted payment request was not sandbox-safe");
  }
});

test("Fiuu live checkout uses the production hosted-payment endpoint", () => {
  const liveCredentials: FiuuCredentials = {
    merchantId: "LIVE_TEST",
    verifyKey: "VERIFY_TEST_KEY",
    secretKey: "SECRET_TEST_KEY",
    extendedVcode: false,
  };
  const request = fiuuHostedPaymentRequest({
    environment: "live",
    credentials: liveCredentials,
    orderId: "ORD-LIVE-123",
    amount: "27.60",
    customerName: "Example Guest",
    customerEmail: "guest@example.com",
    customerMobile: "0123456789",
    description: "Booking payment",
    expiresAt: new Date("2030-01-01T04:00:00Z"),
    returnUrl: "https://example.test/fiuu/return",
    callbackUrl: "https://example.test/fiuu/callback",
    cancelUrl: "https://example.test/booking?bp_token=test",
  });
  if (request.action !== "https://pay.fiuu.com/RMS/pay/LIVE_TEST/" ||
      "verifyKey" in request.fields || "secretKey" in request.fields) {
    throw new Error("Fiuu live hosted payment request was not production-safe");
  }
});

test("Fiuu checkout rejects an expired hold and an environment mismatch", () => {
  const checkout = {
    environment: "sandbox" as const,
    credentials,
    orderId: "ORD-123",
    amount: "27.60",
    customerName: "Example Guest",
    customerEmail: "guest@example.com",
    customerMobile: "0123456789",
    description: "Booking payment",
    expiresAt: new Date("2020-01-01T00:00:00Z"),
  };
  let rejectedExpiry = false;
  try {
    fiuuHostedPaymentRequest(checkout);
  } catch (_) {
    rejectedExpiry = true;
  }
  if (!rejectedExpiry) throw new Error("Expired hold was accepted");

  let rejectedEnvironment = false;
  try {
    fiuuHostedPaymentRequest({
      ...checkout,
      environment: "live",
      expiresAt: new Date("2030-01-01T00:00:00Z"),
    });
  } catch (_) {
    rejectedEnvironment = true;
  }
  if (!rejectedEnvironment) throw new Error("Sandbox ID was accepted for live payment");
});

test("Fiuu response checks signature and exact stored payment identity", () => {
  const expected = { credentials, orderId: "ORD-123", amount: "27.60" };
  if (!verifyFiuuResponse(response, expected)) {
    throw new Error("A valid Fiuu payment response was rejected");
  }
  for (const tampered of [
    { ...response, amount: "27.61" },
    { ...response, orderid: "ORD-124" },
    { ...response, domain: "SB_OTHER" },
    { ...response, currency: "USD" },
    { ...response, status: "11" },
    { ...response, skey: "00000000000000000000000000000000" },
  ]) {
    if (verifyFiuuResponse(tampered, expected)) {
      throw new Error("A tampered Fiuu response was accepted");
    }
  }
});

test("a correctly signed Fiuu pending response is accepted as pending evidence", () => {
  const pending = { ...response, status: "22", appcode: "" };
  const first = createHash("md5").update(
    pending.tranID + pending.orderid + pending.status + pending.domain +
      pending.amount + pending.currency,
  ).digest("hex");
  pending.skey = createHash("md5").update(
    pending.paydate + pending.domain + first + pending.appcode + credentials.secretKey,
  ).digest("hex");
  const expected = { credentials, orderId: pending.orderid, amount: pending.amount };
  if (!verifyFiuuResponse(pending, expected) ||
      fiuuResponseValidationIssue(pending, expected) !== null) {
    throw new Error("A valid signed pending response was rejected");
  }
  if (verifyFiuuResponse({ ...pending, status: "00" }, expected)) {
    throw new Error("An unsigned pending-to-success substitution was accepted");
  }
});

test("e-wallet response may omit appcode while retaining a valid signature", () => {
  const first = createHash("md5").update(
    response.tranID + response.orderid + response.status + response.domain +
      response.amount + response.currency,
  ).digest("hex");
  const skey = createHash("md5").update(
    response.paydate + response.domain + first + credentials.secretKey,
  ).digest("hex");
  const form = new FormData();
  for (const [name, value] of Object.entries({ ...response, skey })) {
    if (name !== "appcode") form.set(name, value);
  }
  const parsed = fiuuResponseFromForm(form);
  const expected = { credentials, orderId: response.orderid, amount: response.amount };
  if (parsed.appcode !== "" || !verifyFiuuResponse(parsed, expected)) {
    throw new Error("Signed e-wallet response without appcode was rejected");
  }
  if (fiuuResponseValidationIssue({ ...parsed, skey: response.skey }, expected) !== "signature") {
    throw new Error("Wrong signature was not classified safely");
  }
});

test("Fiuu's signed RM response is accepted for a MYR checkout", () => {
  const rmResponse = { ...response, currency: "RM", appcode: "" };
  const first = createHash("md5").update(
    rmResponse.tranID + rmResponse.orderid + rmResponse.status + rmResponse.domain +
      rmResponse.amount + rmResponse.currency,
  ).digest("hex");
  rmResponse.skey = createHash("md5").update(
    rmResponse.paydate + rmResponse.domain + first + rmResponse.appcode + credentials.secretKey,
  ).digest("hex");
  const expected = { credentials, orderId: response.orderid, amount: response.amount };
  if (!verifyFiuuResponse(rmResponse, expected)) {
    throw new Error("Fiuu's signed RM response was rejected");
  }
  if (verifyFiuuResponse({ ...rmResponse, currency: "MYR" }, expected)) {
    throw new Error("Unsigned currency substitution was accepted");
  }
});

test("empty browser returns require an order-bound proof", () => {
  const proof = fiuuReturnProof("ORD-123", credentials.secretKey);
  if (!verifyFiuuReturnProof("ORD-123", proof, credentials.secretKey) ||
      verifyFiuuReturnProof("ORD-124", proof, credentials.secretKey) ||
      verifyFiuuReturnProof("ORD-123", proof, "OTHER_KEY") ||
      verifyFiuuReturnProof("ORD-123", "00", credentials.secretKey)) {
    throw new Error("Fiuu browser return proof was not bound to the order and key");
  }
});

test("Fiuu response parser never trusts non-string form values", () => {
  const form = new FormData();
  form.set("orderid", "ORD-123");
  form.set("status", "00");
  const parsed = fiuuResponseFromForm(form);
  if (parsed.orderid !== "ORD-123" || parsed.status !== "00" || parsed.skey !== "") {
    throw new Error("Fiuu response form parser returned unexpected data");
  }
});

test("Fiuu reversal request and response are bound to the transaction", () => {
  const request = fiuuReversalRequest("186339", credentials);
  if (request.fields.txnID !== "186339" || request.fields.domain !== "SB_TEST" ||
      request.fields.type !== "2" || request.fields.skey.length !== 32) {
    throw new Error("Fiuu reversal request was not constructed correctly");
  }
  const reversal = {
    TranID: "186339",
    Domain: "SB_TEST",
    StatCode: "00",
    StatDate: "2026-09-15 14:42:00",
    refundID: "123456",
    VrfKey: "dc5189627772628701cc11f9f8b5ff81",
  };
  // VrfKey = md5(secret + Domain + TranID + StatCode).
  const valid = {
    ...reversal,
    VrfKey: createHash("md5")
      .update(credentials.secretKey + reversal.Domain + reversal.TranID + reversal.StatCode)
      .digest("hex"),
  };
  if (!verifyFiuuReversalResponse(valid, "186339", credentials) ||
      verifyFiuuReversalResponse({ ...valid, StatCode: "11" }, "186339", credentials)) {
    throw new Error("Fiuu reversal response verification failed");
  }
});

test("Fiuu status query and response are bound to amount and transaction", () => {
  const request = fiuuStatusRequest("186339", "39.00", credentials);
  if (request.fields.txID !== "186339" || request.fields.amount !== "39.00" ||
      request.fields.skey.length !== 32 || request.fields.type !== "2") {
    throw new Error("Fiuu status request was not constructed correctly");
  }
  const response = {
    Amount: "39.00",
    TranID: "186339",
    Domain: "SB_TEST",
    Channel: "TNG-EWALLET",
    StatCode: "11",
    StatName: "cancelled",
    Currency: "MYR",
    ErrorCode: "34",
    ErrorDesc: "",
    VrfKey: "",
  };
  const valid = {
    ...response,
    VrfKey: createHash("md5")
      .update(response.Amount + credentials.secretKey + response.Domain +
        response.TranID + response.StatCode)
      .digest("hex"),
  };
  if (!verifyFiuuStatusResponse(valid, "186339", "39.00", credentials) ||
      verifyFiuuStatusResponse({ ...valid, Amount: "40.00" }, "186339", "39.00", credentials)) {
    throw new Error("Fiuu status response verification failed");
  }
});
