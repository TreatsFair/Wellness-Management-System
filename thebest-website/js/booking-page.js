const outlets = {
  kepong: {
    name: "Kepong · Taman Wahyu",
    phone: "60125262551",
    priceOffset: 0,
  },
  setapak: {
    name: "Setapak · PV128",
    phone: "60127449266",
    priceOffset: 10,
  },
};

const services = [
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

const state = {
  step: 1,
  outlet: null,
  services: new Set(),
  therapist: "No preference",
  date: null,
  time: null,
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

function money(value) {
  return `RM ${value.toFixed(0)}`;
}

function selectedServices() {
  return services.filter((service) => state.services.has(service.id));
}

function totalPrice() {
  const offset = state.outlet ? outlets[state.outlet].priceOffset : 0;
  return selectedServices().reduce((sum, service) => sum + service.price + offset, 0);
}

function totalDuration() {
  return selectedServices().reduce((sum, service) => sum + service.duration, 0);
}

function renderServices() {
  const offset = state.outlet ? outlets[state.outlet].priceOffset : 0;
  document.querySelector("#service-options").innerHTML = services
    .map(
      (service) => `
        <article class="service-card ${state.services.has(service.id) ? "is-selected" : ""}" data-service-card="${service.id}">
          <img src="${service.image}" alt="${service.name}" />
          <div class="service-copy">
            <h3>${service.name}</h3>
            <p>${service.description}</p>
            <span>${service.duration} minutes</span>
          </div>
          <div class="service-action">
            <strong>${money(service.price + offset)}</strong>
            <button class="add-service" type="button" data-service="${service.id}" aria-pressed="${state.services.has(service.id)}">
              ${state.services.has(service.id) ? "Added" : "Add"}
            </button>
          </div>
          <details class="service-more">
            <summary>More about this treatment</summary>
            <p>${service.more}</p>
            <ul>${service.includes.map((item) => `<li>${item}</li>`).join("")}</ul>
          </details>
        </article>`,
    )
    .join("");

  document.querySelectorAll("[data-service]").forEach((button) => {
    button.addEventListener("click", () => {
      const id = button.dataset.service;
      state.services.has(id) ? state.services.delete(id) : state.services.add(id);
      state.date = null;
      state.time = null;
      renderServices();
      updateUi();
    });
  });
}

function renderDates() {
  const dateContainer = document.querySelector("#date-options");
  const formatter = new Intl.DateTimeFormat("en-MY", { weekday: "short" });
  const monthFormatter = new Intl.DateTimeFormat("en-MY", { month: "short" });
  const today = new Date();

  dateContainer.innerHTML = Array.from({ length: 7 }, (_, index) => {
    const date = new Date(today);
    date.setDate(today.getDate() + index + 1);
    const key = date.toISOString().slice(0, 10);
    return `
      <button class="date-button ${state.date === key ? "is-selected" : ""}" type="button" data-date="${key}" data-date-label="${date.toLocaleDateString("en-MY", { weekday: "short", day: "numeric", month: "short" })}">
        <small>${formatter.format(date)}</small>
        <strong>${date.getDate()}</strong>
        <small>${monthFormatter.format(date)}</small>
      </button>`;
  }).join("");

  dateContainer.querySelectorAll("[data-date]").forEach((button) => {
    button.addEventListener("click", () => {
      state.date = button.dataset.date;
      state.time = null;
      renderDates();
      renderTimes();
      updateUi();
    });
  });
}

function renderTimes() {
  const groups = [
    ["Morning", ["10:30 AM", "11:00 AM", "11:30 AM", "12:00 PM"]],
    ["Afternoon", ["1:30 PM", "2:00 PM", "3:30 PM", "4:30 PM"]],
    ["Evening", ["6:00 PM", "7:00 PM", "8:30 PM", "9:00 PM"]],
  ];

  document.querySelector("#time-options").innerHTML = groups
    .map(([label, times]) => `
      <div class="time-group">
        <span>${label}</span>
        ${times.map((time) => `<button class="time-button ${state.time === time ? "is-selected" : ""}" type="button" data-time="${time}" ${state.date ? "" : "disabled"}>${time}</button>`).join("")}
      </div>`)
    .join("");

  document.querySelectorAll("[data-time]").forEach((button) => {
    button.addEventListener("click", () => {
      state.time = button.dataset.time;
      renderTimes();
      updateUi();
    });
  });
}

function canContinue() {
  if (state.step === 1) return Boolean(state.outlet);
  if (state.step === 2) return state.services.size > 0;
  if (state.step === 3) return Boolean(state.therapist);
  if (state.step === 4) return Boolean(state.date && state.time);
  if (state.step === 5) return detailsForm.checkValidity();
  return false;
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
  nextButton.innerHTML = state.step === 5
    ? `Continue to secure payment <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6" /></svg>`
    : `Continue <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6" /></svg>`;
  updateUi();
  const progressTarget = window.matchMedia("(max-width: 680px)").matches
    ? document.querySelector(".mobile-progress")
    : document.querySelector(".stepper");
  progressTarget.scrollIntoView({ behavior: "smooth", block: "start" });
}

function updateUi() {
  nextButton.disabled = !canContinue();
  updateReview();
  updateProgress();
}

function updateReview() {
  const outlet = state.outlet ? outlets[state.outlet].name : "—";
  const treatments = selectedServices().map((service) => service.name).join(", ") || "—";
  const selectedDateButton = document.querySelector(`[data-date="${state.date}"]`);
  const dateTime = state.date && state.time
    ? `${selectedDateButton?.dataset.dateLabel || state.date}, ${state.time}`
    : "—";
  const request = document.querySelector("#therapist-comment")?.value.trim();
  const therapist = request ? `${state.therapist} · Request: ${request}` : state.therapist;

  document.querySelector("#review-outlet").textContent = outlet;
  document.querySelector("#review-services").textContent = treatments;
  document.querySelector("#review-datetime").textContent = dateTime;
  document.querySelector("#review-therapist").textContent = therapist;
  document.querySelector("#review-duration").textContent = `${totalDuration()} minutes`;
  document.querySelector("#review-total").textContent = money(totalPrice());

  const treatmentCount = selectedServices().length;
  const caption = !state.outlet
    ? "Choose an outlet"
    : treatmentCount === 0
      ? outlets[state.outlet].name
      : `${treatmentCount} treatment${treatmentCount === 1 ? "" : "s"} · ${totalDuration()} min`;
  document.querySelector("#mobile-summary-caption").textContent = caption;
  document.querySelector("#mobile-summary-total").textContent = money(totalPrice());
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

document.querySelectorAll("[data-outlet]").forEach((button) => {
  button.addEventListener("click", () => {
    state.outlet = button.dataset.outlet;
    document.querySelectorAll("[data-outlet]").forEach((option) => option.classList.toggle("is-selected", option === button));
    renderServices();
    updateUi();
  });
});

document.querySelectorAll("[data-therapist]").forEach((button) => {
  button.addEventListener("click", () => {
    state.therapist = button.dataset.therapist;
    document.querySelectorAll("[data-therapist]").forEach((option) => option.classList.toggle("is-selected", option === button));
    updateUi();
  });
});

steps.forEach((stepButton) => {
  stepButton.addEventListener("click", () => {
    const target = Number(stepButton.dataset.stepTarget);
    if (target <= state.step) showStep(target);
  });
});

nextButton.addEventListener("click", () => {
  if (state.step === 5) {
    if (!detailsForm.reportValidity()) return;
    document.querySelector("#confirmation-dialog").showModal();
    return;
  }
  if (canContinue()) showStep(state.step + 1);
});

backButton.addEventListener("click", () => showStep(state.step - 1));
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
  if (window.innerWidth > 900 && summarySheet.classList.contains("is-open")) {
    closeSummary();
  }
});

document.querySelector("#close-dialog").addEventListener("click", () => document.querySelector("#confirmation-dialog").close());

renderServices();
renderDates();
renderTimes();
updateUi();
