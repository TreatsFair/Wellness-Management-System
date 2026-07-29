const fallbackOutlets = {
  "taman-wahyu": { id: "00000000-0000-0000-0000-000000000002", name: "Kepong - Taman Wahyu", phone: "60125262551", open_time: "11:00", close_time: "23:00" },
  pv128: { id: "00000000-0000-0000-0000-000000000128", name: "Setapak - PV128", phone: "60127449266", open_time: "10:30", close_time: "00:00" },
};

const api = window.BookingApi;
const outlets = JSON.parse(JSON.stringify(fallbackOutlets));
const MAX_GUESTS = 6;
const BOOKING_SESSION_KEY = "thebest-booking-session-v2";
let services = [];
let serviceLoadError = "";
let availabilityLoadError = "";

function newGuest(index) {
  return { label: `Guest ${index + 1}`, serviceId: null, therapist: "No preference", therapistRequest: "" };
}

function guestLabel(guest, index) {
  return guest?.label.trim() || `Guest ${index + 1}`;
}

const sameForAll = { treatment: false };

const state = {
  step: 1,
  outlet: null,
  guests: [newGuest(0)],
  treatmentGuest: 0,
  date: null,
  time: null,
  slots: [],
  dates: [],
  datesKey: "",
  loadingServices: false,
  loadingDates: false,
  loadingTimes: false,
  hold: null,
  holdFingerprint: "",
  paymentUrl: "",
  appointment: null,
};

const panels = [...document.querySelectorAll("[data-panel]")];
const steps = [...document.querySelectorAll(".step")];
const nextButton = document.querySelector("#continue-button");
const backButton = document.querySelector("#back-button");
const detailsForm = document.querySelector("#details-form");
const summarySheet = document.querySelector("#booking-summary");
const summaryToggle = document.querySelector("#mobile-summary-toggle");
const summaryClose = document.querySelector("#summary-close");
const summaryOverlay = document.querySelector("#summary-overlay");
const paymentDeadline = document.querySelector("#payment-deadline");
const paymentCountdown = document.querySelector("#payment-countdown");
const stepNames = ["Outlet", "Guests", "Treatments", "Date & time", "Billing"];
let dateRequestSerial = 0;
let holdCountdownTimer = null;
let holdExpiryInProgress = false;

function readBookingSession() {
  try {
    const value = JSON.parse(sessionStorage.getItem(BOOKING_SESSION_KEY) || "null");
    return value && typeof value === "object" ? value : null;
  } catch (_) {
    return null;
  }
}

function formSnapshot() {
  const form = new FormData(detailsForm);
  return {
    name: String(form.get("name") || ""),
    phone: String(form.get("phone") || ""),
    email: String(form.get("email") || ""),
    notes: String(form.get("notes") || ""),
    consent: Boolean(document.querySelector("#booking-consent")?.checked),
  };
}

function applyFormSnapshot(snapshot) {
  if (!snapshot) return;
  for (const name of ["name", "phone", "email", "notes"]) {
    const field = detailsForm.elements.namedItem(name);
    if (field) field.value = String(snapshot[name] || "");
  }
  const consent = document.querySelector("#booking-consent");
  if (consent) consent.checked = Boolean(snapshot.consent);
}

function persistBookingSession() {
  try {
    sessionStorage.setItem(BOOKING_SESSION_KEY, JSON.stringify({
      step: state.step,
      outlet: state.outlet,
      guests: state.guests,
      treatmentGuest: state.treatmentGuest,
      date: state.date,
      time: state.time,
      hold: state.hold,
      holdFingerprint: state.holdFingerprint,
      paymentUrl: state.paymentUrl,
      form: formSnapshot(),
    }));
  } catch (_) {
    // The booking still works when private browsing blocks session storage.
  }
}

function restoreBookingSession() {
  const saved = readBookingSession();
  if (!saved) return false;
  if (typeof saved.outlet === "string" && outlets[saved.outlet]) state.outlet = saved.outlet;
  if (Array.isArray(saved.guests) && saved.guests.length >= 1 && saved.guests.length <= MAX_GUESTS) {
    state.guests = saved.guests.map((guest, index) => ({
      ...newGuest(index),
      ...guest,
      label: String(guest?.label || `Guest ${index + 1}`),
    }));
  }
  state.treatmentGuest = Math.min(Number(saved.treatmentGuest) || 0, state.guests.length - 1);
  state.date = typeof saved.date === "string" ? saved.date : null;
  state.time = saved.time?.startAt ? saved.time : null;
  state.hold = saved.hold?.token ? saved.hold : null;
  state.holdFingerprint = typeof saved.holdFingerprint === "string" ? saved.holdFingerprint : "";
  state.paymentUrl = typeof saved.paymentUrl === "string" ? saved.paymentUrl : "";
  state.step = Math.min(5, Math.max(1, Number(saved.step) || 1));
  applyFormSnapshot(saved.form);
  return true;
}

function currentBookingFingerprint(form = new FormData(detailsForm)) {
  return JSON.stringify({
    outlet: state.outlet,
    allocations: allocationsPayload(),
    start_at: state.time?.startAt || "",
    customer_name: String(form.get("name") || "").trim(),
    customer_phone: String(form.get("phone") || "").trim(),
    customer_email: String(form.get("email") || "").trim().toLowerCase(),
    notes: String(form.get("notes") || "").trim(),
  });
}

function clearActiveHold() {
  state.hold = null;
  state.holdFingerprint = "";
  state.paymentUrl = "";
  holdExpiryInProgress = false;
  if (holdCountdownTimer) clearInterval(holdCountdownTimer);
  holdCountdownTimer = null;
  paymentDeadline.hidden = true;
  paymentDeadline.classList.remove("is-urgent");
  persistBookingSession();
}

function escapeHtml(value) {
  return String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
}

