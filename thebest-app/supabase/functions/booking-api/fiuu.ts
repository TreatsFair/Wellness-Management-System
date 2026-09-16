import { createHash, createHmac } from "node:crypto";

// Fiuu API Spec for Merchant v13.93, Payment Page Integration and Getting
// Payment Result. This module deliberately has no database or network access.
// The caller must bind the order to a durable payment attempt before exposing
// the hosted checkout form to a customer.

const MERCHANT_ID = /^[A-Za-z0-9_-]{1,32}$/;
const ORDER_ID = /^[A-Za-z0-9-]{1,40}$/;
const TRANSACTION_ID = /^[0-9]{1,20}$/;
const HASH = /^[a-f0-9]{32}$/i;
const RETURN_PROOF = /^[a-f0-9]{64}$/i;
const FIUU_STATUS = new Set(["00", "11", "22"]);

export type FiuuEnvironment = "sandbox" | "live";
export type FiuuChannel = "TNG-EWALLET" | "RPP_DuitNowQR";

export type FiuuCredentials = {
  merchantId: string;
  verifyKey: string;
  secretKey: string;
  extendedVcode: boolean;
};

export type FiuuCheckout = {
  environment: FiuuEnvironment;
  credentials: FiuuCredentials;
  orderId: string;
  amount: string;
  customerName: string;
  customerEmail: string;
  customerMobile: string;
  description: string;
  expiresAt: Date;
  waitTimeSeconds?: number;
  channel?: FiuuChannel;
  returnUrl?: string;
  callbackUrl?: string;
  cancelUrl?: string;
};

export type FiuuPaymentResponse = {
  amount: string;
  orderid: string;
  tranID: string;
  domain: string;
  status: string;
  appcode: string;
  skey: string;
  currency: string;
  paydate: string;
  channel: string;
};

export type FiuuReversalResponse = {
  TranID: string;
  Domain: string;
  VrfKey: string;
  StatCode: string;
  StatDate: string;
  refundID: string;
};

export type FiuuStatusResponse = {
  Amount: string;
  TranID: string;
  Domain: string;
  Channel: string;
  VrfKey: string;
  StatCode: string;
  StatName: string;
  Currency: string;
  ErrorCode: string;
  ErrorDesc: string;
};

function md5(value: string): string {
  return createHash("md5").update(value, "utf8").digest("hex");
}

