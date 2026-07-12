// Public configuration only. Never place a Supabase secret/service-role key here.
window.BOOKING_CONFIG = {
  supabaseUrl: "https://hvyzexmsaxwendcexehx.supabase.co",
  publishableKey: "sb_publishable_bfxOdSPTNjoP1MixTd2pig_j8GFF3OW",
  // Fallback only: if Billplz isn't configured on the Edge Function, immediately
  // confirm the hold into a real appointment instead of redirecting to pay.
  // Requires BOOKING_TEST_AUTOCONFIRM=true on the Edge Function. Now that Billplz
  // sandbox is wired up, leave this false — sandbox payments are the real test path.
  testAutoConfirm: false,
};
