"use strict";

/* ============================================================
   PreviewMD — Galley
   Release bumps: update DOWNLOAD_FILE *and* every literal
   filename in index.html (hrefs + visible text). The rewrite
   below only fixes up the live DOM — no-JS visitors, crawlers
   and the pre-JS paint read index.html as shipped.
   ============================================================ */
const DOWNLOAD_FILE = "PreviewMD-1.7-11-macOS.dmg";
/* Document-relative on purpose: the page is served from the site root in local
   development and from a /<slug>/ subpath in production. A leading slash would
   miss the proxied endpoint there. */
const NEWSLETTER_ENDPOINT = "api/subscribe";
const DOWNLOAD_ENDPOINT = "api/download";

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (sel, root) => (root || document).querySelector(sel);
const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

/* keep the live DOM in sync with DOWNLOAD_FILE (see header note) */
$$("[data-download]").forEach((a) => { a.href = DOWNLOAD_FILE; a.setAttribute("download", ""); });
$$("[data-filename]").forEach((el) => { el.textContent = DOWNLOAD_FILE; });

/* ---------- shared easing / animation ---------- */
const easeOut = (t) => 1 - Math.pow(1 - t, 4); // ≈ cubic-bezier(0.22, 1, 0.36, 1)

function animate(from, to, ms, apply, done) {
  if (reduceMotion || ms <= 0) { apply(to); if (done) done(); return; }
  const t0 = performance.now();
  const tick = (now) => {
    const t = Math.min(1, (now - t0) / ms);
    apply(from + (to - from) * easeOut(t));
    if (t < 1) requestAnimationFrame(tick);
    else if (done) done();
  };
  requestAnimationFrame(tick);
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/* ============================================================
   The render seam
   ============================================================ */
const hero = $("#hero");
const galleyBody = $("#galleyBody");
const seamHandle = $("#seamHandle");
const seamReadout = $("#seamReadout");
const segButtons = $$("#segments button");
const ctaBlock = $("#ctaBlock");
const paneRendered = $(".pane-rendered");
const paneSource = $(".pane-source");
const docRendered = $(".doc-rendered");
const docSource = $(".doc-source");
const docLink = $(".doc-link");
const srcLink = $(".src-link");

let seam = 46; // percent

/* how far a doc may slide before hitting the pane's padding edge */
let maxShift = 0;
function measurePane() {
  const cs = getComputedStyle(paneRendered);
  const contentW = paneRendered.clientWidth
    - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
  maxShift = Math.max(0, (contentW - docRendered.offsetWidth) / 2);
}

function setSeam(pct) {
  seam = clamp(pct, 0, 100);
  galleyBody.style.setProperty("--seam", seam + "%");
  const rect = galleyBody.getBoundingClientRect();
  const px = Math.round((rect.width * seam) / 100);
  seamHandle.setAttribute("aria-valuenow", String(Math.round(seam)));
  seamHandle.setAttribute("aria-valuetext", px + " px");
  seamReadout.textContent = px + " px";

  /* each layer's document slides toward its own pane so both headline
     forms stay whole at rest, converging to center as a pane fills */
  const shiftRen = Math.min((seam / 100) * rect.width / 2, maxShift);
  const shiftSrc = Math.min(((100 - seam) / 100) * rect.width / 2, maxShift);
  docRendered.style.transform = "translateX(" + shiftRen.toFixed(1) + "px)";
  docSource.style.transform = "translateX(-" + shiftSrc.toFixed(1) + "px)";

  const mode = seam < 8 ? "preview" : seam > 92 ? "source" : "split";
  segButtons.forEach((b) => {
    const on = b.dataset.mode === mode;
    b.classList.toggle("active", on);
    b.setAttribute("aria-pressed", String(on));
  });

  /* when the rendered pane is fully clipped away, take it out of the
     tab order and the accessibility tree — no invisible focus stops */
  const renderedGone = seam >= 99.5;
  paneRendered.inert = renderedGone;
  paneRendered.style.visibility = renderedGone ? "hidden" : "";
  if (docLink) docLink.tabIndex = renderedGone ? -1 : 0;
  /* mirror: expose the source layer only when it is the visible document */
  const sourceMode = mode === "source";
  paneSource.setAttribute("aria-hidden", String(!sourceMode));
  if (srcLink) srcLink.tabIndex = sourceMode ? 0 : -1;
}

/* drag */
seamHandle.addEventListener("pointerdown", (e) => {
  e.preventDefault();
  seamHandle.setPointerCapture(e.pointerId);
  seamHandle.classList.add("dragging");
  const move = (ev) => {
    const rect = galleyBody.getBoundingClientRect();
    setSeam(((ev.clientX - rect.left) / rect.width) * 100);
  };
  const up = () => {
    seamHandle.removeEventListener("pointermove", move);
    seamHandle.classList.remove("dragging");
  };
  seamHandle.addEventListener("pointermove", move);
  seamHandle.addEventListener("pointerup", up, { once: true });
  seamHandle.addEventListener("pointercancel", up, { once: true });
  move(e);
});

/* keyboard */
seamHandle.addEventListener("keydown", (e) => {
  const step = e.shiftKey ? 10 : 2;
  if (e.key === "ArrowLeft" || e.key === "ArrowDown") { setSeam(seam - step); e.preventDefault(); }
  else if (e.key === "ArrowRight" || e.key === "ArrowUp") { setSeam(seam + step); e.preventDefault(); }
  else if (e.key === "Home") { setSeam(0); e.preventDefault(); }
  else if (e.key === "End") { setSeam(100); e.preventDefault(); }
});

/* segmented control: Preview / Split / Source */
segButtons.forEach((b) => {
  b.addEventListener("click", () => {
    const target = b.dataset.mode === "preview" ? 0 : b.dataset.mode === "source" ? 100 : 46;
    animate(seam, target, 420, setSeam);
  });
});

/* load moment: the page typesets itself. On narrow screens the two
   layers can't sit side by side legibly, so the sweep runs all the way
   to fully-typeset (0%) instead of resting mid-split. */
const REST_SEAM = window.matchMedia("(max-width: 640px)").matches ? 0 : 46;
measurePane();
if (reduceMotion) {
  setSeam(REST_SEAM);
} else {
  ctaBlock.classList.add("pre");
  setSeam(100);
  setTimeout(() => {
    animate(100, REST_SEAM, 1100, setSeam, () => {
      setTimeout(() => ctaBlock.classList.remove("pre"), 150);
    });
  }, 500);
}

/* keep the px readout and doc anchoring honest on resize */
window.addEventListener("resize", () => { measurePane(); setSeam(seam); });

/* ============================================================
   Character-parallel rows: equalize source/rendered row heights
   ============================================================ */
const renRows = $$(".doc-rendered .row");
const srcRows = $$(".doc-source .row");

function equalizeRows() {
  renRows.forEach((r) => { r.style.minHeight = ""; });
  srcRows.forEach((r) => { r.style.minHeight = ""; });
  renRows.forEach((r, i) => {
    const s = srcRows[i];
    if (!s) return;
    const h = Math.max(r.offsetHeight, s.offsetHeight);
    r.style.minHeight = h + "px";
    s.style.minHeight = h + "px";
  });
}

let eqTimer;
const equalizeSoon = () => { clearTimeout(eqTimer); eqTimer = setTimeout(equalizeRows, 80); };

equalizeRows();
if (document.fonts && document.fonts.ready) document.fonts.ready.then(equalizeRows);
window.addEventListener("resize", equalizeSoon);

/* ============================================================
   The reading-width ruler (560–1600 px, like the app's)
   ============================================================ */
const rulerTrack = $("#rulerTrack");
const rulerHandle = $("#rulerHandle");
const rulerReadout = $("#rulerReadout");
const rulerStops = $$(".ruler-stop");
const M_MIN = 560, M_MAX = 1600;
const DOC_SCALE = 62; // .doc renders at measure × 0.62 (styles.css) — the readout says so

let measure = 800;

function setMeasure(v) {
  measure = Math.round(clamp(v, M_MIN, M_MAX));
  hero.style.setProperty("--measure", String(measure));
  rulerHandle.setAttribute("aria-valuenow", String(measure));
  rulerHandle.setAttribute("aria-valuetext", measure + " px");
  rulerReadout.textContent = measure + " px · shown at " + DOC_SCALE + "%";
  rulerStops.forEach((s) => s.classList.toggle("active", Number(s.dataset.measure) === measure));
  measurePane();
  setSeam(seam);
  equalizeSoon();
}

rulerStops.forEach((s) => {
  s.addEventListener("click", () => animate(measure, Number(s.dataset.measure), 320, setMeasure));
});

rulerHandle.addEventListener("pointerdown", (e) => {
  e.preventDefault();
  rulerHandle.setPointerCapture(e.pointerId);
  rulerHandle.classList.add("dragging");
  const move = (ev) => {
    const rect = rulerTrack.getBoundingClientRect();
    const f = clamp((ev.clientX - rect.left) / rect.width, 0, 1);
    setMeasure(M_MIN + f * (M_MAX - M_MIN));
  };
  const up = () => {
    rulerHandle.removeEventListener("pointermove", move);
    rulerHandle.classList.remove("dragging");
  };
  rulerHandle.addEventListener("pointermove", move);
  rulerHandle.addEventListener("pointerup", up, { once: true });
  rulerHandle.addEventListener("pointercancel", up, { once: true });
  move(e);
});

rulerHandle.addEventListener("keydown", (e) => {
  const step = e.shiftKey ? 120 : 20;
  if (e.key === "ArrowLeft" || e.key === "ArrowDown") { setMeasure(measure - step); e.preventDefault(); }
  else if (e.key === "ArrowRight" || e.key === "ArrowUp") { setMeasure(measure + step); e.preventDefault(); }
  else if (e.key === "Home") { setMeasure(M_MIN); e.preventDefault(); }
  else if (e.key === "End") { setMeasure(M_MAX); e.preventDefault(); }
});

setMeasure(800);

/* ============================================================
   Clipping copy button — only says "Copied" when it actually did
   ============================================================ */
$$("[data-copy]").forEach((btn) => {
  let copyTimer;
  const flash = (label, ok) => {
    btn.textContent = label;
    btn.classList.toggle("done", ok);
    clearTimeout(copyTimer);
    copyTimer = setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("done"); }, 1500);
  };
  btn.addEventListener("click", () => {
    const code = btn.parentElement.querySelector("code");
    const text = code ? code.innerText : "";
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        () => flash("Copied", true),
        () => flash("Copy failed", false)
      );
    } else {
      flash("Copy failed", false);
    }
  });
});

