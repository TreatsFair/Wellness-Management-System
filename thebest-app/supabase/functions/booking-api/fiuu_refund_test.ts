import { createHash } from "node:crypto";
import {
  fiuuAdvancedRefundInquiryRequest,
  fiuuAdvancedRefundInquiryResult,
  fiuuRefundInquiryByTransactionRequest,
  fiuuRefundInquiryResultByTransaction,
  fiuuAdvancedRefundRequest,
  verifyFiuuAdvancedRefundResponse,
  type FiuuCredentials,
} from "./fiuu.ts";

const credentials: FiuuCredentials = {
  merchantId: "SB_TEST",
  verifyKey: "verify-test",
  secretKey: "secret-test",
  extendedVcode: false,
};
const hash = (value: string) =>
  createHash("md5").update(value).digest("hex");

Deno.test("advanced full refund uses stable reference and documented signature", () => {
  const { fields } = fiuuAdvancedRefundRequest(
    "123456", "TBWRfixture", "39.00", credentials,
  );
  if (fields.RefundType !== "P" || fields.Amount !== "39.00" ||
      fields.RefID !== "TBWRfixture" ||
      fields.Signature !== hash("PSB_TESTTBWRfixture12345639.00secret-test")) {
    throw new Error("Advanced refund request did not match Fiuu's contract");
  }
  const inquiry = fiuuAdvancedRefundInquiryRequest("TBWRfixture", credentials);
  if (inquiry.fields.Signature !== hash("TBWRfixtureSB_TESTverify-test")) {
    throw new Error("Refund inquiry signature did not match Fiuu's contract");
  }
});

Deno.test("advanced refund response requires signed matching identity", () => {
  const response = {
    RefundType: "P", MerchantID: "SB_TEST", RefID: "TBWRfixture",
    RefundID: "98765", TxnID: "123456", Amount: "39.00", Status: "22",
    Signature: hash("PSB_TESTTBWRfixture9876512345639.0022secret-test"),
  };
  if (!verifyFiuuAdvancedRefundResponse(
    response, "123456", "TBWRfixture", "39.00", credentials,
  )) throw new Error("Valid Fiuu refund response rejected");
  if (verifyFiuuAdvancedRefundResponse(
    { ...response, Amount: "49.00" }, "123456", "TBWRfixture", "39.00",
    credentials,
  )) throw new Error("Mismatched refund amount accepted");
});

Deno.test("refund inquiry accepts one matching Fiuu array item only", () => {
  const response = {
    TxnID: "123456", RefID: "TBWRfixture", RefundID: "98765",
    Status: "success", LastUpdate: "2026-09-24 01:28:04",
  };
  const result = (value: unknown) => fiuuAdvancedRefundInquiryResult(
    value, "123456", "TBWRfixture", "98765",
  );
  if (result([response]) !== "success" || result(response) !== "success") {
    throw new Error("Matching Fiuu refund success was rejected");
  }
  for (const invalid of [
    [], [response, response],
    [{ ...response, TxnID: "other" }],
    [{ ...response, RefID: "other" }],
    [{ ...response, RefundID: "other" }],
    [{ ...response, Status: "unknown" }],
    { error_code: "INQ006" },
  ]) {
    if (result(invalid) !== null) {
      throw new Error("Ambiguous or mismatched inquiry was accepted");
    }
  }
});

Deno.test("reversal refund inquiry uses transaction signature and matching refund ID", () => {
  const request = fiuuRefundInquiryByTransactionRequest("123456", credentials);
  if (request.fields.Signature !== hash("123456SB_TESTverify-test")) {
    throw new Error("Transaction inquiry signature did not match Fiuu's contract");
  }
  const row = { TxnID: "123456", RefID: "order-1", RefundID: "98765", Status: "success" };
  const result = (value: unknown) =>
    fiuuRefundInquiryResultByTransaction(value, "123456", "98765");
  if (result([row]) !== "success" || result(row) !== "success") {
    throw new Error("Matching reversal refund success was rejected");
  }
  for (const invalid of [
    [], [{ ...row, TxnID: "other" }], [{ ...row, RefundID: "other" }],
    [{ ...row, Status: "unknown" }], [row, row], { error_code: "INQ006" },
  ]) {
    if (result(invalid) !== null) {
      throw new Error("Ambiguous or mismatched reversal inquiry was accepted");
    }
  }
});