function money(value) { return `RM ${Number(value || 0).toFixed(0)}`; }
function clockTime(value) {
  const [hourText, minuteText] = String(value || "").split(":");
  const hour = Number(hourText);
  const minute = Number(minuteText);
  if (!Number.isInteger(hour) || !Number.isInteger(minute)) return "";
  const suffix = hour < 12 ? "AM" : "PM";
  const displayHour = hour % 12 || 12;
  return `${displayHour}:${String(minute).padStart(2, "0")} ${suffix}`;
}
function renderOutletHours(button, outlet) {
  const label = button.querySelector("[data-outlet-hours]");
  const opening = clockTime(outlet?.open_time);
  const closing = clockTime(outlet?.close_time);
  if (label && opening && closing) label.textContent = `${opening} – ${closing}`;
}
function selectedOutlet() { return state.outlet ? outlets[state.outlet] : null; }
function serviceById(id) { return services.find((service) => service.id === id) || null; }
function selectedServices() { return state.guests.map((guest) => serviceById(guest.serviceId)).filter(Boolean); }
function totalPrice() { return selectedServices().reduce((sum, service) => sum + Number(service.price || 0), 0); }
function visitDuration() { return Math.max(0, ...selectedServices().map((service) => Number(service.duration || 0))); }
function allTreatmentsChosen() { return state.guests.every((guest) => Boolean(guest.serviceId)); }
function preferenceCode(value) {
  if (value === "Female masseur" || value === "Female therapist") return "female";
  if (value === "Male masseur" || value === "Male therapist") return "male";
  return "none";
}
function anyGenderPreference() { return state.guests.some((guest) => preferenceCode(guest.therapist) !== "none"); }
function therapistSelectionAllowed() { return selectedOutlet()?.customer_therapist_selection_allowed !== false; }
function allocationsPayload() {
  return state.guests.map((guest, index) => ({
    guest_index: index + 1,
    guest_name: guestLabel(guest, index),
    catalogue_id: guest.serviceId,
    therapist_preference: preferenceCode(guest.therapist),
    therapist_request: guest.therapistRequest,
  }));
}

function showNotice(message, isError = false) {
  let notice = document.querySelector(".booking-mode-notice");
  if (!notice) {
    notice = document.createElement("p");
    notice.className = "booking-mode-notice";
    document.querySelector(".mobile-progress").before(notice);
  }
  notice.textContent = message;
  notice.classList.toggle("is-error", isError);
}
function clearNotice() { document.querySelector(".booking-mode-notice")?.remove(); }

async function loadOutlets() {
  const loading = document.querySelector("#outlet-loading");
  if (!api.configured) {
    document.querySelectorAll("[data-outlet]").forEach((button) => { button.hidden = false; });
    if (loading) loading.hidden = true;
    showNotice("Preview mode: configure Supabase to use live availability.");
    return;
  }
  try {
    const payload = await api.getOutlets();
    const availableCodes = new Set();
    for (const outlet of payload.outlets || []) {
      if (!outlets[outlet.code]) continue;
      availableCodes.add(outlet.code);
      outlets[outlet.code] = { ...outlets[outlet.code], ...outlet, name: outlets[outlet.code].name };
    }
    document.querySelectorAll("[data-outlet]").forEach((button) => {
      button.hidden = !availableCodes.has(button.dataset.outlet);
      renderOutletHours(button, outlets[button.dataset.outlet]);
    });
    if (state.outlet && !availableCodes.has(state.outlet)) state.outlet = null;
    if (!availableCodes.size) showNotice("Online booking is not currently enabled for any outlet.", true);
    else clearNotice();
  } catch (error) {
    document.querySelectorAll("[data-outlet]").forEach((button) => { button.hidden = true; });
    showNotice(error.message || "Unable to connect to the booking service.", true);
  } finally {
    if (loading) loading.hidden = true;
  }
}

function fallbackImageFor(service) {
  const name = String(service.name || "").toLowerCase();
  if (name.includes("foot")) return "./pics/best_footmassage2.jpg";
  if (name.includes("aroma") || name.includes("oil")) return "./pics/best_oilmassage.jpg";
  if (name.includes("combo") || name.includes("package")) return "./pics/best_combo.jpg";
  return "./pics/beauty-spa-hero-1280.jpg";
}

function resetAvailability() {
  dateRequestSerial += 1;
  state.loadingDates = false;
  state.date = null;
  state.time = null;
  state.dates = [];
  state.datesKey = "";
  state.slots = [];
  availabilityLoadError = "";
  renderDates();
  renderTimes();
}

async function loadServices({ preserveBooking = false } = {}) {
  if (!preserveBooking) {
    state.guests.forEach((guest) => { guest.serviceId = null; });
    resetAvailability();
  }
  serviceLoadError = "";
  state.loadingServices = true;
  renderServices();
  updateUi();
  if (!api.configured) {
    services = [];
    serviceLoadError = "Online booking is not configured.";
    state.loadingServices = false;
    renderServices();
    updateUi();
    return;
  }
  try {
    const payload = await api.getCatalogue(state.outlet);
    services = (payload.services || []).map((service) => ({
      id: service.catalogue_id,
      name: service.public_name,
      description: service.short_description || "",
      duration: Number(service.duration_minutes || 0),
      price: service.display_price == null ? null : Number(service.display_price),
      showPrice: Boolean(service.show_price),
      image: service.public_image_url || fallbackImageFor(service),
    }));
    const validIds = new Set(services.map((service) => service.id));
    state.guests.forEach((guest) => {
      if (guest.serviceId && !validIds.has(guest.serviceId)) guest.serviceId = null;
    });
    if (!services.length) serviceLoadError = "No online treatments are available for this outlet yet.";
    clearNotice();
  } catch (error) {
    services = [];
    serviceLoadError = error.message || "Unable to load treatments.";
  } finally {
    state.loadingServices = false;
    renderServices();
    renderGuestUi();
    updateUi();
  }
}

