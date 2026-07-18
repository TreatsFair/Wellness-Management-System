(function () {
  const config = window.BOOKING_CONFIG || {};
  const supabaseUrl = String(config.supabaseUrl || "").replace(/\/$/, "");
  const publishableKey = String(config.publishableKey || "").trim();
  const configured = /^https:\/\/.+\.supabase\.co$/i.test(supabaseUrl) && publishableKey.length > 20;
  const baseUrl = configured ? `${supabaseUrl}/functions/v1/booking-api` : "";

  class BookingApiError extends Error {
    constructor(message, status) {
      super(message);
      this.name = "BookingApiError";
      this.status = status;
    }
  }

  async function request(path, options = {}) {
    if (!configured) throw new BookingApiError("Supabase booking is not configured", 0);
    const response = await fetch(`${baseUrl}${path}`, {
      ...options,
      headers: {
        apikey: publishableKey,
        "Content-Type": "application/json",
        ...(options.headers || {}),
      },
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new BookingApiError(payload.error || "Booking request failed", response.status);
    }
    return payload;
  }

  window.BookingApi = {
    configured,
    getOutlets: () => request("/outlets"),
    getCatalogue: (outletCode) => request(`/catalogue?outlet=${encodeURIComponent(outletCode)}`),
    getDates: ({ catalogueId, preference }) => {
      const params = new URLSearchParams({
        catalogue_id: catalogueId,
        therapist_preference: preference,
      });
      return request(`/availability/dates?${params}`);
    },
    getTimes: ({ catalogueId, date, preference }) => {
      const params = new URLSearchParams({
        catalogue_id: catalogueId,
        date,
        therapist_preference: preference,
      });
      return request(`/availability/times?${params}`);
    },
    getGroupDates: ({ allocations }) => request("/availability/group-dates", {
      method: "POST",
      body: JSON.stringify({ allocations }),
    }),
    getGroupTimes: ({ date, allocations }) => request("/availability/group-times", {
      method: "POST",
      body: JSON.stringify({ date, allocations }),
    }),
    createGroupHold: (body) => request("/booking-groups", {
      method: "POST",
      body: JSON.stringify(body),
    }),
    createHold: (body) => request("/booking-holds", {
      method: "POST",
      body: JSON.stringify(body),
    }),
    confirmHold: (token) => request("/booking-holds/confirm", {
      method: "POST",
      body: JSON.stringify({ token }),
    }),
    payHold: (token) => request("/booking-holds/pay", {
      method: "POST",
      body: JSON.stringify({ token }),
    }),
    getHoldStatus: (token) => request(`/booking-holds/status?token=${encodeURIComponent(token)}`),
  };
})();
