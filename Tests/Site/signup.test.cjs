"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

function modalHarness() {
  const timers = new Map();
  const closeEvents = [];
  const requests = [];
  const warnings = [];
  let nextTimerID = 1;
  let focusedElement = null;

  class Element {
    constructor() {
      this.listeners = new Map();
      this.hidden = false;
      this.disabled = false;
      this.textContent = "";
      this.value = "";
      this.open = false;
    }
    addEventListener(name, listener) {
      const listeners = this.listeners.get(name) || [];
      listeners.push(listener);
      this.listeners.set(name, listeners);
    }
    dispatch(name, event = {}) {
      for (const listener of this.listeners.get(name) || []) {
        listener({ preventDefault() {}, ...event });
      }
    }
    querySelector() { return elements.signupButton; }
    reset() { elements.emailInput.value = ""; }
    checkValidity() { return true; }
    showModal() { this.open = true; }
    close() {
      this.open = false;
      // Native dialog close events are queued rather than fired by close().
      closeEvents.push(() => this.dispatch("close"));
    }
    focus() { focusedElement = this; }
  }

  const elements = Object.fromEntries([
    "emailCard", "cardMain", "cardSuccess", "cardError", "notifyForm",
    "emailInput", "signupButton", "liveStatus", "cardClose", "cardDismiss",
    "emailTitle", "download",
  ].map((name) => [name, new Element()]));
  elements.cardSuccess.hidden = true;
  elements.cardError.hidden = true;

  const context = vm.createContext({
    $: (selector) => elements[selector.slice(1)],
    $$: () => [elements.download],
    AbortController,
    NEWSLETTER_ENDPOINT: "api/subscribe",
    DOWNLOAD_ENDPOINT: "api/download",
    DOWNLOAD_FILE: "PreviewMD-1.7-11-macOS.dmg",
    console: { warn: (...args) => warnings.push(args) },
    fetch: (url, options) => new Promise((resolve, reject) => {
      // Deliberately allow completion after abort: responses can already be
      // queued when a browser closes the dialog.
      requests.push({ url, options, resolve, reject });
    }),
    setTimeout: (callback, delay) => {
      const id = nextTimerID++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout: (id) => timers.delete(id),
  });
  const source = fs.readFileSync(
    path.join(__dirname, "../../site/main.js"), "utf8"
  );
  const modalStart = source.indexOf('const card = $("#emailCard");');
  assert.notEqual(modalStart, -1, "The actual signup implementation must be tested");
  vm.runInContext(source.slice(modalStart), context);

  return {
    elements, requests, warnings, timers,
    focused: () => focusedElement,
    open: () => vm.runInContext("showCard()", context),
    close: () => vm.runInContext("dismissCard()", context),
    flushCloseEvents: () => {
      while (closeEvents.length) closeEvents.shift()();
    },
    submit: (email = "reader@example.com") => {
      elements.emailInput.value = email;
      elements.notifyForm.dispatch("submit");
      return requests.at(-1);
    },
    runTimers: (delay) => {
      for (const [id, timer] of [...timers]) {
        if (timer.delay !== delay) continue;
        timers.delete(id);
        timer.callback();
      }
    },
  };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));

test("download opens each time, without waiting for tracking, and focuses the heading", () => {
  const h = modalHarness();
  assert.equal(h.elements.emailCard.open, false);
  h.elements.download.dispatch("click");
  assert.equal(h.requests[0].url, "api/download");
  h.runTimers(0);
  assert.equal(h.elements.emailCard.open, true);
  assert.equal(h.focused(), h.elements.emailTitle);
  h.close();
  h.flushCloseEvents();
  h.elements.download.dispatch("click");
  h.runTimers(0);
  assert.equal(h.elements.emailCard.open, true);
});

for (const outcome of ["success", "http error", "network error"]) {
  test(`a stale ${outcome} cannot change a reopened form or a newer request`, async () => {
    const h = modalHarness();
    h.open();
    const previous = h.submit();
    h.close();
    assert.equal(previous.options.signal.aborted, true);
    h.open();
    const current = h.submit("second@example.com");
    // Even a close event queued by the old opening must leave this one alone.
    h.flushCloseEvents();
    assert.equal(current.options.signal.aborted, false);

    if (outcome === "network error") previous.reject(new Error("offline"));
    else previous.resolve({ ok: outcome === "success", status: 500 });
    await settle();

    assert.equal(h.elements.emailCard.open, true);
    assert.equal(h.elements.cardMain.hidden, false);
    assert.equal(h.elements.cardSuccess.hidden, true);
    assert.equal(h.elements.cardError.hidden, true);
    assert.equal(h.elements.signupButton.disabled, true);
    assert.equal(h.elements.signupButton.textContent, "Saving…");
    assert.equal(h.warnings.length, 0);
    h.runTimers(1800);
    assert.equal(h.elements.emailCard.open, true);

    current.resolve({ ok: true });
    await settle();
    assert.equal(h.elements.cardSuccess.hidden, false);
  });
}

test("closing a successful signup clears its timer before the next opening", async () => {
  const h = modalHarness();
  h.open();
  h.submit().resolve({ ok: true });
  await settle();
  assert.equal(h.elements.cardMain.hidden, true);
  assert.equal(h.timers.size, 1);
  h.close();
  h.open();
  h.flushCloseEvents();
  assert.equal(h.timers.size, 0);
  h.runTimers(1800);
  assert.equal(h.elements.emailCard.open, true);
  assert.equal(h.elements.cardMain.hidden, false);
});

test("native closure also resets and aborts an outstanding signup", async () => {
  const h = modalHarness();
  h.open();
  const request = h.submit();
  h.elements.emailCard.close();
  h.flushCloseEvents();
  assert.equal(request.options.signal.aborted, true);
  assert.equal(h.elements.emailInput.value, "");
  assert.equal(h.elements.signupButton.disabled, false);
  request.resolve({ ok: true });
  await settle();
  assert.equal(h.elements.cardSuccess.hidden, true);
});

test("a current failure remains retryable and a current success closes normally", async () => {
  const h = modalHarness();
  h.open();
  h.submit().resolve({ ok: false, status: 500 });
  await settle();
  assert.equal(h.elements.cardError.hidden, false);
  assert.equal(h.elements.signupButton.disabled, false);
  assert.equal(h.warnings.length, 1);
  h.submit().resolve({ ok: true });
  await settle();
  assert.equal(h.elements.cardError.hidden, true);
  assert.equal(h.elements.cardSuccess.hidden, false);
  h.runTimers(1800);
  assert.equal(h.elements.emailCard.open, false);
  assert.equal(h.elements.cardSuccess.hidden, true);
});

test("repeated submits cannot create competing requests within one opening", () => {
  const h = modalHarness();
  h.open();
  h.submit();
  h.submit();
  assert.equal(h.requests.length, 1);
});