/* ============================================================
   Email updates modal — shown after every download click
   ============================================================ */
const card = $("#emailCard");
const cardMain = $("#cardMain");
const cardSuccess = $("#cardSuccess");
const cardError = $("#cardError");
const notifyForm = $("#notifyForm");
const emailInput = $("#emailInput");
const signupButton = notifyForm.querySelector('[type="submit"]');
const liveStatus = $("#liveStatus");

function showCard() {
  if (card.open) return;
  card.showModal(); // native <dialog>: focus trap, Escape and backdrop for free
  liveStatus.textContent = "An optional PreviewMD updates signup appeared.";
}

function dismissCard() {
  if (card.open) card.close();
}

/* Reset the form after every close so the modal is ready to open again.
   The dialog returns focus to the triggering link by itself. */
card.addEventListener("close", () => {
  liveStatus.textContent = "";
  cardMain.hidden = false;
  cardSuccess.hidden = true;
  cardError.hidden = true;
  notifyForm.reset();
  signupButton.disabled = false;
  signupButton.textContent = "Keep me posted";
});

/* classic modal affordance: clicking the dimmed backdrop closes it
   (the backdrop is the dialog element itself outside its padding box) */
card.addEventListener("click", (e) => {
  if (e.target === card) dismissCard();
});

$("#cardClose").addEventListener("click", dismissCard);
$("#cardDismiss").addEventListener("click", dismissCard);

