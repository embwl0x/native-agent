import assert from "node:assert/strict";
import test from "node:test";
import { assertSnapshotSchema } from "./snapshot-schema-fixture.js";

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
  constructor(callback) { this.callback = callback; mutationCallback ??= callback; }
  observe() {}
  takeRecords() { return []; }
  disconnect() {}
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

test("native modal is a named container and blocks underlying feed actions and page scrolling", async () => {
  const dialog = new FixtureElement("dialog", { text: "Thread", parent: body });
  dialog.matches = (selector) => selector === ":modal";
  new FixtureElement("button", { text: "Back to feed", parent: dialog });
  try {
    const snapshot = (await send({ type: "nativeagent.page.snapshot", leaseId: "modal", tabId: 42, userSequence: 0 })).result;
    const modal = snapshot.nodes.find((node) => node.kind === "dialog");
    const back = snapshot.nodes.find((node) => node.name === "Back to feed");
    const behind = snapshot.nodes.find((node) => node.name === "Buy now");
    assert.ok(modal); assert.equal(back.parentNodeId, modal.nodeId);
    assert.ok(back.actions.includes("click")); assert.equal(back.states.blockedByModal, false);
    assert.deepEqual(behind.actions, []); assert.equal(behind.states.blockedByModal, true);
    const click = await send({ type: "nativeagent.page.click", snapshotId: snapshot.snapshotId, nodeId: behind.nodeId });
    assert.equal(click.error.code, "node_not_actionable");
    const scroll = await send({ type: "nativeagent.page.scroll", deltaX: 0, deltaY: 100 });
    assert.equal(scroll.error.code, "modal_target_required");
  } finally { body.children.splice(body.children.indexOf(dialog), 1); }
});

test("feed snapshots omit deep layout duplication but keep articles and correctly parent repeated controls", async () => {
  const outer = new FixtureElement("div", { text: "Repeated layout text", parent: body });
  let wrapper = outer;
  for (let i = 0; i < 550; i++) wrapper = new FixtureElement("div", { text: "Repeated layout text", parent: wrapper });
  const article = new FixtureElement("article", { text: "Second author: measured result", parent: wrapper });
  const layout = new FixtureElement("div", { text: "Reply", parent: article });
  new FixtureElement("button", { text: "Reply", parent: layout });
  const mixed = new FixtureElement("div", { text: "Important prose and a control", parent: article });
  mixed.childNodes = [{ nodeType: 3, textContent: "Important prose" }];
  new FixtureElement("button", { text: "More", parent: mixed });
  try {
    const snapshot = (await send({ type: "nativeagent.page.snapshot", leaseId: "feed", tabId: 42, userSequence: 0 })).result;
    const articleNode = snapshot.nodes.find((node) => node.kind === "article");
    assert.ok(articleNode, "layout cannot consume the 500-node budget before the feed content");
    assert.equal(snapshot.nodes.find((node) => node.name === "Reply").parentNodeId, articleNode.nodeId);
    assert.ok(snapshot.nodes.some((node) => node.text === "Important prose and a control"));
    assert.equal(snapshot.nodes.some((node) => node.text === "Repeated layout text"), false);
    assert.ok(snapshot.nodes.length < 30);
  } finally { body.children.splice(body.children.indexOf(outer), 1); }
});

test("aria-labelledby names resolve in their own root and remain action identity", async () => {
  const previous = document.getElementById;
  const label = new FixtureElement("span", { text: "Search posts" });
  document.getElementById = (id) => id === "search-label" ? label : null;
  const control = new FixtureElement("button", { text: "Icon", attrs: { "aria-labelledby": "search-label", "aria-label": "Fallback" }, parent: body });
  try {
    const snapshot = (await send({ type: "nativeagent.page.snapshot", leaseId: "labels", tabId: 42, userSequence: 0 })).result;
    const node = snapshot.nodes.find((row) => row.name === "Search posts");
    assert.ok(node);
    label.innerText = "Delete posts";
    const result = await send({ type: "nativeagent.page.click", snapshotId: snapshot.snapshotId, nodeId: node.nodeId });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "node_identity_changed");
  } finally {
    document.getElementById = previous;
    body.children.splice(body.children.indexOf(control), 1);
  }
});

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
  assert.deepEqual(actionable.actions, ["click", "double_click", "keypress", "wait", "drop"]);
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
  assert.deepEqual(scrolls.at(-1), { left: 0, top: 640, behavior: "instant" });
});