function renderGuestTabs(containerId, activeIndex) {
  const container = document.querySelector(containerId);
  container.innerHTML = state.guests.map((guest, index) => {
    const complete = Boolean(guest.serviceId);
    return `<button type="button" role="tab" aria-selected="${index === activeIndex}" class="guest-tab ${index === activeIndex ? "is-active" : ""} ${complete ? "is-complete" : ""}" data-guest-index="${index}"><span>${complete ? "&#10003;" : index + 1}</span>${escapeHtml(guestLabel(guest, index))}</button>`;
  }).join("");
  container.querySelectorAll("[data-guest-index]").forEach((button) => {
    button.addEventListener("click", () => {
      state.treatmentGuest = Number(button.dataset.guestIndex);
      renderServices();
    });
  });
}

function masseurFeasibility() {
  const outlet = selectedOutlet();
  if (!outlet || outlet.female_masseurs == null) return { ok: true, message: "" };
  const counts = { female: Number(outlet.female_masseurs), male: Number(outlet.male_masseurs), total: Number(outlet.total_masseurs) };
  const wanted = { female: 0, male: 0 };
  state.guests.forEach((guest) => {
    const code = preferenceCode(guest.therapist);
    if (code !== "none") wanted[code] += 1;
  });
  const overLimit = (gender, label) => {
    if (wanted[gender] <= counts[gender]) return null;
    if (counts[gender] === 0) return `No ${label} masseurs are available at this outlet. Please choose "No preference" instead.`;
    return `Only ${counts[gender]} ${label} masseur${counts[gender] === 1 ? " works" : "s work"} at this outlet, so at most ${counts[gender]} guest${counts[gender] === 1 ? "" : "s"} can choose ${label === "female" ? "Female" : "Male"}. Please set the others to "No preference".`;
  };
  const message = overLimit("female", "female") || overLimit("male", "male");
  if (message) return { ok: false, message };
  if (state.guests.length > counts.total) {
    return { ok: false, message: `This outlet can host at most ${counts.total} guests at one time.` };
  }
  return { ok: true, message: "" };
}

function renderPaxPicker() {
  const picker = document.querySelector("#pax-picker");
  picker.innerHTML = Array.from({ length: MAX_GUESTS }, (_, index) => {
    const count = index + 1;
    const selected = state.guests.length === count;
    return `<button type="button" role="radio" aria-checked="${selected}" class="pax-option ${selected ? "is-selected" : ""}" data-pax="${count}"><strong>${count}</strong><small>${count === 1 ? "guest" : "guests"}</small></button>`;
  }).join("");
  picker.querySelectorAll("[data-pax]").forEach((button) => {
    button.addEventListener("click", () => setGuestCount(Number(button.dataset.pax)));
  });
}

function setGuestCount(count) {
  const next = Math.min(MAX_GUESTS, Math.max(1, count));
  if (next === state.guests.length) return;
  while (state.guests.length < next) {
    const guest = newGuest(state.guests.length);
    if (sameForAll.treatment) guest.serviceId = state.guests[0]?.serviceId ?? null;
    state.guests.push(guest);
  }
  state.guests.length = next;
  state.treatmentGuest = Math.min(state.treatmentGuest, next - 1);
  resetAvailability();
  renderGuestUi();
  renderServices();
  updateUi();
}

function renderGuestUi() {
  renderPaxPicker();
  document.querySelector("#pax-hint").textContent = state.guests.length === 1
    ? ""
    : "Groups share one visit time — every guest starts together.";
  const allowPref = therapistSelectionAllowed();
  const prefOptions = ["No preference", "Female masseur", "Male masseur"];
  const prefShort = { "No preference": "No preference", "Female masseur": "Female", "Male masseur": "Male" };
  const preview = document.querySelector("#guest-preview");
  document.querySelector("#guest-names").hidden = false;
  preview.innerHTML = state.guests.map((guest, index) => {
    const prefField = allowPref
      ? `<div class="guest-card-fields">
          <div class="guest-field" role="group" aria-label="Preferred masseur gender for guest ${index + 1}">
            <span>Preferred masseur gender</span>
            <div class="guest-pref">${prefOptions.map((pref) =>
              `<button type="button" class="pref-chip ${guest.therapist === pref ? "is-selected" : ""}" data-guest-pref="${index}" data-pref-value="${escapeHtml(pref)}" aria-pressed="${guest.therapist === pref}">${prefShort[pref]}</button>`).join("")}</div>
          </div>
        </div>`
      : "";
    return `<div class="guest-card">
      <header class="guest-card-head"><b>${index + 1}</b><h4>Guest ${index + 1}</h4></header>
      ${prefField}
    </div>`;
  }).join("");
  preview.querySelectorAll("[data-guest-pref]").forEach((button) => {
    button.addEventListener("click", () => {
      const guest = state.guests[Number(button.dataset.guestPref)];
      if (!guest) return;
      guest.therapist = button.dataset.prefValue;
      resetAvailability();
      renderGuestUi();
      updateUi();
    });
  });
  renderGuestTabs("#treatment-guest-tabs", state.treatmentGuest);
  const feasibility = masseurFeasibility();
  const warning = document.querySelector("#preference-warning");
  const newlyShown = warning.hidden && !feasibility.ok;
  warning.hidden = feasibility.ok;
  warning.textContent = feasibility.message;
  if (newlyShown) warning.scrollIntoView({ behavior: "smooth", block: "center" });
}

