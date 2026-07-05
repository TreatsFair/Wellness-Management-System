const fallbackOutlets = {
  "taman-wahyu": {
    id: "00000000-0000-0000-0000-000000000002",
    name: "Kepong · Taman Wahyu",
    phone: "60125262551",
    priceOffset: 0,
  },
  pv128: {
    id: "00000000-0000-0000-0000-000000000128",
    name: "Setapak · PV128",
    phone: "60127449266",
    priceOffset: 10,
  },
};

const fallbackServices = [
  {
    id: "foot",
    name: "Foot Reflexology",
    description: "Herbal foot soak followed by focused reflexology to ease tired feet.",
    duration: 60,
    price: 88,
    image: "./pics/best_footmassage2.jpg",
    more: "A restorative lower-leg and foot treatment designed for tired feet and everyday tension.",
    includes: ["Complimentary herbal foot soak", "Foot and lower-leg pressure massage", "Reflexology pressure points", "Relaxation and circulation support"],
  },
  {
    id: "thai",
    name: "Thai Body Massage",
    description: "Traditional stretches and pressure work to restore movement and release tension.",
    duration: 60,
    price: 88,
    image: "./pics/beauty-spa.jpg",
    more: "An oil-free traditional treatment combining rhythmic pressure and assisted stretching.",
    includes: ["Traditional Thai acupressure", "Gentle assisted stretches", "Back, shoulder and leg focus", "Flexibility and tension relief"],
  },
  {
    id: "aroma",
    name: "Aroma Oil Body Massage",
    description: "A soothing full-body ritual with aromatic oils for deep relaxation.",
    duration: 60,
    price: 99,
    image: "./pics/best_oilmassage.jpg",
    more: "A calming full-body treatment using aromatic oil and flowing massage techniques.",
    includes: ["Aromatic massage oil", "Full-body massage", "Custom pressure request", "Stress and muscle relaxation"],
  },
  {
    id: "combo",
    name: "Foot & Aroma Oil Combo",
    description: "Our signature foot reflexology and aroma body treatment in one restorative visit.",
    duration: 90,
    price: 138,
    image: "./pics/best_combo.jpg",
    more: "A longer signature ritual that combines focused foot care with a relaxing aroma body massage.",
    includes: ["Complimentary herbal foot soak", "Foot reflexology", "Aroma oil body massage", "Extended head-to-toe relaxation"],
  },
];

const api = window.BookingApi;
const outlets = JSON.parse(JSON.stringify(fallbackOutlets));
let services = [];
let serviceLoadError = "";
let availabilityLoadError = "";

const state = {
  step: 1,
  outlet: null,
  services: new Set(),
  therapist: null,
  date: null,
  time: null,
  slots: [],
  dates: [],
  loadingServices: false,
  loadingTimes: false,
  hold: null,
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
const stepNames = ["Outlet", "Treatment", "Therapist", "Date & time", "Details"];

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function money(value) {
  return `RM ${Number(value || 0).toFixed(0)}`;
}

function localDateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function selectedOutlet() {
  return state.outlet ? outlets[state.outlet] : null;
}

function therapistSelectionAllowed() {
  return selectedOutlet()?.customer_therapist_selection_allowed !== false;
}

function selectedServices() {
  return services.filter((service) => state.services.has(service.id));
}

function totalPrice() {
  return selectedServices().reduce((sum, service) => sum + Number(service.price || 0), 0);
}

function totalDuration() {
  return selectedServices().reduce((sum, service) => sum + service.duration, 0);
}

function preferenceCode() {
  if (state.therapist === "Female therapist") return "female";
  if (state.therapist === "Male therapist") return "male";
  return "none";
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

function clearNotice() {
  document.querySelector(".booking-mode-notice")?.remove();
}

async function loadOutlets() {
  if (!api.configured) {
    showNotice("Preview mode: add your Supabase URL and publishable key in js/booking-config.js to use live availability.");
    return;
  }
  try {
    const payload = await api.getOutlets();
    const availableCodes = new Set();
    for (const outlet of payload.outlets || []) {
      if (!outlets[outlet.code]) continue;
      availableCodes.add(outlet.code);
      outlets[outlet.code] = {
        ...outlets[outlet.code],
        ...outlet,
        name: outlets[outlet.code].name,
        priceOffset: 0,
      };
    }
    document.querySelectorAll("[data-outlet]").forEach((button) => {
      button.hidden = !availableCodes.has(button.dataset.outlet);
    });
    if (availableCodes.size === 0) showNotice("Online booking is not currently enabled for any outlet.", true);
    else clearNotice();
  } catch (error) {
    showNotice(error.message || "Unable to connect to the booking service.", true);
  }
}

function fallbackImageFor(service) {
  const name = String(service.name || "").toLowerCase();
  if (name.includes("foot")) return "./pics/best_footmassage2.jpg";
  if (name.includes("aroma") || name.includes("oil")) return "./pics/best_oilmassage.jpg";
  if (name.includes("combo") || name.includes("package")) return "./pics/best_combo.jpg";
  return "./pics/beauty-spa.jpg";
}

async function loadServices() {
  state.services.clear();
  state.date = null;
  state.time = null;
  state.slots = [];
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
      image: service.public_image_url,
      more: service.short_description || "",
      includes: [],
    }));
    clearNotice();
    if (services.length === 0) serviceLoadError = "No online treatments are available for this outlet yet.";
  } catch (error) {
    services = [];
    serviceLoadError = error.message || "Unable to load treatments.";
  } finally {
    state.loadingServices = false;
    renderServices();
    updateUi();
  }
}