test("scroll reports clamped movement and a boundary without claiming feed completion", async () => {
  const original = window.scrollBy;
  const originalY = window.scrollY;
  const originalVisibility = document.visibilityState;
  const originalDispatch = document.dispatchEvent;
  const notifications = [];
  document.visibilityState = "hidden";
  document.dispatchEvent = (event) => { notifications.push(event); return true; };
  window.scrollY = 2100;
  window.scrollBy = function(options) {
    scrolls.push(options);
    this.scrollY = Math.max(0, Math.min(2200, this.scrollY + options.top));
  };
  try {
    const moved = (await send({ type: "nativeagent.page.scroll", deltaX: 0, deltaY: 640 })).result;
    assert.equal(moved.movedY, 100);
    assert.equal(moved.remainingDown, 0);
    assert.equal(moved.remainingUp, 2200);
    assert.equal(moved.atBottom, true);
    assert.equal(moved.scrollNotification, "supplemental_untrusted_hidden");
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].type, "scroll");
    assert.equal(notifications[0].bubbles, true);
    assert.equal(notifications[0].isTrusted, false);
    const blocked = (await send({ type: "nativeagent.page.scroll", deltaX: 0, deltaY: 640 })).result;
    assert.equal(blocked.scrolled, false);
    assert.equal(blocked.movedY, 0);
    assert.equal(notifications.length, 1);
    assert.equal(blocked.scrollNotification, "browser_managed");
    assert.equal(blocked.observationScope, "immediate_position_not_feed_completion");
    const top = (await send({ type: "nativeagent.page.scroll", deltaX: 0, deltaY: -4000 })).result;
    assert.equal(top.atTop, true);
    assert.equal(top.atBottom, false);
    assert.equal(top.remainingDown, 2200);
    assert.equal(notifications.length, 2);
    document.visibilityState = "visible";
    const visible = (await send({ type: "nativeagent.page.scroll", deltaX: 0, deltaY: 100 })).result;
    assert.equal(visible.movedY, 100);
    assert.equal(visible.scrollNotification, "browser_managed");
    assert.equal(notifications.length, 2);
  } finally {
    window.scrollBy = original; window.scrollY = originalY;
    document.visibilityState = originalVisibility; document.dispatchEvent = originalDispatch;
  }
});

test("nested scrolling measures its container independently of the page", async () => {
  const container = new FixtureElement("section", { attrs: { "aria-label": "Nested feed" }, parent: body });
  container.scrollHeight = 1000;
  container.clientHeight = 200;
  container.scrollTop = 700;
  container.scrollLeft = 0;
  container.scrollBy = function(options) { this.scrollTop = Math.min(800, this.scrollTop + options.top); };
  const originalStyle = globalThis.getComputedStyle;
  globalThis.getComputedStyle = (element) => ({ ...originalStyle(element), overflow: element === container ? "auto" : "visible" });
  const pageY = window.scrollY;
  const originalVisibility = document.visibilityState;
  document.visibilityState = "hidden";
  const notifications = [];
  container.dispatchEvent = (event) => { notifications.push(event); return true; };
  try {
    const snapshot = (await send({ type: "nativeagent.page.snapshot", leaseId: "nested-scroll", tabId: 42, userSequence: 0 })).result;
    const node = snapshot.nodes.find((node) => node.name === "Nested feed");
    const result = (await send({ type: "nativeagent.page.scroll", snapshotId: snapshot.snapshotId, targetNodeId: node.nodeId, deltaX: 0, deltaY: 400 })).result;
    assert.equal(result.coordinateScope, "element");
    assert.equal(result.movedY, 100);
    assert.equal(result.remainingDown, 0);
    assert.equal(result.atBottom, true);
    assert.equal(window.scrollY, pageY);
    assert.equal(result.scrollNotification, "supplemental_untrusted_hidden");
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].bubbles, false);
    assert.equal(notifications[0].isTrusted, false);
  } finally {
    document.visibilityState = originalVisibility;
    globalThis.getComputedStyle = originalStyle;
    body.children.splice(body.children.indexOf(container), 1);
  }
});