function renderServices() {
  const container = document.querySelector("#service-options");
  if (sameForAll.treatment) state.treatmentGuest = 0;
  const guest = state.guests[state.treatmentGuest];
  const multi = state.guests.length > 1;
  const heading = document.querySelector("#treatment-guest-heading");
  heading.hidden = !multi || sameForAll.treatment;
  heading.textContent = guest && multi && !sameForAll.treatment ? `Selecting for ${guestLabel(guest, state.treatmentGuest)}` : "";
  document.querySelector("#same-treatment-row").hidden = !multi;
  document.querySelector("#same-treatment-checkbox").checked = sameForAll.treatment;
  const tabs = document.querySelector("#treatment-guest-tabs");
  tabs.hidden = !multi || sameForAll.treatment;
  if (!tabs.hidden) renderGuestTabs("#treatment-guest-tabs", state.treatmentGuest);
  if (state.loadingServices) { container.innerHTML = '<p class="booking-feedback">Loading treatments...</p>'; return; }
  if (serviceLoadError) { container.innerHTML = `<p class="booking-feedback is-error">${escapeHtml(serviceLoadError)}</p>`; return; }
  container.innerHTML = services.map((service) => {
    const selected = guest?.serviceId === service.id;
    return `<article class="service-card ${selected ? "is-selected" : ""}">
      <img src="${escapeHtml(service.image)}" alt="${escapeHtml(service.name)}" />
      <div class="service-copy"><h3>${escapeHtml(service.name)}</h3><p>${escapeHtml(service.description)}</p><span>${service.duration} minutes</span></div>
      <div class="service-action"><strong>${service.showPrice ? `${money(service.price)}<small class="nett">NETT</small>` : "Price on request"}</strong><button class="add-service" type="button" data-service="${escapeHtml(service.id)}" aria-pressed="${selected}">${selected ? "Selected" : "Select"}</button></div>
    </article>`;
  }).join("");
  container.querySelectorAll("[data-service]").forEach((button) => {
    button.addEventListener("click", () => {
      if (sameForAll.treatment) state.guests.forEach((item) => { item.serviceId = button.dataset.service; });
      else guest.serviceId = button.dataset.service;
      resetAvailability();
      renderServices();
      renderGuestUi();
      updateUi();
      if (!sameForAll.treatment && state.guests.length > 1) {
        const nextMissing = state.guests.findIndex((item, index) => index > state.treatmentGuest && !item.serviceId);
        if (nextMissing >= 0) { state.treatmentGuest = nextMissing; setTimeout(renderServices, 170); }
      }
    });
  });
}

function preferenceHint() {
  if (state.guests.length > 1 && anyGenderPreference()) {
    return " This can happen when there aren't enough masseurs matching everyone's preference — try \"No preference\" for some guests.";
  }
  return "";
}

function renderDates() {
  const container = document.querySelector("#date-options");
  const note = document.querySelector(".availability-note");
  if (state.loadingDates) {
    container.innerHTML = '<p class="booking-feedback">Checking the group\'s schedule...</p>';
    if (note) note.textContent = "Loading the outlet's booking dates.";
    return;
  }
  if (availabilityLoadError && !state.dates.length) {
    container.innerHTML = '<p class="booking-feedback is-error">We could not check available dates. Please try again.</p>';
    if (note) note.textContent = "";
    return;
  }
  if (!state.dates.length) {
    container.innerHTML = `<p class="booking-feedback">${allTreatmentsChosen() ? "No booking dates are available for the whole group." : "Choose a treatment for every guest first."}</p>`;
    if (note) note.textContent = "Choose a date to check exact times for the whole group.";
    return;
  }
  if (!state.dates.some((item) => item.available)) {
    container.innerHTML = `<p class="booking-feedback">No upcoming date can fit the whole group.${preferenceHint()}</p>`;
    if (note) note.textContent = "";
    return;
  }
  if (note) note.textContent = "Choose a date to check exact times for the whole group.";
  const weekday = new Intl.DateTimeFormat("en-MY", { weekday: "short" });
  const month = new Intl.DateTimeFormat("en-MY", { month: "short" });
  container.innerHTML = state.dates.map((item) => {
    const key = item.booking_date;
    const date = new Date(`${key}T12:00:00+08:00`);
    const label = date.toLocaleDateString("en-MY", { weekday: "short", day: "numeric", month: "short" });
    return `<button class="date-button ${state.date === key ? "is-selected" : ""}" type="button" data-date="${key}" data-date-label="${escapeHtml(label)}" ${item.available ? "" : "disabled"}><small>${weekday.format(date)}</small><strong>${date.getDate()}</strong><small>${month.format(date)}</small></button>`;
  }).join("");
  container.querySelectorAll("[data-date]").forEach((button) => button.addEventListener("click", async () => {
    state.date = button.dataset.date;
    state.time = null;
    renderDates();
    await loadAvailability();
    updateUi();
  }));
}

async function loadDates() {
  if (state.loadingDates) return;
  const allocations = allocationsPayload();
  const datesKey = JSON.stringify(allocations);
  if (state.datesKey === datesKey && state.dates.length) return;
  resetAvailability();
  if (!allTreatmentsChosen() || !api.configured) return;
  const requestId = dateRequestSerial;
  state.loadingDates = true;
  renderDates();
  updateUi();
  try {
    const payload = await api.getGroupDates({ allocations });
    if (requestId !== dateRequestSerial) return;
    state.dates = payload.dates || [];
    state.datesKey = datesKey;
  } catch (error) {
    if (requestId !== dateRequestSerial) return;
    availabilityLoadError = error.message || "Unable to load booking dates.";
  } finally {
    if (requestId === dateRequestSerial) {
      state.loadingDates = false;
      renderDates();
      renderTimes();
      updateUi();
    }
  }
}

function timeLabel(iso) {
  return new Intl.DateTimeFormat("en-MY", { hour: "numeric", minute: "2-digit", hour12: true, timeZone: "Asia/Kuala_Lumpur" }).format(new Date(iso));
}
function timePeriod(iso) {
  const hour = Number(new Intl.DateTimeFormat("en-MY", { hour: "2-digit", hourCycle: "h23", timeZone: "Asia/Kuala_Lumpur" }).format(new Date(iso)));
  return hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : "Evening";
}