function equalHash(a: string, b: string): boolean {
  if (!HASH.test(a) || !HASH.test(b)) return false;
  let difference = 0;
  for (let index = 0; index < 32; index++) {
    difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return difference === 0;
}

function validAmount(value: string): boolean {
  return /^(?:0|[1-9][0-9]*)\.[0-9]{2}$/.test(value) && Number(value) > 0;
}

export function fiuuVcode(
  amount: string,
  orderId: string,
  credentials: FiuuCredentials,
): string {
  if (!validAmount(amount) || !ORDER_ID.test(orderId)) {
    throw new Error("Invalid Fiuu payment amount or order ID");
  }
  if (!MERCHANT_ID.test(credentials.merchantId) || !credentials.verifyKey) {
    throw new Error("Fiuu merchant credentials are not configured");
  }
  const input = amount + credentials.merchantId + orderId +
    credentials.verifyKey + (credentials.extendedVcode ? "MYR" : "");
  return md5(input);
}

// This proof is only a browser navigation capability. It never verifies or
// settles a payment; the signed server notification remains authoritative.
export function fiuuReturnProof(orderId: string, secretKey: string): string {
  if (!ORDER_ID.test(orderId) || !secretKey) throw new Error("Invalid Fiuu return proof input");
  return createHmac("sha256", secretKey).update(`fiuu-return:${orderId}`, "utf8").digest("hex");
}

export function verifyFiuuReturnProof(orderId: string, proof: string, secretKey: string): boolean {
  if (!ORDER_ID.test(orderId) || !RETURN_PROOF.test(proof) || !secretKey) return false;
  const expected = fiuuReturnProof(orderId, secretKey);
  let difference = 0;
  for (let index = 0; index < expected.length; index++) {
    difference |= expected.charCodeAt(index) ^ proof.charCodeAt(index);
  }
  return difference === 0;
}

export function fiuuHostedPaymentRequest(checkout: FiuuCheckout): {
  action: string;
  fields: Record<string, string>;
} {
  const { credentials } = checkout;
  if (!MERCHANT_ID.test(credentials.merchantId) ||
      (checkout.environment === "sandbox" && !credentials.merchantId.startsWith("SB_")) ||
      (checkout.environment === "live" && credentials.merchantId.startsWith("SB_"))) {
    throw new Error("Fiuu merchant ID does not match the payment environment");
  }
  if (!validAmount(checkout.amount) || !ORDER_ID.test(checkout.orderId)) {
    throw new Error("Invalid Fiuu payment amount or order ID");
  }
  if (Number.isNaN(checkout.expiresAt.getTime()) ||
      checkout.expiresAt.getTime() <= Date.now()) {
    throw new Error("Fiuu payment deadline has expired");
  }
  if (checkout.waitTimeSeconds !== undefined &&
      (!Number.isInteger(checkout.waitTimeSeconds) || checkout.waitTimeSeconds <= 0)) {
    throw new Error("Invalid Fiuu payment countdown");
  }
  if (!checkout.customerName.trim() || !checkout.customerEmail.trim() ||
      !checkout.customerMobile.trim() || !checkout.description.trim()) {
    throw new Error("Fiuu customer payment details are incomplete");
  }

  const host = checkout.environment === "sandbox"
    ? "sandbox-payment.fiuu.com"
    : "pay.fiuu.com";
  const fields: Record<string, string> = {
    amount: checkout.amount,
    orderid: checkout.orderId,
    bill_name: checkout.customerName.trim(),
    bill_email: checkout.customerEmail.trim(),
    bill_mobile: checkout.customerMobile.trim(),
    bill_desc: checkout.description.trim(),
    country: "MY",
    currency: "MYR",
    vcode: fiuuVcode(checkout.amount, checkout.orderId, credentials),
    PaymentExpirationTime: checkout.expiresAt.toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  if (checkout.waitTimeSeconds !== undefined) {
    fields.waittime = String(checkout.waitTimeSeconds);
  }
  if (checkout.channel) fields.channel = checkout.channel;
  if (checkout.returnUrl) fields.returnurl = checkout.returnUrl;
  if (checkout.callbackUrl) fields.callbackurl = checkout.callbackUrl;
  if (checkout.cancelUrl) fields.cancelurl = checkout.cancelUrl;
  return {
    action: `https://${host}/RMS/pay/${credentials.merchantId}/`,
    fields,
  };
}

export function fiuuResponseFromForm(form: FormData): FiuuPaymentResponse {
  const get = (name: string) => {
    const value = form.get(name);
    return typeof value === "string" ? value : "";
  };
  return {
    amount: get("amount"),
    orderid: get("orderid"),
    tranID: get("tranID"),
    domain: get("domain"),
    status: get("status"),
    appcode: get("appcode"),
    skey: get("skey"),
    currency: get("currency"),
    paydate: get("paydate"),
    channel: get("channel"),
  };
}

export function fiuuResponseValidationIssue(
  response: FiuuPaymentResponse,
  expected: {
    credentials: FiuuCredentials;
    orderId: string;
    amount: string;
  },
): "configuration" | "transaction" | "status" | "identity" | "paydate" | "signature" | null {
  if (!expected.credentials.secretKey ||
      !MERCHANT_ID.test(expected.credentials.merchantId) ||
      !ORDER_ID.test(expected.orderId) || !validAmount(expected.amount)) {
    return "configuration";
  }
  if (!TRANSACTION_ID.test(response.tranID)) return "transaction";
  if (!FIUU_STATUS.has(response.status)) return "status";
  if (
      response.domain !== expected.credentials.merchantId ||
      response.orderid !== expected.orderId ||
      response.amount !== expected.amount ||
      (response.currency !== "MYR" && response.currency !== "RM")) {
    return "identity";
  }
  if (!/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/.test(response.paydate)) return "paydate";
  const first = md5(response.tranID + response.orderid + response.status +
    response.domain + response.amount + response.currency);
  const expectedSkey = md5(response.paydate + response.domain + first +
    response.appcode + expected.credentials.secretKey);
  return equalHash(expectedSkey, response.skey) ? null : "signature";
}

export function verifyFiuuResponse(
  response: FiuuPaymentResponse,
  expected: {
    credentials: FiuuCredentials;
    orderId: string;
    amount: string;
  },
): boolean {
  return fiuuResponseValidationIssue(response, expected) === null;
}

export function fiuuReversalRequest(
  transactionId: string,
  credentials: FiuuCredentials,
): { fields: Record<string, string> } {
  if (!TRANSACTION_ID.test(transactionId) ||
      !MERCHANT_ID.test(credentials.merchantId) || !credentials.secretKey) {
    throw new Error("Invalid Fiuu reversal request");
  }
  return {
    fields: {
      txnID: transactionId,
      domain: credentials.merchantId,
      skey: md5(transactionId + credentials.merchantId + credentials.secretKey),
      type: "2",
    },
  };
}

export function verifyFiuuReversalResponse(
  response: FiuuReversalResponse,
  transactionId: string,
  credentials: FiuuCredentials,
): boolean {
  if (response.TranID !== transactionId ||
      response.Domain !== credentials.merchantId ||
      !/^\d{2}$/.test(response.StatCode) || !credentials.secretKey) return false;
  const expected = md5(
    credentials.secretKey + response.Domain + response.TranID + response.StatCode,
  );
  return equalHash(expected, response.VrfKey);
}

export function fiuuStatusRequest(
  transactionId: string,
  amount: string,
  credentials: FiuuCredentials,
): { fields: Record<string, string> } {
  if (!TRANSACTION_ID.test(transactionId) || !validAmount(amount) ||
      !MERCHANT_ID.test(credentials.merchantId) || !credentials.verifyKey) {
    throw new Error("Invalid Fiuu status request");
  }
  return {
    fields: {
      amount,
      txID: transactionId,
      domain: credentials.merchantId,
      skey: md5(transactionId + credentials.merchantId +
        credentials.verifyKey + amount),
      type: "2",
    },
  };
}

export function verifyFiuuStatusResponse(
  response: FiuuStatusResponse,
  transactionId: string,
  amount: string,
  credentials: FiuuCredentials,
): boolean {
  if (response.TranID !== transactionId || response.Amount !== amount ||
      response.Domain !== credentials.merchantId ||
      !/^\d{2}$/.test(response.StatCode) || !credentials.secretKey) return false;
  const expected = md5(
    response.Amount + credentials.secretKey + response.Domain +
      response.TranID + response.StatCode,
  );
  return equalHash(expected, response.VrfKey);
}