test("select snapshots expose exact choices and refuse disabled, changed, and unobserved choices", async () => {
  const original = select.options;
  select.options = [
    { value: "opaque-42", label: "Priority delivery", selected: true },
    { value: "retired", label: "Retired delivery", disabled: true },
    { value: "region", parentElement: { tagName: "OPTGROUP", label: "Unavailable", disabled: true } },
  ];
  async function observe() {
    const snapshot = (await send({ type: "nativeagent.page.snapshot", leaseId: "form-options", tabId: 42, userSequence: 0 })).result;
    return { snapshot, node: snapshot.nodes.find((node) => node.name === "Plan") };
  }
  async function choose(observed, value) {
    return send({ type: "nativeagent.page.select", snapshotId: observed.snapshot.snapshotId, nodeId: observed.node.nodeId, values: [value] });
  }
  try {
    let observed = await observe();
    assert.equal(observed.node.select.options[0].label, "Priority delivery");
    assert.equal(observed.node.select.options[0].value, "opaque-42");
    assert.equal(observed.node.select.options[2].group, "Unavailable");
    assert.equal(observed.node.select.options[2].disabled, true);
    assert.equal((await choose(observed, "retired")).error.code, "option_disabled");
    assert.equal((await choose(observed, "region")).error.code, "option_disabled");
    select.options[0].label = "Changed meaning";
    assert.equal((await choose(observed, "opaque-42")).error.code, "node_stale");
    select.options = Array.from({ length: 101 }, (_, i) => ({ value: String(i), selected: i === 0 }));
    observed = await observe();
    assert.equal(observed.node.select.optionCount, 101);
    assert.equal(observed.node.select.optionsTruncated, true);
    assert.equal(observed.node.select.options.length, 100);
    assert.equal((await choose(observed, "100")).error.code, "option_not_observed");
  } finally { select.options = original; }
});

test("form snapshots expose validity and native input submit actions without password state", async () => {
  const submit = new FixtureElement("input", { type: "submit", attrs: { "aria-label": "Validate form" }, parent: body });
  textInput.required = true;
  textInput.validity = { valid: false, valueMissing: true };
  password.validity = { valid: false, tooShort: true };
  try {
    const snapshot = (await send({ type: "nativeagent.page.snapshot", leaseId: "form-validation", tabId: 42, userSequence: 0 })).result;
    const field = snapshot.nodes.find((node) => node.name === "Notes");
    assert.deepEqual(field.formState.failures, ["valueMissing"]);
    assert.equal(field.formState.required, true);
    assert.equal(field.formState.valid, false);
    const button = snapshot.nodes.find((node) => node.name === "Validate form");
    assert.ok(button.actions.includes("click"));
    assert.equal(snapshot.nodes.find((node) => node.value === null && node.kind === "input" && node.actions.length === 0)?.formState, undefined);
  } finally {
    delete textInput.required; delete textInput.validity; delete password.validity;
    body.children.splice(body.children.indexOf(submit), 1);
  }
});

test("snapshot schema accepts emitted draggable, select and validity-bearing controls", async () => {
  button.draggable = true;
  textInput.required = true;
  textInput.validity = { valid: false, valueMissing: true };
  try {
    const { frame, ...page } = (await send({ type: "nativeagent.page.snapshot", leaseId: "schema-proof", tabId: 42, userSequence: 0 })).result;
    const snapshot = { ...page,
      nodes: page.nodes.map((node) => ({ ...node, frameId: 0 })),
      frames: [{ frameId: 0, parentFrameId: -1, ...frame, accessible: true, nodeCount: page.nodes.length }],
    };
    assert.ok(snapshot.nodes.some((node) => node.actions.includes("drag")));
    assert.ok(snapshot.nodes.some((node) => node.select?.options.length > 0));
    assert.ok(snapshot.nodes.some((node) => node.formState?.failures.includes("valueMissing")));
    assertSnapshotSchema(snapshot);
    const invalid = structuredClone(snapshot);
    invalid.nodes[0].actions.push("invented_action");
    assert.throws(() => assertSnapshotSchema(invalid));
    const malformed = structuredClone(snapshot);
    malformed.nodes.find((node) => node.formState).formState.valid = "false";
    assert.throws(() => assertSnapshotSchema(malformed));
  } finally {
    delete button.draggable;
    delete textInput.required;
    delete textInput.validity;
  }
});