async function loadAvailability() {
  state.time = null;
  state.slots = [];
  availabilityLoadError = "";
  if (!state.date || !allTreatmentsChosen()) { renderTimes(); return; }
  state.loadingTimes = true;
  renderTimes();
  try {
    const payload = await api.getGroupTimes({ date: state.date, allocations: allocationsPayload() });
    state.slots = (payload.slots || []).map((slot) => ({ startAt: slot.start_at, endAt: slot.end_at, status: slot.status || "available" }));
    clearNotice();
  } catch (error) {
    availabilityLoadError = error.message || "Unable to check live availability.";
    showNotice(availabilityLoadError, true);
  } finally {
    state.loadingTimes = false;
    renderTimes();
    updateUi();
  }
}

function renderTimes() {
  const container = document.querySelector("#time-options");
  if (!state.date) { container.innerHTML = '<p class="booking-feedback">Choose a date to see times available for everyone.</p>'; return; }
  if (state.loadingTimes) { container.innerHTML = '<p class="booking-feedback">Checking the group schedule...</p>'; return; }
  if (availabilityLoadError) { container.innerHTML = '<p class="booking-feedback is-error">We could not check availability. Please try again shortly.</p>'; return; }
  if (!state.slots.length) { container.innerHTML = `<p class="booking-feedback">No shared times are available for this date. Please choose another date.${preferenceHint()}</p>`; return; }
  const groups = new Map();
  state.slots.forEach((slot, index) => {
    const period = timePeriod(slot.startAt);
    if (!groups.has(period)) groups.set(period, []);
    groups.get(period).push({ ...slot, index });
  });
  const statusClass = (status) => status === "full" ? "is-full" : status === "selling_fast" ? "is-selling" : "is-available";
  container.innerHTML = [...groups.entries()].map(([label, slots]) => `<div class="time-group"><span>${label}</span><div class="time-button-grid">${slots.map((slot) => {
    const full = slot.status === "full";
    const classes = ["time-button", statusClass(slot.status)];
    if (state.time?.startAt === slot.startAt && !full) classes.push("is-selected");
    return `<button class="${classes.join(" ")}" type="button" data-slot-index="${slot.index}"${full ? " disabled aria-disabled=\"true\"" : ""}>${escapeHtml(timeLabel(slot.startAt))}</button>`;
  }).join("")}</div></div>`).join("");
  container.querySelectorAll("[data-slot-index]:not([disabled])").forEach((button) => button.addEventListener("click", () => {
    state.time = state.slots[Number(button.dataset.slotIndex)];
    renderTimes();
    updateUi();
  }));
}

function canContinue() {
  if (state.step === 1) return Boolean(state.outlet);
  if (state.step === 2) return state.guests.length > 0 && masseurFeasibility().ok;
  if (state.step === 3) return allTreatmentsChosen() && !state.loadingServices && !state.loadingDates;
  if (state.step === 4) return Boolean(state.date && state.time) && !state.loadingTimes;
  if (state.step === 5) return detailsForm.checkValidity();
  return false;
}

function setContinueLabel() {
  const missingTreatments = state.guests.filter((guest) => !guest.serviceId).length;
  const labels = ["Continue to guests", "Continue to treatments", "See available times", "Continue to billing"];
  let label = state.step === 5
    ? (state.hold?.token ? "Continue to secure payment" : "Reserve and pay")
    : labels[state.step - 1];
  if (state.step === 3 && missingTreatments) {
    label = `Choose ${missingTreatments} more treatment${missingTreatments === 1 ? "" : "s"}`;
  } else if (state.step === 3 && state.loadingDates) {
    label = "Checking availability...";
  }
  nextButton.innerHTML = `${label} <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6" /></svg>`;
}

function showStep(step) {
  state.step = Math.min(5, Math.max(1, step));
  panels.forEach((panel) => { const active = Number(panel.dataset.panel) === state.step; panel.hidden = !active; panel.classList.toggle("is-active", active); });
  steps.forEach((button, index) => {
    const number = index + 1;
    button.classList.toggle("is-active", number === state.step);
    button.classList.toggle("is-complete", number < state.step);
    button.disabled = number > state.step;
  });
  if (state.step === 3) renderServices();
  backButton.hidden = state.step === 1;
  setContinueLabel();
  updateUi();
  const target = window.matchMedia("(max-width: 680px)").matches ? document.querySelector(".mobile-progress") : document.querySelector(".stepper");
  target.scrollIntoView({ behavior: "smooth", block: "start" });
}

function updateReview() {
  document.querySelector("#review-outlet").textContent = selectedOutlet()?.name || "-";
  document.querySelector("#review-guests").textContent = `${state.guests.length} guest${state.guests.length === 1 ? "" : "s"}`;
  const selectedDateButton = document.querySelector(`[data-date="${state.date}"]`);
  document.querySelector("#review-datetime").textContent = state.date && state.time ? `${selectedDateButton?.dataset.dateLabel || state.date}, ${timeLabel(state.time.startAt)}` : "-";
  document.querySelector("#review-guest-list").innerHTML = state.guests.map((guest, index) => {
    const service = serviceById(guest.serviceId);
    const treatment = service
      ? `${escapeHtml(service.name)} · ${service.duration} min`
      : '<em>Treatment not chosen yet</em>';
    return `<article class="review-guest">
      <header><span>${index + 1}</span><b>${escapeHtml(guestLabel(guest, index))}</b><strong>${service?.showPrice ? money(service.price) : service ? "Ask outlet" : "&mdash;"}</strong></header>
      <p class="review-guest-service">${treatment}</p>
      <p class="review-guest-pref">${escapeHtml(guest.therapist || "No preference")}</p>
    </article>`;
  }).join("");
  document.querySelector("#review-duration").textContent = `${visitDuration()} minutes`;
  const hasHiddenPrice = selectedServices().some((service) => !service.showPrice);
  document.querySelector("#review-total").textContent = hasHiddenPrice ? "Price on request" : money(totalPrice());
  const configured = state.guests.filter((guest) => guest.serviceId).length;
  document.querySelector("#mobile-summary-caption").textContent = !state.outlet ? "Choose an outlet" : `${configured}/${state.guests.length} guests ready`;
  document.querySelector("#mobile-summary-total").textContent = hasHiddenPrice ? "Ask outlet" : money(totalPrice());
}