function renderServices() {
  const container = document.querySelector("#service-options");
  if (state.loadingServices) {
    container.innerHTML = '<p class="booking-feedback">Loading treatments…</p>';
    return;
  }
  if (serviceLoadError) {
    container.innerHTML = `<p class="booking-feedback is-error">${escapeHtml(serviceLoadError)}</p>`;
    return;
  }

  container.innerHTML = services.map((service) => {
    const selected = state.services.has(service.id);
    const details = service.more
      ? `<details class="service-more"><summary>More about this treatment</summary><p>${escapeHtml(service.more)}</p>${service.includes.length ? `<ul>${service.includes.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>` : ""}</details>`
      : "";
    return `
      <article class="service-card ${selected ? "is-selected" : ""}" data-service-card="${escapeHtml(service.id)}">
        <img src="${escapeHtml(service.image)}" alt="${escapeHtml(service.name)}" />
        <div class="service-copy">
          <h3>${escapeHtml(service.name)}</h3>
          <p>${escapeHtml(service.description)}</p>
          <span>${service.duration} minutes</span>
        </div>
        <div class="service-action">
          <strong>${service.showPrice ? money(service.price) : "Price on request"}</strong>
          <button class="add-service" type="button" data-service="${escapeHtml(service.id)}" aria-pressed="${selected}">${selected ? "Added" : "Add"}</button>
        </div>
        ${details}
      </article>`;
  }).join("");

  container.querySelectorAll("[data-service]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.service;
      if (state.services.has(id)) state.services.clear();
      else { state.services.clear(); state.services.add(id); }
      state.time = null;
      state.slots = [];
      state.dates = [];
      renderServices();
      if (state.services.size) await loadDates();
      updateUi();
    });
  });
}

function renderDates() {
  const dateContainer = document.querySelector("#date-options");
  const availabilityNote = document.querySelector(".availability-note");
  const formatter = new Intl.DateTimeFormat("en-MY", { weekday: "short" });
  const monthFormatter = new Intl.DateTimeFormat("en-MY", { month: "short" });
  if (!state.dates.length) {
    dateContainer.innerHTML = '<p class="booking-feedback">Select a treatment to see online booking dates.</p>';
    if (availabilityNote) availabilityNote.textContent = "Dates are loaded from the outlet’s online schedule.";
    return;
  }
  const hasAvailableDate = state.dates.some((item) => item.available);
  if (availabilityNote) {
    availabilityNote.textContent = hasAvailableDate
      ? "Choose an available date to see its half-hour start times."
      : "No online times are available in the next 7 days. Please try again later or contact the outlet.";
  }
  dateContainer.innerHTML = state.dates.map((item) => {
    const key = item.booking_date;
    const date = new Date(`${key}T12:00:00+08:00`);
    const label = date.toLocaleDateString("en-MY", { weekday: "short", day: "numeric", month: "short" });
    return `
      <button class="date-button ${state.date === key ? "is-selected" : ""}" type="button" data-date="${key}" data-date-label="${escapeHtml(label)}" ${item.available ? "" : 'disabled title="No online times available"'}>
        <small>${formatter.format(date)}</small>
        <strong>${date.getDate()}</strong>
        <small>${monthFormatter.format(date)}</small>
      </button>`;
  }).join("");

  dateContainer.querySelectorAll("[data-date]").forEach((button) => {
    button.addEventListener("click", async () => {
      state.date = button.dataset.date;
      state.time = null;
      renderDates();
      await loadAvailability();
      updateUi();
    });
  });
}

