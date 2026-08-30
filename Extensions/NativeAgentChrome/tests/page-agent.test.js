import assert from "node:assert/strict";
import test from "node:test";

const messageListeners = [];
const clicks = [];
const scrolls = [];
const editableEvents = [];
const keyboardEvents = [];
const mouseEvents = [];
const trustedInputListeners = new Map();
let mutationCallback;

class FixtureElement {
  constructor(tagName, { text = "", attrs = {}, value, type, parent = null } = {}) {
    this.tagName = tagName.toUpperCase();
    this.innerText = text;
    this.textContent = text;
    this.attributes = attrs;
    this.value = value;
    this.type = type;
    this.parentElement = parent;
    this.isConnected = true;
    this.disabled = false;
    this.checked = false;
    this.selected = false;
    this.isContentEditable = false;
    this.scrollHeight = 40;
    this.clientHeight = 40;
    this.scrollWidth = 120;
    this.clientWidth = 120;
    this.children = [];
    this.tabIndex = -1;
    this.multiple = false;
    this.options = undefined;
    if (parent) parent.children.push(this);
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  getBoundingClientRect() { return { x: 10, y: 20, width: 120, height: 40 }; }
  click() { clicks.push(this); }
  scrollBy(options) { scrolls.push(options); }
  focus() { this.focused = true; }
  dispatchEvent(event) {
    if (event.type === "input") this.onInput?.();
    if (event.type === "change") this.onChange?.();
    if (event.type.startsWith("key")) keyboardEvents.push(event.type);
    else if (event.type === "dblclick") mouseEvents.push(event.type);
    else editableEvents.push(event.type);
    return true;
  }
}

const body = new FixtureElement("body", { text: "Fixture page Buy now Hidden secret" });
const heading = new FixtureElement("h1", { text: "Fixture page", parent: body });
const button = new FixtureElement("button", { text: "Buy now", attrs: { "aria-label": "Buy now" }, parent: body });
const textInput = new FixtureElement("input", { value: "start", type: "text", attrs: { "aria-label": "Notes" }, parent: body });
const password = new FixtureElement("input", { value: "hidden-secret", type: "password", parent: body });
const select = new FixtureElement("select", { attrs: { "aria-label": "Plan" }, parent: body });
select.options = [
  { value: "free", selected: true },
  { value: "pro", selected: false },
];
const checkbox = new FixtureElement("input", { type: "checkbox", attrs: { "aria-label": "Subscribe" }, parent: body });
const shadowHost = new FixtureElement("div", { attrs: { "aria-label": "Shadow host" }, parent: body });
const shadowButton = new FixtureElement("button", { text: "Shadow action", attrs: { "aria-label": "Shadow action" } });
shadowButton.getRootNode = () => shadowHost.shadowRoot;
shadowHost.shadowRoot = { host: shadowHost, children: [shadowButton] };

globalThis.MutationObserver = class {
  constructor(callback) { this.callback = callback; mutationCallback = callback; }
  observe() {}
};
globalThis.document = {
  body,
  title: "Fixture",
  documentElement: { lang: "en", scrollWidth: 1200, scrollHeight: 3000 },
};
globalThis.window = {
  addEventListener(name, listener) { trustedInputListeners.set(name, listener); },
  innerWidth: 1200,
  innerHeight: 800,
  scrollX: 0,
  scrollY: 100,
  scrollBy(options) { scrolls.push(options); this.scrollY += options.top; },
};
globalThis.location = { href: "https://example.com/fixture" };
Object.defineProperty(globalThis, "navigator", { value: { language: "en-US" }, configurable: true });
globalThis.getComputedStyle = () => ({
  display: "block", visibility: "visible", opacity: "1", overflow: "visible", overflowX: "visible", overflowY: "visible",
});
globalThis.chrome = {
  runtime: {
    onMessage: { addListener(listener) { messageListeners.push(listener); } },
  },
};
globalThis.KeyboardEvent = class {
  constructor(type, init) { this.type = type; Object.assign(this, init); }
};
globalThis.MouseEvent = class {
  constructor(type, init) { this.type = type; Object.assign(this, init); }
};

await import("../src/page-agent.js");

function send(message) {
  return new Promise((resolve) => {
    const returned = messageListeners[0](message, {}, resolve);
    assert.ok(returned === false || returned === true);
  });
}

test("fill confirms immediate input and editable content without claiming reset values succeeded", async () => {
  const editable = new FixtureElement("div", { attrs: { "aria-label": "Editable proof" }, parent: body });
  editable.isContentEditable = true;
  const originalValue = textInput.value;
  async function fill(element, value) {
    const snapshot = await send({ type: "nativeagent.page.snapshot", leaseId: "fill-proof", tabId: 42, userSequence: 0 });
    const node = snapshot.result.nodes.find((node) => node.name === element.getAttribute("aria-label"));
    assert.ok(node);
    return send({ type: "nativeagent.page.fill", snapshotId: snapshot.result.snapshotId, nodeId: node.nodeId, value });
  }
  try {
    for (const element of [textInput, editable]) {
      const assign = (value) => { if (element.isContentEditable) element.textContent = value; else element.value = value; };
      element.onInput = () => assign("confirmed 🐕");
      assert.equal((await fill(element, "confirmed 🐕")).result.filled, true);
      delete element.onInput;
      for (const event of ["onInput", "onChange"]) {
        let eventCount = 0;
        element[event] = () => { eventCount += 1; assign("page restored private text"); };
        const response = await fill(element, "requested private text");
        assert.equal(response.ok, false);
        assert.equal(response.error.code, "action_outcome_unknown");
        assert.match(response.error.message, /Observe before retrying/);
        assert.doesNotMatch(response.error.message, /private text/);
        assert.equal(eventCount, 1, "no automatic reapplication");
        delete element[event];
      }
      element.onChange = () => { throw new Error("private page exception"); };
      const thrown = await fill(element, "may have applied");
      assert.equal(thrown.error.code, "action_outcome_unknown");
      assert.doesNotMatch(thrown.error.message, /private page exception/);
      delete element.onChange;
      element.onChange = () => { element.isConnected = false; };
      assert.equal((await fill(element, "detached value")).error.code, "action_outcome_unknown");
      element.isConnected = true;
      delete element.onChange;
    }
  } finally {
    textInput.value = originalValue;
    textInput.isConnected = true;
    delete textInput.onInput;
    delete textInput.onChange;
    body.children.splice(body.children.indexOf(editable), 1);
  }
});

test("select confirms live option values including multiselect and rejects post-event mismatch as unknown", async () => {
  const originalOptions = select.options;
  const originalMultiple = select.multiple;
  async function choose(values) {
    const snapshot = await send({ type: "nativeagent.page.snapshot", leaseId: "select-proof", tabId: 42, userSequence: 0 });
    const node = snapshot.result.nodes.find((node) => node.name === "Plan");
    return send({ type: "nativeagent.page.select", snapshotId: snapshot.result.snapshotId, nodeId: node.nodeId, values });
  }
  const reset = () => {
    select.options = [{ value: "free", selected: true }, { value: "pro", selected: false }];
  };
  try {
    select.multiple = true;
    reset();
    assert.deepEqual((await choose(["pro", "free", "pro"])).result.values, ["free", "pro"]);
    assert.deepEqual((await choose([])).result.values, []);
    select.multiple = false;
    reset();
    select.onChange = () => { select.options = [{ value: "pro", selected: true }]; };
    assert.deepEqual((await choose(["pro"])).result.values, ["pro"], "equivalent live replacement remains valid");
    delete select.onChange;
    for (const event of ["onInput", "onChange"]) {
      reset();
      let eventCount = 0;
      select[event] = () => { eventCount += 1; reset(); };
      const response = await choose(["pro"]);
      assert.equal(response.ok, false);
      assert.equal(response.error.code, "action_outcome_unknown");
      assert.match(response.error.message, /Observe before retrying/);
      assert.equal(eventCount, 1, "no automatic reselection");
      delete select[event];
    }
    reset();
    select.onChange = () => { throw new Error("private page exception"); };
    const thrown = await choose(["pro"]);
    assert.equal(thrown.error.code, "action_outcome_unknown");
    assert.doesNotMatch(thrown.error.message, /private page exception/);
    delete select.onChange;
    const missing = await choose(["missing"]);
    assert.equal(missing.error.code, "option_not_found", "pre-effect refusal stays a refusal");
  } finally {
    select.options = originalOptions;
    select.multiple = originalMultiple;
    delete select.onInput;
    delete select.onChange;
  }
});

test("fixture snapshot returns readable actionable nodes and redacts passwords", async () => {
  const response = await send({
    type: "nativeagent.page.snapshot",
    leaseId: "lease-fixture",
    tabId: 42,
    userSequence: 0,
    maxNodes: 500,
    maxTextChars: 50_000,
  });
  assert.equal(response.ok, true);
  assert.equal(response.result.summary.text, "Fixture page Buy now Hidden secret");
  const actionable = response.result.nodes.find((node) => node.name === "Buy now");
  assert.deepEqual(actionable.actions, ["click", "double_click", "keypress", "wait"]);
  const passwordNode = response.result.nodes.find((node) => node.value === null && node.kind === "input");
  assert.equal(passwordNode.value, null);
  assert.deepEqual(passwordNode.actions, []);

  const click = await send({
    type: "nativeagent.page.click",
    snapshotId: response.result.snapshotId,
    nodeId: actionable.nodeId,
  });
  assert.equal(click.result.clicked, true);
  assert.equal(clicks.length, 1);

  const rejectedClick = await send({
    type: "nativeagent.page.click",
    snapshotId: response.result.snapshotId,
    nodeId: response.result.nodes.find((node) => node.kind === "heading").nodeId,
  });
  assert.equal(rejectedClick.ok, false);
  assert.equal(rejectedClick.error.code, "node_not_actionable");

  const scroll = await send({
    type: "nativeagent.page.scroll",
    snapshotId: response.result.snapshotId,
    deltaX: 0,
    deltaY: 640,
  });
  assert.equal(scroll.result.scrolled, true);
  assert.deepEqual(scrolls.at(-1), { left: 0, top: 640, behavior: "auto" });
});

test("select, keypress, set_checked, and double_click require advertised current nodes", async () => {
  const snapshot = await send({
    type: "nativeagent.page.snapshot",
    leaseId: "lease-phase-two",
    tabId: 42,
    userSequence: 0,
  });
  const selectNode = snapshot.result.nodes.find((node) => node.name === "Plan");
  const checkboxNode = snapshot.result.nodes.find((node) => node.name === "Subscribe");
  const buttonNode = snapshot.result.nodes.find((node) => node.name === "Buy now");
  const shadowNode = snapshot.result.nodes.find((node) => node.name === "Shadow action");
  assert.ok(shadowNode, "open shadow-root content must be walked");
  assert.equal(shadowNode.parentNodeId, snapshot.result.nodes.find((node) => node.name === "Shadow host").nodeId);
  assert.ok(selectNode.actions.includes("select"));
  assert.ok(checkboxNode.actions.includes("set_checked"));

  const selected = await send({
    type: "nativeagent.page.select",
    snapshotId: snapshot.result.snapshotId,
    nodeId: selectNode.nodeId,
    values: ["pro"],
  });
  assert.equal(selected.ok, true);
  assert.deepEqual(selected.result.values, ["pro"]);

  const checked = await send({
    type: "nativeagent.page.set_checked",
    snapshotId: snapshot.result.snapshotId,
    nodeId: checkboxNode.nodeId,
    checked: true,
  });
  assert.equal(checked.ok, true);
  assert.equal(checked.result.checked, true);

  const keypress = await send({
    type: "nativeagent.page.keypress",
    snapshotId: snapshot.result.snapshotId,
    nodeId: buttonNode.nodeId,
    key: "Enter",
  });
  assert.equal(keypress.ok, true);
  assert.deepEqual(keyboardEvents.slice(-2), ["keydown", "keyup"]);

  const doubled = await send({
    type: "nativeagent.page.double_click",
    snapshotId: snapshot.result.snapshotId,
    nodeId: buttonNode.nodeId,
  });
  assert.equal(doubled.ok, true);
  assert.equal(mouseEvents.at(-1), "dblclick");

  const refused = await send({
    type: "nativeagent.page.select",
    snapshotId: snapshot.result.snapshotId,
    nodeId: buttonNode.nodeId,
    values: ["pro"],
  });
  assert.equal(refused.ok, false);
  assert.equal(refused.error.code, "node_not_actionable");
});

test("fill replaces and type appends only on the current advertised editable node", async () => {
  const snapshot = await send({
    type: "nativeagent.page.snapshot",
    leaseId: "lease-edit",
    tabId: 42,
    userSequence: 0,
  });
  const editable = snapshot.result.nodes.find((node) => node.name === "Notes");
  assert.deepEqual(editable.actions, ["fill", "type", "keypress", "wait"]);

  const fill = await send({
    type: "nativeagent.page.fill",
    snapshotId: snapshot.result.snapshotId,
    nodeId: editable.nodeId,
    value: "replacement",
  });
  assert.equal(fill.ok, true);
  assert.equal(fill.result.valueLength, 11);
  assert.equal(textInput.value, "replacement");

  const typed = await send({
    type: "nativeagent.page.type",
    leaseId: "lease-edit",
    leaseExpiresAtMs: Date.now() + 60_000,
    snapshotId: snapshot.result.snapshotId,
    nodeId: editable.nodeId,
    text: " + more",
    delayMs: 0,
  });
  assert.equal(typed.ok, true);
  assert.equal(typed.result.characterCount, 7);
  assert.equal(typed.result.completed, true);
  assert.equal(textInput.value, "replacement + more");
  assert.equal(textInput.focused, true);
  assert.ok(editableEvents.includes("input"));
  assert.ok(editableEvents.includes("change"));

  const waited = await send({
    type: "nativeagent.page.wait",
    leaseId: "lease-edit",
    leaseExpiresAtMs: Date.now() + 60_000,
    snapshotId: snapshot.result.snapshotId,
    nodeId: editable.nodeId,
    state: "enabled",
    timeoutMs: 100,
  });
  assert.equal(waited.ok, true);
  assert.equal(waited.result.matched, true);
});

async function nodeWaitMessage(leaseId, timeoutMs = 5_000) {
  const snapshot = await send({ type: "nativeagent.page.snapshot", leaseId, tabId: 42, userSequence: 0 });
  const node = snapshot.result.nodes.find((item) => item.name === "Notes");
  return {
    type: "nativeagent.page.wait", leaseId, leaseExpiresAtMs: Date.now() + 60_000,
    snapshotId: snapshot.result.snapshotId, nodeId: node.nodeId, state: "disabled", timeoutMs,
  };
}

test("node wait uses elapsed time even when the wall clock moves backward", async (t) => {
  let elapsed = 0;
  let wall = Date.now();
  let delays = 0;
  t.mock.method(performance, "now", () => elapsed);
  t.mock.method(Date, "now", () => wall);
  t.mock.method(globalThis, "setTimeout", (callback, milliseconds) => {
    assert.ok(++delays <= 4, "a backward wall clock must not extend the polling loop");
    elapsed += milliseconds;
    wall -= 10_000;
    queueMicrotask(callback);
    return 0;
  });
  const response = await send(await nodeWaitMessage("lease-wait-monotonic", 120));
  assert.equal(response.ok, true);
  assert.equal(response.result.matched, false);
  assert.equal(elapsed, 120);
  assert.equal(delays, 3);
});

test("node waits stop on existing takeover, lease revoke, and expiry signals", async (t) => {
  const timers = [];
  let wall = Date.now();
  t.mock.method(Date, "now", () => wall);
  t.mock.method(globalThis, "setTimeout", (callback) => { timers.push(callback); return 0; });
  for (const reason of ["lease_revoked", "user_takeover", "lease_expired"]) {
    const message = await nodeWaitMessage(`lease-wait-${reason}`);
    const pending = send(message);
    assert.equal(timers.length, 1);
    if (reason === "lease_revoked") {
      await send({ type: "nativeagent.page.lease.invalidated", leaseId: message.leaseId });
    } else if (reason === "user_takeover") {
      trustedInputListeners.get("pointerdown")({ isTrusted: true });
    } else {
      wall = message.leaseExpiresAtMs + 1;
    }
    timers.shift()();
    const response = await pending;
    assert.equal(response.ok, false);
    assert.equal(response.error.code, reason);
    assert.equal(timers.length, 0, "stopped waits must not schedule another poll");
  }
});

test("lease invalidation stops only its matching node wait", async (t) => {
  const timers = [];
  t.mock.method(globalThis, "setTimeout", (callback) => { timers.push(callback); return 0; });
  t.after(() => { textInput.disabled = false; });
  const firstMessage = await nodeWaitMessage("lease-wait-first");
  const first = send(firstMessage);
  const secondMessage = await nodeWaitMessage("lease-wait-second");
  let secondCompleted = false;
  const second = send(secondMessage).then((response) => { secondCompleted = true; return response; });
  await send({ type: "nativeagent.page.lease.invalidated", leaseId: firstMessage.leaseId });
  timers.shift()();
  assert.equal((await first).error.code, "lease_revoked");
  assert.equal(secondCompleted, false);
  textInput.disabled = true;
  timers.shift()();
  const response = await second;
  assert.equal(response.ok, true);
  assert.equal(response.result.matched, true);
});

test("typing deadline reports Unicode-safe continuation instead of replaying the full text", async (t) => {
  let now = 0;
  t.mock.method(performance, "now", () => now);
  textInput.value = "";
  textInput.onInput = () => { now = 20_001; };
  t.after(() => { textInput.onInput = undefined; });
  const snapshot = await send({ type: "nativeagent.page.snapshot", leaseId: "lease-deadline", tabId: 42, userSequence: 0 });
  const editable = snapshot.result.nodes.find((node) => node.name === "Notes");
  const typed = await send({
    type: "nativeagent.page.type", leaseId: "lease-deadline", leaseExpiresAtMs: Date.now() + 60_000,
    snapshotId: snapshot.result.snapshotId, nodeId: editable.nodeId, text: "🙂xy", delayMs: 0,
  });
  assert.equal(typed.ok, true);
  assert.equal(typed.result.completed, false);
  assert.equal(typed.result.stopReason, "execution_deadline");
  assert.equal(typed.result.characterCount, 1);
  assert.equal(typed.result.requestedCharacterCount, 3);
  assert.equal(typed.result.remainingCharacterCount, 2);
  assert.equal(typed.result.nextCharacterIndex, 1);
  assert.equal(typed.result.nextUTF16Offset, 2);
  assert.equal("🙂xy".slice(typed.result.nextUTF16Offset), "xy");
  assert.equal(textInput.value, "🙂");
});

test("typing revalidates field identity and lease state between characters", async (t) => {
  t.after(() => { textInput.onInput = undefined; textInput.attributes["aria-label"] = "Notes"; });
  for (const stopReason of ["target_changed", "lease_revoked", "lease_expired"]) {
    textInput.attributes["aria-label"] = "Notes";
    textInput.value = "";
    const leaseId = `lease-${stopReason}`;
    const snapshot = await send({ type: "nativeagent.page.snapshot", leaseId, tabId: 42, userSequence: 0 });
    const editable = snapshot.result.nodes.find((node) => node.name === "Notes");
    textInput.onInput = () => {
      if (stopReason === "target_changed") textInput.attributes["aria-label"] = "Different field";
      if (stopReason === "lease_revoked") void send({ type: "nativeagent.page.lease.invalidated", leaseId });
    };
    const typed = await send({
      type: "nativeagent.page.type", leaseId,
      leaseExpiresAtMs: Date.now() + (stopReason === "lease_expired" ? -1 : 60_000),
      snapshotId: snapshot.result.snapshotId, nodeId: editable.nodeId, text: "abc", delayMs: 0,
    });
    assert.equal(typed.result.completed, false);
    assert.equal(typed.result.stopReason, stopReason);
    assert.equal(typed.result.characterCount, stopReason === "lease_expired" ? 0 : 1);
    assert.equal(textInput.value, stopReason === "lease_expired" ? "" : "a");
  }
});

test("zero-delay typing yields for trusted user takeover without continuing the burst", async () => {
  textInput.value = "";
  const snapshot = await send({ type: "nativeagent.page.snapshot", leaseId: "lease-yield", tabId: 42, userSequence: 0 });
  const editable = snapshot.result.nodes.find((node) => node.name === "Notes");
  setTimeout(() => trustedInputListeners.get("pointerdown")({ isTrusted: true }), 0);
  const typed = await send({
    type: "nativeagent.page.type", leaseId: "lease-yield", leaseExpiresAtMs: Date.now() + 60_000,
    snapshotId: snapshot.result.snapshotId, nodeId: editable.nodeId, text: "a".repeat(100), delayMs: 0,
  });
  assert.equal(typed.result.completed, false);
  assert.equal(typed.result.stopReason, "user_takeover");
  assert.equal(typed.result.characterCount, 32);
  assert.equal(textInput.value.length, 32);
});

test("stale generations and password edits refuse instead of guessing", async () => {
  const snapshot = await send({
    type: "nativeagent.page.snapshot",
    leaseId: "lease-stale",
    tabId: 42,
    userSequence: 0,
  });
  const editable = snapshot.result.nodes.find((node) => node.name === "Notes");
  const passwordNode = snapshot.result.nodes.find((node) => node.value === null && node.kind === "input");

  const passwordFill = await send({
    type: "nativeagent.page.fill",
    snapshotId: snapshot.result.snapshotId,
    nodeId: passwordNode.nodeId,
    value: "do-not-write",
  });
  assert.equal(passwordFill.ok, false);
  assert.equal(passwordFill.error.code, "node_not_actionable");
  assert.equal(password.value, "hidden-secret");

  mutationCallback([]);
  const stale = await send({
    type: "nativeagent.page.fill",
    snapshotId: snapshot.result.snapshotId,
    nodeId: editable.nodeId,
    value: "stale-write",
  });
  assert.equal(stale.ok, false);
  assert.equal(stale.error.code, "snapshot_stale");
  assert.notEqual(textInput.value, "stale-write");
});