function updateProgress() {
  document.querySelector("#mobile-step-label").textContent = stepNames[state.step - 1];
  document.querySelector("#mobile-step-count").textContent = `Step ${state.step} of ${stepNames.length}`;
  document.querySelectorAll("[data-progress-dot]").forEach((dot, index) => {
    dot.classList.toggle("is-complete", index + 1 < state.step);
    dot.classList.toggle("is-current", index + 1 === state.step);
  });
}
function updateUi() {
  nextButton.disabled = !canContinue();
  setContinueLabel();
  updateReview();
  updateProgress();
  persistBookingSession();
}

function openSummary() { summarySheet.classList.add("is-open"); summaryOverlay.classList.add("is-open"); summaryToggle.setAttribute("aria-expanded", "true"); document.body.classList.add("summary-open"); summaryClose.focus(); }
function closeSummary() { summarySheet.classList.remove("is-open"); summaryOverlay.classList.remove("is-open"); summaryToggle.setAttribute("aria-expanded", "false"); document.body.classList.remove("summary-open"); }

function showConfirmation({ preview = false, hold = null } = {}) {
  const eyebrow = document.querySelector("#confirmation-eyebrow");
  const title = document.querySelector("#confirmation-title");
  const message = document.querySelector("#confirmation-message");
  if (preview) {
    eyebrow.textContent = "Preview mode"; title.textContent = "The group booking form is ready."; message.textContent = "Configure Supabase to create a real hold. No appointment or payment was created.";
  } else if (state.appointment) {
    eyebrow.textContent = "Booking confirmed"; title.textContent = "Your appointment is booked."; message.textContent = `Reference ${String(hold.token).slice(0, 8).toUpperCase()}. We look forward to seeing you.`;
  }
  document.querySelector("#confirmation-dialog").showModal();
}

function holdRemainingMs() {
  if (!state.hold?.expires_at) return 0;
  return Math.max(0, new Date(state.hold.expires_at).getTime() - Date.now());
}

function deadlineTimeLabel() {
  return new Date(state.hold.expires_at).toLocaleTimeString("en-MY", {
    hour: "numeric",
    minute: "2-digit",
  });
}