async function loadDates() {
  state.date = null;
  state.time = null;
  state.dates = [];
  state.slots = [];
  availabilityLoadError = "";
  const service = selectedServices()[0];
  if (!service || !api.configured) { renderDates(); renderTimes(); return; }
  try {
    const payload = await api.getDates({ catalogueId: service.id, preference: preferenceCode() });
    state.dates = payload.dates || [];
  } catch (error) {
    availabilityLoadError = error.message || "Unable to load booking dates.";
  }
  renderDates();
  renderTimes();
  updateUi();
}

function fallbackSlots() {
  const times = ["10:30", "11:00", "11:30", "12:00", "13:30", "14:00", "15:30", "16:30", "18:00", "19:00", "20:30", "21:00"];
  return times.map((time) => {
    const start = new Date(`${state.date}T${time}:00+08:00`);
    const end = new Date(start.getTime() + totalDuration() * 60000);
    return { startAt: start.toISOString(), endAt: end.toISOString(), availableCount: 1 };
  });
}

async function loadAvailability() {
  state.time = null;
  state.slots = [];
  availabilityLoadError = "";
  if (!state.date || !state.outlet || state.services.size === 0) {
    renderTimes();
    return;
  }

  state.loadingTimes = true;
  renderTimes();
  try {
    if (!api.configured) {
      state.slots = [];
    } else {
      const payload = await api.getTimes({
        catalogueId: selectedServices()[0].id,
        date: state.date,
        preference: preferenceCode(),
      });
      state.slots = (payload.slots || []).map((slot) => ({
        startAt: slot.start_at,
        endAt: slot.end_at,
      }));
      clearNotice();
    }
  } catch (error) {
    availabilityLoadError = error.message || "Unable to check live availability.";
    showNotice(availabilityLoadError, true);
  } finally {
    state.loadingTimes = false;
    renderTimes();
    updateUi();
  }
}

function timeLabel(iso) {
  return new Intl.DateTimeFormat("en-MY", {
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
    timeZone: "Asia/Kuala_Lumpur",
  }).format(new Date(iso));
}

function timePeriod(iso) {
  const hour = Number(new Intl.DateTimeFormat("en-MY", {
    hour: "2-digit",
    hourCycle: "h23",
    timeZone: "Asia/Kuala_Lumpur",
  }).format(new Date(iso)));
  if (hour < 12) return "Morning";
  if (hour < 17) return "Afternoon";
  return "Evening";
}

function renderTimes() {
  const container = document.querySelector("#time-options");
  if (!state.date) {
    container.innerHTML = '<p class="booking-feedback">Choose a date to see available times.</p>';
    return;
  }
  if (state.loadingTimes) {
    container.innerHTML = '<p class="booking-feedback">Checking live availability…</p>';
    return;
  }
  if (availabilityLoadError) {
    container.innerHTML = '<p class="booking-feedback is-error">We could not check live availability. Please try again shortly.</p>';
    return;
  }
  if (state.slots.length === 0) {
    container.innerHTML = '<p class="booking-feedback">No times are available for this date. Please choose another date.</p>';
    return;
  }

  const groups = new Map();
  state.slots.forEach((slot, index) => {
    const period = timePeriod(slot.startAt);
    if (!groups.has(period)) groups.set(period, []);
    groups.get(period).push({ ...slot, index });
  });

  container.innerHTML = [...groups.entries()].map(([label, slots]) => `
    <div class="time-group">
      <span>${label}</span>
      <div class="time-button-grid">
        ${slots.map((slot) => `<button class="time-button ${state.time?.startAt === slot.startAt ? "is-selected" : ""}" type="button" data-slot-index="${slot.index}">${escapeHtml(timeLabel(slot.startAt))}</button>`).join("")}
      </div>
    </div>`).join("");

  container.querySelectorAll("[data-slot-index]").forEach((button) => {
    button.addEventListener("click", () => {
      state.time = state.slots[Number(button.dataset.slotIndex)];
      renderTimes();
      updateUi();
    });
  });
}