/* Let the native download start, record the click without gating it, then open
   the signup. Dismissing it never suppresses a future opening. */
function recordDownloadClick() {
  fetch(DOWNLOAD_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify({ file: DOWNLOAD_FILE }),
    keepalive: true
  })
    .then((response) => {
      if (!response.ok) throw new Error("HTTP " + response.status);
    })
    .catch((err) => {
      console.warn("PreviewMD: download tracking failed —", err);
    });
}

$$("[data-download]").forEach((link) => {
  link.addEventListener("click", () => {
    recordDownloadClick();
    setTimeout(showCard, 0);
  });
});

const showSignupSuccess = () => {
  cardMain.hidden = true;
  cardSuccess.hidden = false; // role="status" announces it
  card.focus({ preventScroll: true }); // focus was on the hidden button
  setTimeout(dismissCard, 1800); // linger, then let the reader go
};

notifyForm.addEventListener("submit", (e) => {
  e.preventDefault();
  const email = emailInput.value.trim();
  if (!email || !emailInput.checkValidity()) { emailInput.reportValidity(); return; }
  cardError.hidden = true;
  signupButton.disabled = true;
  signupButton.textContent = "Saving…";

  fetch(NEWSLETTER_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify({ email })
  })
    .then((r) => {
      if (!r.ok) throw new Error("HTTP " + r.status);
      showSignupSuccess();
    })
    .catch((err) => {
      console.warn("PreviewMD: newsletter signup failed —", err);
      cardError.hidden = false; // keep the form so retry is possible
    })
    .finally(() => {
      signupButton.disabled = false;
      signupButton.textContent = "Keep me posted";
    });
});
