import { assert, assertEquals } from "jsr:@std/assert@1";

// Set up two pending Staging holds and a single-use code before running this
// test. The test only calls the public Edge Function and releases the winner.
// Required: BOOKING_API_URL, BOOKING_PUBLISHABLE_KEY, TEST_PROMOTION_CODE,
// TEST_PROMOTION_TOKEN_A, TEST_PROMOTION_TOKEN_B.
Deno.test({
  name: "a single-use promotion can be reserved by only one concurrent hold",
  ignore: ![
    "BOOKING_API_URL",
    "BOOKING_PUBLISHABLE_KEY",
    "TEST_PROMOTION_CODE",
    "TEST_PROMOTION_TOKEN_A",
    "TEST_PROMOTION_TOKEN_B",
  ].every((name) => Deno.env.get(name)),
  fn: async () => {
    const url = Deno.env.get("BOOKING_API_URL")!;
    const key = Deno.env.get("BOOKING_PUBLISHABLE_KEY")!;
    const code = Deno.env.get("TEST_PROMOTION_CODE")!;
    const tokens = [
      Deno.env.get("TEST_PROMOTION_TOKEN_A")!,
      Deno.env.get("TEST_PROMOTION_TOKEN_B")!,
    ];
    const apply = (token: string) => fetch(`${url}/booking-holds/promotion`, {
      method: "POST",
      headers: { apikey: key, "Content-Type": "application/json" },
      body: JSON.stringify({ token, code }),
    });
    const responses = await Promise.all(tokens.map(apply));
    assertEquals(responses.map((response) => response.status).sort(), [200, 422]);
    const payloads = await Promise.all(responses.map((response) => response.json()));
    const winner = payloads.findIndex((payload) => payload?.pricing?.promotion_code);
    assert(winner >= 0);
    assert(
      payloads.some((payload) =>
        ["PROMOTION_FULLY_REDEEMED", "PROMOTION_CUSTOMER_LIMIT"].includes(payload?.code)
      ),
    );

    await fetch(`${url}/booking-holds/promotion/remove`, {
      method: "POST",
      headers: { apikey: key, "Content-Type": "application/json" },
      body: JSON.stringify({ token: tokens[winner] }),
    });
  },
});