function canContinue() {
  if (state.step === 1) return Boolean(state.outlet);
  if (state.step === 2) return state.services.size > 0 && !state.loadingServices;
  if (state.step === 3) return Boolean(state.therapist);
  if (state.step === 4) return Boolean(state.date && state.time) && !state.loadingTimes;
  if (state.step === 5) return detailsForm.checkValidity();
  return false;
}

function setContinueLabel() {
  nextButton.innerHTML = state.step === 5
    ? `Reserve for 15 minutes <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6" /></svg>`
    : `Continue <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6" /></svg>`;
}

function showStep(step) {
  state.step = Math.min(5, Math.max(1, step));
  panels.forEach((panel) => {
    const active = Number(panel.dataset.panel) === state.step;
    panel.hidden = !active;
    panel.classList.toggle("is-active", active);
  });
  steps.forEach((stepButton, index) => {
    const number = index + 1;
    stepButton.classList.toggle("is-active", number === state.step);
    stepButton.classList.toggle("is-complete", number < state.step);
    stepButton.disabled = number > state.step;
  });
  backButton.hidden = state.step === 1;
  setContinueLabel();
  updateUi();
  const target = window.matchMedia("(max-width: 680px)").matches
    ? document.querySelector(".mobile-progress")
    : document.querySelector(".stepper");
  target.scrollIntoView({ behavior: "smooth", block: "start" });
}

function updateUi() {
  nextButton.disabled = !canContinue();
  updateReview();
  updateProgress();
}

function updateReview() {
  const outlet = selectedOutlet()?.name || "—";
  const treatments = selectedServices().map((service) => service.name).join(", ") || "—";
  const selectedDateButton = document.querySelector(`[data-date="${state.date}"]`);
  const dateTime = state.date && state.time
    ? `${selectedDateButton?.dataset.dateLabel || state.date}, ${timeLabel(state.time.startAt)}`
    : "—";
  const request = document.querySelector("#therapist-comment")?.value.trim();
  const therapist = !state.therapist
    ? "—"
    : request
      ? `${state.therapist} · Request: ${request}`
      : state.therapist;

  document.querySelector("#review-outlet").textContent = outlet;
  document.querySelector("#review-services").textContent = treatments;
  document.querySelector("#review-datetime").textContent = dateTime;
  document.querySelector("#review-therapist").textContent = therapist;
  document.querySelector("#review-duration").textContent = `${totalDuration()} minutes`;
  const selected = selectedServices()[0];
  document.querySelector("#review-total").textContent = selected && !selected.showPrice ? "Price on request" : money(totalPrice());

  const count = selectedServices().length;
  const caption = !state.outlet
    ? "Choose an outlet"
    : count === 0
      ? selectedOutlet().name
      : `${count} treatment${count === 1 ? "" : "s"} · ${totalDuration()} min`;
  document.querySelector("#mobile-summary-caption").textContent = caption;
  document.querySelector("#mobile-summary-total").textContent = selected && !selected.showPrice ? "Price on request" : money(totalPrice());
}

function updateProgress() {
  document.querySelector("#mobile-step-label").textContent = stepNames[state.step - 1];
  document.querySelector("#mobile-step-count").textContent = `Step ${state.step} of ${stepNames.length}`;
  document.querySelectorAll("[data-progress-dot]").forEach((dot, index) => {
    const number = index + 1;
    dot.classList.toggle("is-complete", number < state.step);
    dot.classList.toggle("is-current", number === state.step);
  });
}

function openSummary() {
  summarySheet.classList.add("is-open");
  summaryOverlay.classList.add("is-open");
  summaryToggle.setAttribute("aria-expanded", "true");
  document.body.classList.add("summary-open");
  summaryClose.focus();
}

function closeSummary() {
  summarySheet.classList.remove("is-open");
  summaryOverlay.classList.remove("is-open");
  summaryToggle.setAttribute("aria-expanded", "false");
  document.body.classList.remove("summary-open");
}