function renderHoldCountdown() {
  if (!state.hold?.token) {
    paymentDeadline.hidden = true;
    return 0;
  }
  const remaining = holdRemainingMs();
  const totalSeconds = Math.ceil(remaining / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  document.querySelector("#payment-deadline-title").textContent =
    `Complete payment by ${deadlineTimeLabel()}`;
  document.querySelector("#payment-deadline-copy").textContent =
    "Your booking will be cancelled if payment is not completed before this deadline.";
  paymentCountdown.textContent = `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  paymentDeadline.hidden = false;
  paymentDeadline.classList.toggle("is-urgent", remaining <= 120000);
  return remaining;
}

function showPaymentHandoff() {
  const dialog = document.querySelector("#confirmation-dialog");
  const close = document.querySelector("#close-dialog");
  dialog.dataset.paymentState = "handoff";
  setDialogIcon("pending");
  document.querySelector("#confirmation-title").textContent = "Continue to secure payment";
  document.querySelector("#confirmation-message").textContent =
    `Please complete payment by ${deadlineTimeLabel()}. Your appointment is only confirmed after a successful payment.`;
  close.style.display = "";
  close.textContent = "Continue to Payment";
  close.dataset.action = "pay";
  if (!dialog.open) dialog.showModal();
}

function showHoldExpired() {
  const dialog = document.querySelector("#confirmation-dialog");
  const close = document.querySelector("#close-dialog");
  dialog.dataset.paymentState = "expired";
  setDialogIcon("failed");
  document.querySelector("#confirmation-eyebrow").textContent = "Payment deadline expired";
  document.querySelector("#confirmation-title").textContent = "Your selected time is no longer reserved.";
  document.querySelector("#confirmation-message").textContent =
    "Please choose an available time and create a new payment reservation. Your contact details have been kept for convenience.";
  close.style.display = "";
  close.textContent = "Choose another time";
  close.dataset.action = "availability";
  if (!dialog.open) dialog.showModal();
}

async function expireActiveHold() {
  if (!state.hold?.token || holdExpiryInProgress) return;
  holdExpiryInProgress = true;
  const token = state.hold.token;
  try {
    await api.expireHold(token);
  } catch (_) {
    // The server and scheduled cleanup remain authoritative. The local session
    // must stop offering payment as soon as its server-issued deadline passes.
  }
  clearActiveHold();
  state.time = null;
  updateUi();
  showHoldExpired();
}

function startHoldCountdown() {
  if (holdCountdownTimer) clearInterval(holdCountdownTimer);
  holdCountdownTimer = null;
  if (!state.hold?.token) return;
  if (renderHoldCountdown() <= 0) {
    expireActiveHold();
    return;
  }
  holdCountdownTimer = setInterval(() => {
    if (renderHoldCountdown() <= 0) expireActiveHold();
  }, 1000);
}

let paymentPollTimer = null;
let paymentPollAttempts = 0;
const PAYMENT_POLL_INTERVAL_MS = 2000;
const PAYMENT_POLL_MAX_ATTEMPTS = 60;
function setDialogIcon(kind) {
  const mark = document.querySelector(".success-mark");
  mark.classList.remove("is-pending", "is-failed");
  if (kind === "pending") { mark.classList.add("is-pending"); mark.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 3" /></svg>'; }
  else if (kind === "failed") { mark.classList.add("is-failed"); mark.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 8l8 8M16 8l-8 8" /></svg>'; }
  else mark.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m7 12 3 3 7-7" /></svg>';
}
function showPaymentStatus(kind, { reference = "" } = {}) {
  const dialog = document.querySelector("#confirmation-dialog");
  const eyebrow = document.querySelector("#confirmation-eyebrow");
  const title = document.querySelector("#confirmation-title");
  const message = document.querySelector("#confirmation-message");
  const close = document.querySelector("#close-dialog");
  dialog.dataset.paymentState = kind;
  close.style.display = kind === "checking" ? "none" : "";
  if (kind === "checking") { setDialogIcon("pending"); eyebrow.textContent = "Confirming your payment"; title.textContent = "Just a moment..."; message.textContent = "We're confirming your booking."; }
  else if (kind === "confirmed") { setDialogIcon("success"); eyebrow.textContent = "Booking confirmed"; title.textContent = "Your booking is confirmed."; message.textContent = `Payment received${reference ? ` - reference ${reference}` : ""}`; close.textContent = "Done"; close.dataset.action = "home"; }
  else if (kind === "failed") { setDialogIcon("failed"); eyebrow.textContent = "Payment not completed"; title.textContent = "We couldn't confirm your booking."; message.textContent = "Your booking was unsuccessful. Please try again."; close.textContent = "Try booking again"; close.dataset.action = "retry"; }
  else { setDialogIcon("pending"); eyebrow.textContent = "Still confirming"; title.textContent = "This is taking longer than expected."; message.textContent = "Your payment may still be processing."; close.textContent = "Check again"; close.dataset.action = "recheck"; }
  if (!dialog.open) dialog.showModal();
}
function stopPaymentPoll() { if (paymentPollTimer) clearTimeout(paymentPollTimer); paymentPollTimer = null; }
async function pollPaymentStatus(token) {
  stopPaymentPoll(); paymentPollAttempts += 1;
  try {
    const payload = await api.getHoldStatus(token);
    if (payload.hold?.status === "confirmed") {
      // Same receipt number the app shows for this booking's transaction; falls
      // back to the hold's own reference only if the webhook hasn't landed yet.
      const reference = payload.hold.receipt_number || String(token).slice(0, 8).toUpperCase();
      try { sessionStorage.removeItem(BOOKING_SESSION_KEY); } catch (_) { /* Optional browser storage. */ }
      showPaymentStatus("confirmed", { reference });
      return;
    }
    if (["payment_failed", "cancelled", "expired"].includes(payload.hold?.status)) { showPaymentStatus("failed"); return; }
  } catch (_) { /* Retry transient failures. */ }
  if (paymentPollAttempts >= PAYMENT_POLL_MAX_ATTEMPTS) { showPaymentStatus("timeout"); return; }
  paymentPollTimer = setTimeout(() => pollPaymentStatus(token), PAYMENT_POLL_INTERVAL_MS);
}
function initializePaymentReturn() {
  const token = new URLSearchParams(window.location.search).get("bp_token");
  if (!token) return false;
  document.querySelector(".booking-shell").style.display = "none";
  paymentPollAttempts = 0; showPaymentStatus("checking"); pollPaymentStatus(token); return true;
}

async function redirectActivePayment() {
  if (!state.hold?.token) return;
  if (holdRemainingMs() <= 0) {
    await expireActiveHold();
    return;
  }
  nextButton.disabled = true;
  nextButton.textContent = "Opening secure payment...";
  try {
    if (!state.paymentUrl) {
      const pay = await api.payHold(state.hold.token);
      state.paymentUrl = pay.url;
    }
    persistBookingSession();
    window.location.assign(state.paymentUrl);
  } catch (error) {
    if (error.status === 409) {
      await expireActiveHold();
      return;
    }
    showNotice(error.message || "Unable to open payment. Please try again.", true);
    setContinueLabel();
    updateUi();
  }
}

async function submitHold() {
  if (!detailsForm.reportValidity() || !state.time) return;
  if (!api.configured) { showConfirmation({ preview: true }); return; }
  const form = new FormData(detailsForm);
  const fingerprint = currentBookingFingerprint(form);
  nextButton.disabled = true;
  nextButton.textContent = "Reserving your group...";
  try {
    if (state.hold?.token) {
      const payload = await api.getHoldStatus(state.hold.token);
      const status = payload?.hold?.status;
      const stillPending = status === "pending_payment" && holdRemainingMs() > 0;
      if (stillPending && fingerprint === state.holdFingerprint) {
        await redirectActivePayment();
        return;
      }
      if (status === "confirmed") {
        showPaymentStatus("confirmed", {
          reference: payload.hold.receipt_number || String(state.hold.token).slice(0, 8).toUpperCase(),
        });
        return;
      }
      if (stillPending || ["payment_failed", "cancelled"].includes(status)) {
        await api.cancelHold(state.hold.token);
      } else if (status === "expired" || holdRemainingMs() <= 0) {
        await api.expireHold(state.hold.token);
      }
      clearActiveHold();
    }

    const payload = await api.createGroupHold({
      allocations: allocationsPayload(), start_at: state.time.startAt,
      customer_name: form.get("name"), customer_phone: form.get("phone"), customer_email: form.get("email"),
      notes: form.get("notes"), website: form.get("website"),
    });
    state.hold = payload.hold;
    state.holdFingerprint = fingerprint;
    state.paymentUrl = "";
    state.appointment = null;
    let holdNoticeMessage = null;
    try {
      nextButton.textContent = "Preparing secure payment...";
      const pay = await api.payHold(payload.hold.token);
      state.paymentUrl = pay.url;
    } catch (payError) {
      if (window.BOOKING_CONFIG?.testAutoConfirm) {
        try { state.appointment = (await api.confirmHold(payload.hold.token)).appointment; }
        catch (error) { holdNoticeMessage = error.message || "The time was reserved, but automatic confirmation failed."; }
      } else {
        const reason = payError.message || "Unable to start payment.";
        holdNoticeMessage = `${reason} Your time remains reserved until ${deadlineTimeLabel()}. Select Continue to secure payment to try again.`;
      }
    }
    persistBookingSession();
    startHoldCountdown();
    if (holdNoticeMessage) showNotice(holdNoticeMessage, true); else clearNotice();
    if (state.paymentUrl) showPaymentHandoff();
    else if (state.appointment) showConfirmation({ hold: payload.hold });
  } catch (error) {
    showNotice(error.message || "Unable to reserve this group time.", true);
    if (error.status === 409) { state.time = null; await loadAvailability(); showStep(4); }
  } finally { setContinueLabel(); updateUi(); }
}

document.querySelectorAll("[data-outlet]").forEach((button) => button.addEventListener("click", async () => {
  state.outlet = button.dataset.outlet;
  if (!therapistSelectionAllowed()) state.guests.forEach((guest) => { guest.therapist = "No preference"; });
  document.querySelectorAll("[data-outlet]").forEach((option) => option.classList.toggle("is-selected", option === button));
  await loadServices();
  renderGuestUi();
  updateUi();
}));

document.querySelector("#same-treatment-checkbox").addEventListener("change", (event) => {
  sameForAll.treatment = event.target.checked;
  if (sameForAll.treatment) {
    const source = state.guests[state.treatmentGuest] || state.guests[0];
    state.guests.forEach((guest) => { guest.serviceId = source?.serviceId ?? null; });
    state.treatmentGuest = 0;
    resetAvailability();
  }
  renderServices(); renderGuestUi(); updateUi();
});
steps.forEach((button) => button.addEventListener("click", () => { const target = Number(button.dataset.stepTarget); if (target <= state.step) showStep(target); }));
nextButton.addEventListener("click", async () => {
  if (state.step === 5) { await submitHold(); return; }
  if (state.step === 3 && canContinue()) await loadDates();
  if (canContinue()) showStep(state.step + 1);
});
backButton.addEventListener("click", () => showStep(state.step - 1));
detailsForm.addEventListener("input", updateUi);
summaryToggle.addEventListener("click", openSummary);
summaryClose.addEventListener("click", closeSummary);
summaryOverlay.addEventListener("click", closeSummary);
document.addEventListener("keydown", (event) => { if (event.key === "Escape" && summarySheet.classList.contains("is-open")) { closeSummary(); summaryToggle.focus(); } });
window.addEventListener("resize", () => { if (window.innerWidth > 900 && summarySheet.classList.contains("is-open")) closeSummary(); });
document.querySelector("#close-dialog").addEventListener("click", () => {
  const close = document.querySelector("#close-dialog");
  if (close.dataset.action === "pay") {
    document.querySelector("#confirmation-dialog").close();
    redirectActivePayment();
    return;
  }
  if (close.dataset.action === "availability") {
    document.querySelector("#confirmation-dialog").close();
    showStep(4);
    loadAvailability();
    return;
  }
  if (close.dataset.action === "retry") { window.location.href = "./booking.html"; return; }
  if (close.dataset.action === "home") { window.location.href = "./index.html"; return; }
  if (close.dataset.action === "recheck") { const token = new URLSearchParams(window.location.search).get("bp_token"); if (token) { paymentPollAttempts = 0; showPaymentStatus("checking"); pollPaymentStatus(token); } return; }
  document.querySelector("#confirmation-dialog").close();
});
document.querySelector("#confirmation-dialog").addEventListener("cancel", (event) => { if (event.currentTarget.dataset.paymentState === "checking") event.preventDefault(); });
document.querySelector("#terms-link").addEventListener("click", (event) => {
  event.preventDefault();
  document.querySelector("#terms-dialog").showModal();
});
document.querySelector("#terms-dialog-close").addEventListener("click", () => {
  document.querySelector("#terms-dialog").close();
});

async function initializeBooking() {
  if (initializePaymentReturn()) return;
  const restored = restoreBookingSession();
  document.querySelectorAll("[data-outlet]").forEach((button) => renderOutletHours(button, outlets[button.dataset.outlet]));
  renderGuestUi(); renderServices(); renderDates(); renderTimes(); updateUi();
  await loadOutlets();
  if (state.outlet) {
    const selectedButton = document.querySelector(`[data-outlet="${state.outlet}"]`);
    if (selectedButton && !selectedButton.hidden) {
      document.querySelectorAll("[data-outlet]").forEach((button) => {
        button.classList.toggle("is-selected", button === selectedButton);
      });
      const savedDate = state.date;
      const savedTime = state.time;
      await loadServices({ preserveBooking: restored });
      if (restored && savedDate && allTreatmentsChosen()) {
        await loadDates();
        state.date = savedDate;
        await loadAvailability();
        state.time = state.slots.find((slot) => slot.startAt === savedTime?.startAt) || savedTime;
      }
      renderGuestUi();
      showStep(state.step);
    }
  }
  if (state.hold?.token) {
    try {
      const payload = await api.getHoldStatus(state.hold.token);
      if (payload?.hold?.status === "pending_payment" && holdRemainingMs() > 0) {
        startHoldCountdown();
      } else if (payload?.hold?.status === "confirmed") {
        showPaymentStatus("confirmed", {
          reference: payload.hold.receipt_number || String(state.hold.token).slice(0, 8).toUpperCase(),
        });
        clearActiveHold();
      } else {
        clearActiveHold();
      }
    } catch (error) {
      if (holdRemainingMs() > 0) {
        startHoldCountdown();
        showNotice("We could not refresh your payment status. Your existing reservation has been kept.", true);
      } else {
        await expireActiveHold();
      }
    }
  }
  updateUi();
}
initializeBooking();

window.addEventListener("pageshow", () => {
  if (state.hold?.token) startHoldCountdown();
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && state.hold?.token) startHoldCountdown();
});
