// PRODUCTION PREVIEW deployment only (tbwlive.netlify.app).
//
// This file is never served by the staging site (tbwtest.netlify.app) or the
// public site (thebestwellness.my). It replaces js/booking-config.js at deploy
// time via the preview site's build command, so booking.html, booking-api.js
// and booking-page.js stay byte-identical across all three deployments.
//
// Public configuration only. Never place a Supabase secret/service-role key or
// any Billplz value here — all four Billplz credentials live exclusively in
// Edge Function secrets and are never sent to a browser.
window.BOOKING_CONFIG = {
  supabaseUrl: "https://erjttzhownsxohpvzjbs.supabase.co",
  publishableKey: "sb_publishable_1z21AP6inEGHlsinvDQeKQ_FVc_K4zE",
  // Permanently disabled. The deployed booking-api hardcodes AUTO_CONFIRM =
  // false and does not read a test-autoconfirm variable at all, so this is
  // belt-and-braces rather than the actual gate.
  testAutoConfirm: false,
};

// The banner is mounted from here rather than from the shared booking.html so
// that staging and the public site cannot inherit it. booking.html loads this
// script near the end of <body>, and .booking-header is a normal in-flow block,
// so prepending pushes the page down without disturbing the layout.
(function () {
  function mountProductionTestBanner() {
    if (document.getElementById("production-test-banner")) return;

    var banner = document.createElement("div");
    banner.id = "production-test-banner";
    banner.setAttribute("role", "alert");
    banner.textContent =
      "PRODUCTION TEST — real database and live payments. This is not the public booking site.";
    banner.style.cssText = [
      "box-sizing:border-box",
      "width:100%",
      "padding:10px 16px",
      "background:#B3261E",
      "color:#fff",
      "font:600 14px/1.4 system-ui,-apple-system,Segoe UI,sans-serif",
      "letter-spacing:.02em",
      "text-align:center",
    ].join(";");

    document.body.prepend(banner);
    document.title = "[PRODUCTION TEST] " + document.title;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mountProductionTestBanner);
  } else {
    mountProductionTestBanner();
  }
})();