function showConfirmation({ preview = false, hold = null } = {}) {
  const eyebrow = document.querySelector("#confirmation-eyebrow");
  const title = document.querySelector("#confirmation-title");
  const message = document.querySelector("#confirmation-message");
  if (preview) {
    eyebrow.textContent = "Preview mode";
    title.textContent = "The booking form is ready.";
    message.textContent = "Configure Supabase to create a real 15-minute hold. No appointment or payment was created.";
  } else {
    const expires = new Date(hold.expires_at).toLocaleTimeString("en-MY", { hour: "numeric", minute: "2-digit" });
    eyebrow.textContent = "Time temporarily reserved";
    title.textContent = "Your booking hold was created.";
    message.textContent = `Reference ${String(hold.token).slice(0, 8).toUpperCase()}. This hold expires at ${expires}. Billplz is not connected yet, so this is not a confirmed appointment.`;
  }
  document.querySelector("#confirmation-dialog").showModal();
}

async function submitHold() {
  if (!detailsForm.reportValidity() || !state.time) return;
  if (!api.configured) {
    showConfirmation({ preview: true });
    return;
  }

  const form = new FormData(detailsForm);
  nextButton.disabled = true;
  nextButton.textContent = "Reserving…";
  try {
    const payload = await api.createHold({
      catalogue_id: selectedServices()[0].id,
      start_at: state.time.startAt,
      therapist_preference: preferenceCode(),
      therapist_request: document.querySelector("#therapist-comment").value.trim(),
      customer_name: form.get("name"),
      customer_phone: form.get("phone"),
      customer_email: form.get("email"),
      notes: form.get("notes"),
      website: form.get("website"),
    });
    state.hold = payload.hold;
    clearNotice();
    showConfirmation({ hold: payload.hold });
  } catch (error) {
    showNotice(error.message || "Unable to reserve this time.", true);
    if (error.status === 409) {
      state.time = null;
      await loadAvailability();
      showStep(4);
    }
  } finally {
    setContinueLabel();
    updateUi();
  }
}

document.querySelectorAll("[data-outlet]").forEach((button) => {
  button.addEventListener("click", async () => {
    state.outlet = button.dataset.outlet;
    state.therapist = null;
    document.querySelectorAll("[data-therapist]").forEach((option) => option.classList.remove("is-selected"));
    document.querySelectorAll("[data-outlet]").forEach((option) => option.classList.toggle("is-selected", option === button));
    await loadServices();
    state.dates = [];
    renderDates();
    renderTimes();
    updateUi();
  });
});

document.querySelectorAll("[data-therapist]").forEach((button) => {
  button.addEventListener("click", async () => {
    state.therapist = button.dataset.therapist;
    state.time = null;
    document.querySelectorAll("[data-therapist]").forEach((option) => option.classList.toggle("is-selected", option === button));
    await loadDates();
    updateUi();
  });
});

steps.forEach((stepButton) => {
  stepButton.addEventListener("click", () => {
    const target = Number(stepButton.dataset.stepTarget);
    if (target <= state.step) showStep(target);
  });
});

nextButton.addEventListener("click", async () => {
  if (state.step === 5) {
    await submitHold();
    return;
  }
  if (state.step === 2 && !therapistSelectionAllowed()) {
    state.therapist = "No preference";
    await loadDates();
    showStep(4);
    return;
  }
  if (canContinue()) showStep(state.step + 1);
});

backButton.addEventListener("click", () => showStep(state.step === 4 && !therapistSelectionAllowed() ? 2 : state.step - 1));
detailsForm.addEventListener("input", updateUi);
document.querySelector("#therapist-comment").addEventListener("input", updateUi);
summaryToggle.addEventListener("click", openSummary);
summaryClose.addEventListener("click", closeSummary);
summaryOverlay.addEventListener("click", closeSummary);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && summarySheet.classList.contains("is-open")) {
    closeSummary();
    summaryToggle.focus();
  }
});
window.addEventListener("resize", () => {
  if (window.innerWidth > 900 && summarySheet.classList.contains("is-open")) closeSummary();
});
document.querySelector("#close-dialog").addEventListener("click", () => document.querySelector("#confirmation-dialog").close());

async function initializeBooking() {
  services = [];
  renderServices();
  renderDates();
  renderTimes();
  updateUi();
  await loadOutlets();
}

initializeBooking();
