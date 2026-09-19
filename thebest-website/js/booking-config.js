// Public configuration only. Never place a Supabase secret/service-role key here.
window.BOOKING_CONFIG = {
  supabaseUrl: "https://hvyzexmsaxwendcexehx.supabase.co",
  publishableKey: "sb_publishable_bfxOdSPTNjoP1MixTd2pig_j8GFF3OW",
  // STAGING only. The public/production hostname override below controls the
  // separate live-payment test gate. Keep staging limited to Taman Wahyu.
  onlinePaymentEnabled: true,
  onlinePaymentOutletCodes: ["taman-wahyu"],
  // Fallback only: if Billplz isn't configured on the Edge Function, immediately
  // confirm the hold into a real appointment instead of redirecting to pay.
  // Requires BOOKING_TEST_AUTOCONFIRM=true on the Edge Function. Now that Billplz
  // sandbox is wired up, leave this false — sandbox payments are the real test path.
  testAutoConfirm: false,
};

// The public domain and production preview use Production. The staging
// hostname and local development retain the configuration above unchanged.
if (new Set([
  "thebestwellness.my",
  "www.thebestwellness.my",
  "tbwlive.netlify.app",
]).has(window.location.hostname.toLowerCase())) {
  window.BOOKING_CONFIG = {
    supabaseUrl: "https://erjttzhownsxohpvzjbs.supabase.co",
    publishableKey: "sb_publishable_1z21AP6inEGHlsinvDQeKQ_FVc_K4zE",
    // Controlled Production rollout: expose live payment only for the first
    // outlet while the live integration is being verified.
    onlinePaymentEnabled: true,
    onlinePaymentOutletCodes: ["taman-wahyu"],
    testAutoConfirm: false,
  };
}
