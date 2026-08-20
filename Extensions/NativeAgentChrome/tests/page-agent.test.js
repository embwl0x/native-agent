import assert from "node:assert/strict";
import test from "node:test";

const messageListeners = [];
const clicks = [];
const scrolls = [];
const editableEvents = [];
const keyboardEvents = [];
const mouseEvents = [];
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
    snapshotId: snapshot.result.snapshotId,
    nodeId: editable.nodeId,
    text: " + more",
    delayMs: 0,
  });
  assert.equal(typed.ok, true);
  assert.equal(typed.result.characterCount, 7);
  assert.equal(textInput.value, "replacement + more");
  assert.equal(textInput.focused, true);
  assert.ok(editableEvents.includes("input"));
  assert.ok(editableEvents.includes("change"));

  const waited = await send({
    type: "nativeagent.page.wait",
    snapshotId: snapshot.result.snapshotId,
    nodeId: editable.nodeId,
    state: "enabled",
    timeoutMs: 100,
  });
  assert.equal(waited.ok, true);
  assert.equal(waited.result.matched, true);
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