test("HTML drag honors acceptance, cancellation and endpoint changes without trusted input", async () => {
  const originalTransfer = globalThis.DataTransfer, originalDragEvent = globalThis.DragEvent;
  globalThis.DataTransfer = class { constructor() { this.effectAllowed = "all"; this.dropEffect = "none"; } };
  globalThis.DragEvent = class extends Event {
    constructor(type, init) { super(type, init); this.dataTransfer = init.dataTransfer; }
  };
  const source = new FixtureElement("article", { text: "Move card", attrs: { "aria-label": "Move card" }, parent: body });
  const target = new FixtureElement("section", { attrs: { "aria-label": "Done lane" }, parent: body });
  source.draggable = true;
  let mode = "accept", events = [];
  source.dispatchEvent = (event) => {
    events.push(event);
    if (event.type === "dragstart" && mode === "cancel") return false;
    if (event.type === "dragstart" && mode === "changed") target.attributes["aria-label"] = "Different target";
    return true;
  };
  target.dispatchEvent = (event) => {
    events.push(event);
    return !(event.type === "dragover" && ["accept", "acknowledge"].includes(mode))
      && !(event.type === "drop" && mode === "acknowledge");
  };
  async function drag() {
    events = [];
    target.attributes["aria-label"] = "Done lane";
    const snapshot = (await send({ type: "nativeagent.page.snapshot", leaseId: "drag-proof", tabId: 42, userSequence: 0 })).result;
    const from = snapshot.nodes.find((node) => node.name === "Move card");
    const to = snapshot.nodes.find((node) => node.name === "Done lane");
    return send({ type: "nativeagent.page.drag", snapshotId: snapshot.snapshotId, nodeId: from.nodeId, targetNodeId: to.nodeId });
  }
  try {
    const unconfirmed = (await drag()).result;
    assert.equal(unconfirmed.dropDispatched, true);
    assert.equal(unconfirmed.dropAcknowledged, false);
    assert.equal(unconfirmed.reason, "dispatched_unconfirmed");
    assert.deepEqual(events.map((event) => event.type), ["dragstart", "dragenter", "dragover", "drop", "dragend"]);
    assert.ok(events.every((event) => !event.isTrusted));
    mode = "acknowledge";
    assert.equal((await drag()).result.dropAcknowledged, true);
    mode = "reject";
    assert.equal((await drag()).result.reason, "target_did_not_accept");
    assert.ok(!events.some((event) => event.type === "drop"));
    mode = "cancel";
    assert.equal((await drag()).result.reason, "dragstart_cancelled");
    assert.deepEqual(events.map((event) => event.type), ["dragstart", "dragend"]);
    mode = "changed";
    assert.equal((await drag()).error.code, "action_outcome_unknown");
    assert.ok(!events.some((event) => event.type === "drop"));
  } finally {
    globalThis.DataTransfer = originalTransfer; globalThis.DragEvent = originalDragEvent;
    body.children.splice(body.children.indexOf(source), 1); body.children.splice(body.children.indexOf(target), 1);
  }
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

test("unrelated feed updates retain only unchanged navigation clicks", async () => {
  const nav = new FixtureElement("nav", { parent: body });
  const link = new FixtureElement("a", { text: "Explore", parent: nav });
  link.href = "https://example.com/explore";
  try {
    const read = async () => (await send({ type: "nativeagent.page.snapshot", leaseId: "nav", tabId: 42, userSequence: 0 })).result;
    let snapshot = await read();
    const click = (snapshot) => send({ type: "nativeagent.page.click", snapshotId: snapshot.snapshotId,
      nodeId: snapshot.nodes.find((node) => node.name === "Explore" && node.kind === "link").nodeId });
    mutationCallback([{ type: "characterData", target: heading }]);
    assert.equal((await click(snapshot)).ok, true);
    const fill = await send({ type: "nativeagent.page.fill", snapshotId: snapshot.snapshotId,
      nodeId: snapshot.nodes.find((node) => node.name === "Notes").nodeId, value: "must refuse" });
    assert.equal(fill.error.code, "snapshot_stale");
    link.href = "https://example.com/logout";
    assert.equal((await click(snapshot)).error.code, "snapshot_stale");
    link.href = "https://example.com/explore";
    snapshot = await read();
    mutationCallback([{ type: "childList", target: nav }]);
    assert.equal((await click(snapshot)).error.code, "snapshot_stale");
    snapshot = await read();
    const dialog = new FixtureElement("dialog", { text: "Modal", parent: body });
    dialog.matches = (selector) => selector === ":modal";
    mutationCallback([{ type: "childList", target: body, addedNodes: [dialog] }]);
    assert.equal((await click(snapshot)).error.code, "snapshot_stale");
    body.children = body.children.filter((child) => child !== dialog);
    snapshot = await read();
    mutationCallback([{ type: "childList", target: body, removedNodes: [nav] }]);
    assert.equal((await click(snapshot)).error.code, "snapshot_stale");
  } finally {
    body.children = body.children.filter((child) => child !== nav && child.tagName !== "DIALOG");
  }
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
