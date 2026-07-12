import { assertEquals } from "jsr:@std/assert@1";

// Required environment variables:
// BOOKING_API_URL, BOOKING_PUBLISHABLE_KEY, TEST_CATALOGUE_ID, TEST_START_AT.
// The fixture must have one eligible therapist and one available room slot.
Deno.test("simultaneous public holds cannot reserve the same capacity twice", async () => {
  const url = Deno.env.get("BOOKING_API_URL")!;
  const key = Deno.env.get("BOOKING_PUBLISHABLE_KEY")!;
  const catalogueId = Deno.env.get("TEST_CATALOGUE_ID")!;
  const startAt = Deno.env.get("TEST_START_AT")!;
  if (![url, key, catalogueId, startAt].every(Boolean)) {
    throw new Error("Concurrency test environment is incomplete");
  }

  const request = (suffix: string) => fetch(`${url}/booking-holds`, {
    method: "POST",
    headers: { apikey: key, "Content-Type": "application/json", "x-test-client": suffix },
    body: JSON.stringify({
      catalogue_id: catalogueId,
      start_at: startAt,
      therapist_preference: "none",
      customer_name: `Concurrency ${suffix}`,
      customer_phone: `60120000${suffix}`,
      customer_email: `concurrency-${suffix}@example.test`,
      notes: "Automated concurrency test",
      website: "",
    }),
  });

  const responses = await Promise.all([request("01"), request("02")]);
  const statuses = responses.map((response) => response.status).sort();
  assertEquals(statuses, [201, 409]);
});

Deno.test({
  name: "configured capacity three accepts three holds and rejects the fourth",
  ignore: !Deno.env.get("TEST_CAPACITY_THREE_CATALOGUE_ID"),
  fn: async () => {
    const url = Deno.env.get("BOOKING_API_URL")!;
    const key = Deno.env.get("BOOKING_PUBLISHABLE_KEY")!;
    const catalogueId = Deno.env.get("TEST_CAPACITY_THREE_CATALOGUE_ID")!;
    const startAt = Deno.env.get("TEST_CAPACITY_THREE_START_AT")!;
    const responses = await Promise.all(Array.from({ length: 4 }, (_, index) => fetch(`${url}/booking-holds`, {
      method: "POST",
      headers: { apikey: key, "Content-Type": "application/json" },
      body: JSON.stringify({
        catalogue_id: catalogueId, start_at: startAt, therapist_preference: "none",
        customer_name: `Capacity ${index}`, customer_phone: `6012111000${index}`,
        customer_email: `capacity-${index}@example.test`, website: "",
      }),
    })));
    assertEquals(responses.map((response) => response.status).sort(), [201, 201, 201, 409]);
  },
});

Deno.test({
  name: "overlapping half-hour starts cannot race for one therapist and room",
  ignore: !Deno.env.get("TEST_OVERLAP_CATALOGUE_ID"),
  fn: async () => {
    const url = Deno.env.get("BOOKING_API_URL")!;
    const key = Deno.env.get("BOOKING_PUBLISHABLE_KEY")!;
    const catalogueId = Deno.env.get("TEST_OVERLAP_CATALOGUE_ID")!;
    const starts = [Deno.env.get("TEST_OVERLAP_START_A")!, Deno.env.get("TEST_OVERLAP_START_B")!];
    const responses = await Promise.all(starts.map((startAt, index) => fetch(`${url}/booking-holds`, {
      method: "POST",
      headers: { apikey: key, "Content-Type": "application/json" },
      body: JSON.stringify({
        catalogue_id: catalogueId, start_at: startAt, therapist_preference: "none",
        customer_name: `Overlap ${index}`, customer_phone: `6012222000${index}`,
        customer_email: `overlap-${index}@example.test`, website: "",
      }),
    })));
    assertEquals(responses.map((response) => response.status).sort(), [201, 409]);
  },
});
