import assert from "node:assert/strict";
import test from "node:test";

const nativeMessages = [];
const nativeMessageListeners = [];
const runtimeMessageListeners = [];
const activatedListeners = [];
const removedListeners = [];
const updatedListeners = [];
const alarmListeners = [];
const createdTabs = [];
const removedTabs = [];
const tabs = new Map();
let sessionStorage = {};
let nextCreatedTabId = 42;
let rejectNextTypeReply = false;
let typeDispatchCount = 0;
let nextTypeResult = null;
let nextFillOrSelectError = null;
let fillOrSelectDispatchCount = 0;
const rejectedMutationReplies = new Set();
const mutationDispatchCounts = new Map();
const invalidatedLeases = [];
let nextSnapshotNodes = null;
let nextDragResult = null;
let lastClickedLocalNode = null;
let snapshotReplyHook = null;
let waitReplyHook = null;
let tabUpdateHook = null;
let tabGetHook = null;
let webFrames = [{ frameId: 0, parentFrameId: -1, url: "https://example.com/fixture" }];

const nativePort = {
  onMessage: { addListener(listener) { nativeMessageListeners.push(listener); } },
  onDisconnect: { addListener() {} },
  postMessage(message) { nativeMessages.push(message); },
};

globalThis.chrome = {
  alarms: {
    async create() {},
    async clear() { return true; },
    onAlarm: { addListener(listener) { alarmListeners.push(listener); } },
  },
  runtime: {
    lastError: undefined,
    connectNative(hostId) {
      assert.equal(hostId, "com.nativeagent.chrome");
      return nativePort;
    },
    getManifest() { return { version: "0.1.0" }; },
    getURL(path) { return `chrome-extension://fixture/${path}`; },
    onInstalled: { addListener() {} },
    onMessage: { addListener(listener) { runtimeMessageListeners.push(listener); } },
    onStartup: { addListener() {} },
  },
  storage: {
    session: {
      async get() { return sessionStorage; },
      async set(value) { sessionStorage = { ...sessionStorage, ...structuredClone(value) }; },
    },
  },
  webNavigation: {
    async getAllFrames() { return structuredClone(webFrames); },
  },
  windows: {
    async getLastFocused() { return { id: 7, focused: true, type: "normal" }; },
    async create(options) {
      assert.equal(options.focused, false);
      const anchor = { id: 10000, windowId: 7, active: true, url: options.url };
      tabs.set(anchor.id, anchor);
      return { id: 7, focused: false, type: "normal", tabs: [anchor] };
    },
    async get(id) { return { id, focused: false, type: "normal" }; },
  },
  tabGroups: {
    async query() { return []; },
    async get(id) { return { id, windowId: 7 }; },
    async update() {},
  },
  tabs: {
    async group(options) {
      for (const id of options.tabIds) tabs.get(id).groupId = 1;
      return 1;
    },
    async create(options) {
      createdTabs.push(structuredClone(options));
      const tab = {
        id: nextCreatedTabId++,
        windowId: 7,
        active: options.active,
        title: "",
        url: options.url ?? "chrome://newtab/",
      };
      tabs.set(tab.id, tab);
      return tab;
    },
    async get(tabId) {
      const tab = tabs.get(tabId);
      if (!tab) throw new Error("tab missing");
      if (tabGetHook) await tabGetHook(tab);
      return structuredClone(tab);
    },
    async update(tabId, options) {
      assert.equal("active" in options, false, "navigation must never request tab activation");
      const tab = tabs.get(tabId);
      if (!tab) throw new Error("tab missing");
      tab.url = options.url;
      tab.status = "complete";
      if (tabUpdateHook) await tabUpdateHook(tab);
      return structuredClone(tab);
    },
    async sendMessage(tabId, message, options = {}) {
      if (message.type === "nativeagent.page.lease.invalidated") {
        invalidatedLeases.push(message.leaseId);
        return { ok: true, result: { invalidated: true } };
      }
      assert.ok(tabs.has(tabId));
      if (message.type === "nativeagent.page.snapshot") {
        const nodes = nextSnapshotNodes ?? [{ nodeId: "n1", parentNodeId: null, actions: ["click", "fill", "type", "select", "keypress", "set_checked", "double_click", "wait"] }];
        nextSnapshotNodes = null;
        if (snapshotReplyHook) await snapshotReplyHook(tabId, options.frameId ?? 0);
        return { ok: true, result: {
          snapshotId: `snapshot-frame-${options.frameId ?? 0}`, leaseId: message.leaseId, tabId,
          userSequence: message.userSequence,
          url: webFrames.find((frame) => frame.frameId === (options.frameId ?? 0))?.url,
          title: options.frameId === 0 ? "Fixture" : "Child",
          language: "en",
          viewport: { width: 1200, height: 800, scrollX: 0, scrollY: 0, documentWidth: 1200, documentHeight: 2000 },
          summary: { text: options.frameId === 0 ? "Top frame" : "Child frame", nodeCount: 1, truncated: false, truncationReasons: [] },
          frame: { name: options.frameId === 0 ? "Fixture" : "Child", url: webFrames.find((frame) => frame.frameId === (options.frameId ?? 0))?.url },
          nodes,
        } };
      }
      if (["nativeagent.page.click", "nativeagent.page.scroll"].includes(message.type)) {
        mutationDispatchCounts.set(message.type, (mutationDispatchCounts.get(message.type) ?? 0) + 1);
        if (rejectedMutationReplies.delete(message.type)) throw new Error("frame navigated after dispatch");
      }
      if (message.type === "nativeagent.page.click") {
        lastClickedLocalNode = message.nodeId;
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, clicked: true } };
      }
      if (["nativeagent.page.fill", "nativeagent.page.select"].includes(message.type)) {
        fillOrSelectDispatchCount += 1;
        if (nextFillOrSelectError) {
          const error = nextFillOrSelectError;
          nextFillOrSelectError = null;
          return { ok: false, error };
        }
      }
      if (message.type === "nativeagent.page.fill") {
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, filled: true, valueLength: message.value.length } };
      }
      if (message.type === "nativeagent.page.type") {
        typeDispatchCount += 1;
        assert.equal(typeof message.leaseId, "string");
        assert.ok(message.leaseExpiresAtMs > Date.now());
        if (rejectNextTypeReply) {
          rejectNextTypeReply = false;
          throw new Error("frame navigated");
        }
        const result = nextTypeResult ?? { snapshotId: message.snapshotId, nodeId: message.nodeId, typed: true, completed: true, characterCount: Array.from(message.text).length };
        nextTypeResult = null;
        return { ok: true, result };
      }
      if (message.type === "nativeagent.page.select") {
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, selected: true, values: message.values } };
      }
      if (message.type === "nativeagent.page.keypress") {
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, keypressed: true, key: message.key } };
      }
      if (message.type === "nativeagent.page.set_checked") {
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, setChecked: true, checked: message.checked } };
      }
      if (message.type === "nativeagent.page.double_click") {
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, doubleClicked: true } };
      }
      if (message.type === "nativeagent.page.drag") {
        const result = nextDragResult ?? { dropDispatched: true, targetNodeId: message.targetNodeId };
        nextDragResult = null;
        return { ok: true, result };
      }
      if (message.type === "nativeagent.page.wait") {
        assert.equal(typeof message.leaseId, "string");
        assert.ok(Number.isFinite(message.leaseExpiresAtMs));
        if (waitReplyHook) await waitReplyHook(tabId, message);
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, state: message.state, matched: true } };
      }
      if (message.type === "nativeagent.page.scroll") {
        return { ok: true, result: { scrolled: true, scrollY: message.deltaY } };
      }
      throw new Error("unexpected page message");
    },
    async remove(tabId) {
      removedTabs.push(tabId);
      tabs.delete(tabId);
    },
    onActivated: { addListener(listener) { activatedListeners.push(listener); } },
    onRemoved: { addListener(listener) { removedListeners.push(listener); } },
    onUpdated: {
      addListener(listener) { updatedListeners.push(listener); },
      removeListener(listener) {
        const index = updatedListeners.indexOf(listener);
        if (index >= 0) updatedListeners.splice(index, 1);
      },
    },
  },
};

await import("../src/background.js");

function request(id, action, payload = {}) {
  return { version: 1, type: "request", id, action, payload };
}

async function waitFor(predicate, description) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const value = nativeMessages.find(predicate);
    if (value) return value;
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.fail(`timed out waiting for ${description}`);
}

async function sendRequest(id, action, payload = {}) {
  nativeMessageListeners[0](request(id, action, payload));
  return waitFor((message) => message.type === "response" && message.id === id, id);
}

function eventFor(name, leaseId) {
  return waitFor(
    (message) => message.type === "event"
      && message.event === name
      && message.payload.leaseId === leaseId,
    `${name}:${leaseId}`,
  );
}

test("background creates inactive leases, renews, and explicitly releases", async () => {
  const acquire = await sendRequest("acquire-created", "lease.acquire", {
    mode: "create",
    initialUrl: "https://example.com/",
    leaseDurationMs: 30_000,
  });
  assert.equal(acquire.ok, true);
  assert.deepEqual(createdTabs[0], { windowId: 7, active: false, url: "https://example.com/" });
  assert.equal(acquire.result.originalTab.active, false);
  assert.ok(sessionStorage.nativeAgentTabLeasesV1.some(
    (lease) => lease.leaseId === acquire.result.leaseId,
  ));
  await eventFor("lease.granted", acquire.result.leaseId);

  const renew = await sendRequest("renew-created", "lease.renew", {
    leaseId: acquire.result.leaseId,
    expectedUserSequence: 0,
    leaseDurationMs: 45_000,
  });
  assert.equal(renew.ok, true);
  assert.ok(Date.parse(renew.result.expiresAt) >= Date.parse(acquire.result.expiresAt));
  await eventFor("lease.renewed", acquire.result.leaseId);

  const release = await sendRequest("release-created", "lease.release", {
    leaseId: acquire.result.leaseId,
  });
  assert.equal(release.ok, true);
  assert.equal(release.result.tabClosed, true);
  assert.ok(removedTabs.includes(acquire.result.tabId));
  assert.equal(sessionStorage.nativeAgentTabLeasesV1.length, 0);
  const released = await eventFor("lease.released", acquire.result.leaseId);
  assert.equal(released.payload.reason, "host_released");
});

test("every physical touch path terminally yields a claimed lease", async () => {
  const paths = [
    ["pointer", "user_pointer"],
    ["keyboard", "user_keyboard"],
    ["scroll", "user_scroll"],
    ["touch", "user_touch"],
  ];
  let tabId = 100;
  for (const [kind, reason] of paths) {
    const tab = { id: tabId++, windowId: 9, active: false, title: `Tab ${kind}`, url: `https://example.com/${kind}` };
    tabs.set(tab.id, tab);
    const acquire = await sendRequest(`acquire-${kind}`, "lease.acquire", {
      mode: "claim",
      tabId: tab.id,
      expectedTab: { title: tab.title, url: tab.url },
    });
    assert.equal(acquire.ok, true);
    runtimeMessageListeners[0]({ type: "nativeagent.user-touch", kind }, { tab: { id: tab.id } });
    const yielded = await eventFor("lease.yielded", acquire.result.leaseId);
    assert.equal(yielded.payload.reason, reason);
    assert.equal(yielded.payload.userSequence, 1);
    assert.equal(sessionStorage.nativeAgentTabLeasesV1.length, 0);
    assert.equal(removedTabs.includes(tab.id), false, "yield must leave the user's tab open");

    const renew = await sendRequest(`renew-after-${kind}`, "lease.renew", {
      leaseId: acquire.result.leaseId,
      expectedUserSequence: 1,
    });
    assert.equal(renew.ok, false);
    assert.equal(renew.error.code, "lease_not_found");
  }
});

test("activating a leased tab yields without any extension focus request", async () => {
  const tab = { id: 200, windowId: 11, active: false, title: "Background", url: "https://example.com/background" };
  tabs.set(tab.id, tab);
  const acquire = await sendRequest("acquire-activation", "lease.acquire", {
    mode: "claim",
    tabId: tab.id,
    expectedTab: { title: tab.title, url: tab.url },
  });
  activatedListeners[0]({ tabId: tab.id, windowId: tab.windowId });
  const yielded = await eventFor("lease.yielded", acquire.result.leaseId);
  assert.equal(yielded.payload.reason, "tab_activated");
  assert.ok(createdTabs.every((options) => options.active === false));
  assert.equal("highlight" in chrome.tabs, false, "extension has no tab-highlighting primitive");
});

test("closing a leased tab releases and notifies the host", async () => {
  const tab = { id: 300, windowId: 12, active: false, title: "Closing", url: "https://example.com/closing" };
  tabs.set(tab.id, tab);
  const acquire = await sendRequest("acquire-closing", "lease.acquire", {
    mode: "claim",
    tabId: tab.id,
    expectedTab: { title: tab.title, url: tab.url },
  });
  removedListeners[0](tab.id, { windowId: tab.windowId, isWindowClosing: false });
  const released = await eventFor("lease.released", acquire.result.leaseId);
  assert.equal(released.payload.reason, "tab_closed");
  assert.equal(sessionStorage.nativeAgentTabLeasesV1.length, 0);
});

test("navigate, structured snapshot, fluid form acts, wait, and scroll round-trip on one lease", async () => {
  const acquire = await sendRequest("acquire-actions", "lease.acquire", { mode: "create" });
  const lease = acquire.result;
  const navigate = await sendRequest("navigate-actions", "navigate", {
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
    url: "https://example.com/fixture",
  });
  assert.equal(navigate.ok, true);
  assert.equal(navigate.result.url, "https://example.com/fixture");

  const snapshot = await sendRequest("snapshot-actions", "page.snapshot.read", {
    leaseId: lease.leaseId,
  });
  assert.ok(snapshot.result.snapshotId);
  assert.equal(snapshot.result.nodes[0].nodeId, "n1");

  const click = await sendRequest("click-actions", "page.element.click", {
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId,
    nodeId: snapshot.result.nodes[0].nodeId,
  });
  assert.equal(click.result.clicked, true);

  const fill = await sendRequest("fill-actions", "page.element.fill", {
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId,
    nodeId: snapshot.result.nodes[0].nodeId,
    value: "replacement",
  });
  assert.equal(fill.result.filled, true);
  assert.equal(fill.result.outcome, "succeeded");
  assert.equal(fill.result.receipt.action, "fill");
  assert.equal(fill.result.receipt.leaseId, lease.leaseId);

  const typed = await sendRequest("type-actions", "page.element.type", {
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId,
    nodeId: snapshot.result.nodes[0].nodeId,
    text: " appended",
    delayMs: 0,
  });
  assert.equal(typed.result.typed, true);
  assert.equal(typed.result.receipt.outcome, "succeeded");

  for (const [id, action, extra, resultKey] of [
    ["select-actions", "page.element.select", { values: ["pro"] }, "selected"],
    ["keypress-actions", "page.element.keypress", { key: "Enter" }, "keypressed"],
    ["checked-actions", "page.element.set_checked", { checked: true }, "setChecked"],
    ["double-actions", "page.element.double_click", {}, "doubleClicked"],
  ]) {
    const acted = await sendRequest(id, action, {
      leaseId: lease.leaseId,
      expectedUserSequence: 0,
      snapshotId: snapshot.result.snapshotId,
      nodeId: snapshot.result.nodes[0].nodeId,
      ...extra,
    });
    assert.equal(acted.result[resultKey], true);
    assert.equal(acted.result.receipt.outcome, "succeeded");
  }

  const waited = await sendRequest("wait-actions", "page.wait", {
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
    condition: "element_state",
    snapshotId: snapshot.result.snapshotId,
    nodeId: snapshot.result.nodes[0].nodeId,
    state: "enabled",
    timeoutMs: 100,
  });
  assert.equal(waited.result.matched, true);
  assert.equal(waited.result.receipt.verification, "verified");

  const navigationWait = await sendRequest("wait-navigation", "page.wait", {
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
    condition: "navigation_settled",
    timeoutMs: 100,
  });
  assert.equal(navigationWait.result.matched, true);
  assert.equal(navigationWait.result.receipt.outcome, "succeeded");

  const scroll = await sendRequest("scroll-actions", "page.scroll", {
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId,
    deltaX: 0,
    deltaY: 640,
  });
  assert.equal(scroll.result.scrolled, true);
  assert.equal(scroll.result.scrollY, 640);

  nextSnapshotNodes = [
    { nodeId: "drag-source", parentNodeId: null, actions: ["drag"] },
    { nodeId: "drag-target", parentNodeId: null, actions: ["drop"] },
  ];
  const dragSnapshot = await sendRequest("drag-snapshot", "page.snapshot.read", { leaseId: lease.leaseId });
  const dragPayload = {
    leaseId: lease.leaseId, expectedUserSequence: 0, snapshotId: dragSnapshot.result.snapshotId,
    nodeId: dragSnapshot.result.nodes[0].nodeId, targetNodeId: dragSnapshot.result.nodes[1].nodeId,
  };
  for (const acknowledged of [false, true]) {
    nextDragResult = { dropDispatched: true, dropAcknowledged: acknowledged };
    const dragged = await sendRequest(`drag-${acknowledged}`, "page.element.drag", dragPayload);
    assert.equal(dragged.result.receipt.outcome, acknowledged ? "succeeded" : "outcome_unknown");
    assert.equal(dragged.result.receipt.verification, acknowledged ? "page_acknowledged" : "not_verified");
  }
});

test("frame walker aggregates frame-scoped nodes and routes acts to their owning frame", async () => {
  webFrames = [
    { frameId: 0, parentFrameId: -1, url: "https://example.com/top" },
    { frameId: 7, parentFrameId: 0, url: "https://example.net/child" },
  ];
  const acquire = await sendRequest("acquire-frames", "lease.acquire", { mode: "create" });
  const snapshot = await sendRequest("snapshot-frames", "page.snapshot.read", {
    leaseId: acquire.result.leaseId,
  });
  assert.deepEqual(snapshot.result.frames.map((frame) => frame.frameId), [0, 7]);
  assert.equal(snapshot.result.nodes.length, 2);
  const childNode = snapshot.result.nodes.find((node) => node.frameId === 7);
  const crossDrag = await sendRequest("cross-frame-drag", "page.element.drag", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0, snapshotId: snapshot.result.snapshotId,
    nodeId: snapshot.result.nodes.find((node) => node.frameId === 0).nodeId, targetNodeId: childNode.nodeId,
  });
  assert.equal(crossDrag.ok, false);
  assert.equal(crossDrag.error.code, "cross_frame_drag_unsupported");
  assert.ok(childNode);
  const acted = await sendRequest("keypress-child-frame", "page.element.keypress", {
    leaseId: acquire.result.leaseId,
    expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId,
    nodeId: childNode.nodeId,
    key: "Enter",
  });
  assert.equal(acted.result.frameId, 7);
  runtimeMessageListeners[0](
    { type: "nativeagent.page.mutated", snapshotIds: ["snapshot-frame-7"] },
    { tab: { id: acquire.result.tabId }, frameId: 7 },
  );
  const stale = await sendRequest("keypress-stale-child-frame", "page.element.keypress", {
    leaseId: acquire.result.leaseId,
    expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId,
    nodeId: childNode.nodeId,
    key: "Enter",
  });
  assert.equal(stale.ok, false);
  assert.equal(stale.error.code, "snapshot_stale");
  webFrames = [{ frameId: 0, parentFrameId: -1, url: "https://example.com/fixture" }];
});

test("fill and select readback failures return outcome_unknown receipts without retrying", async () => {
  for (const [action, fields] of [["fill", { value: "requested" }], ["select", { values: ["pro"] }]]) {
    const acquire = await sendRequest(`acquire-${action}-readback`, "lease.acquire", { mode: "create" });
    const snapshot = await sendRequest(`snapshot-${action}-readback`, "page.snapshot.read", { leaseId: acquire.result.leaseId });
    const before = fillOrSelectDispatchCount;
    nextFillOrSelectError = { code: "action_outcome_unknown", message: "Immediate state unconfirmed. Observe before retrying." };
    const response = await sendRequest(`${action}-readback`, `page.element.${action}`, {
      leaseId: acquire.result.leaseId,
      expectedUserSequence: 0,
      snapshotId: snapshot.result.snapshotId,
      nodeId: snapshot.result.nodes[0].nodeId,
      ...fields,
    });
    assert.equal(response.ok, true);
    assert.equal(response.result.outcome, "outcome_unknown");
    assert.equal(response.result.receipt.verification, "outcome_unknown");
    assert.equal(response.result.receipt.retry, "never_automatic");
    assert.equal(fillOrSelectDispatchCount, before + 1);
  }
});

test("lost type reply returns one outcome_unknown receipt and never retries", async () => {
  const acquire = await sendRequest("acquire-unknown", "lease.acquire", { mode: "create" });
  const snapshot = await sendRequest("snapshot-unknown", "page.snapshot.read", {
    leaseId: acquire.result.leaseId,
  });
  const before = typeDispatchCount;
  rejectNextTypeReply = true;
  const typed = await sendRequest("type-unknown", "page.element.type", {
    leaseId: acquire.result.leaseId,
    expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId,
    nodeId: snapshot.result.nodes[0].nodeId,
    text: "possibly submitted",
  });
  assert.equal(typed.ok, true);
  assert.equal(typed.result.outcome, "outcome_unknown");
  assert.equal(typed.result.receipt.verification, "outcome_unknown");
  assert.equal(typed.result.receipt.retry, "never_automatic");
  assert.equal(typeDispatchCount, before + 1);
});

test("lost click and scroll replies return one outcome_unknown receipt without retrying", async () => {
  for (const [action, messageType, fields] of [
    ["page.element.click", "nativeagent.page.click", { nodeId: "n1" }],
    ["page.scroll", "nativeagent.page.scroll", { deltaX: 0, deltaY: 240 }],
  ]) {
    const suffix = action.replaceAll(".", "-");
    const acquire = await sendRequest(`acquire-${suffix}-unknown`, "lease.acquire", { mode: "create" });
    const snapshot = await sendRequest(`snapshot-${suffix}-unknown`, "page.snapshot.read", {
      leaseId: acquire.result.leaseId,
    });
    const before = mutationDispatchCounts.get(messageType) ?? 0;
    rejectedMutationReplies.add(messageType);
    const response = await sendRequest(`${suffix}-unknown`, action, {
      leaseId: acquire.result.leaseId,
      expectedUserSequence: 0,
      snapshotId: snapshot.result.snapshotId,
      ...fields,
    });
    assert.equal(response.ok, true);
    assert.equal(response.result.outcome, "outcome_unknown");
    assert.equal(response.result.receipt.verification, "outcome_unknown");
    assert.equal(response.result.receipt.retry, "never_automatic");
    assert.equal(mutationDispatchCounts.get(messageType), before + 1);
  }
});

test("partial type progress stays partial and lease release reaches in-flight page actions", async () => {
  const acquire = await sendRequest("acquire-partial", "lease.acquire", { mode: "create" });
  const snapshot = await sendRequest("snapshot-partial", "page.snapshot.read", { leaseId: acquire.result.leaseId });
  nextTypeResult = {
    typed: false, completed: false, characterCount: 1, requestedCharacterCount: 3,
    remainingCharacterCount: 2, nextCharacterIndex: 1, nextUTF16Offset: 2,
    characterUnit: "unicode_code_point", stopReason: "execution_deadline",
  };
  const typed = await sendRequest("type-partial", "page.element.type", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId, nodeId: snapshot.result.nodes[0].nodeId, text: "🙂xy",
  });
  assert.equal(typed.ok, true);
  assert.equal(typed.result.outcome, "partially_completed");
  assert.equal(typed.result.characterCount, 1);
  assert.equal(typed.result.nextUTF16Offset, 2);
  assert.equal(typed.result.receipt.retry, "fresh_snapshot_then_remaining_text_only");
  await sendRequest("release-partial", "lease.release", { leaseId: acquire.result.leaseId, closeCreatedTab: false });
  assert.ok(invalidatedLeases.includes(acquire.result.leaseId));
});

test("encoded snapshot budget preserves retained targets and truthful counts", async () => {
  const acquire = await sendRequest("acquire-byte-budget", "lease.acquire", { mode: "create" });
  nextSnapshotNodes = Array.from({ length: 500 }, (_, index) => ({
    nodeId: `source-${index}`, parentNodeId: index === 0 ? null : "source-0",
    kind: "link", role: "link", name: "🙂".repeat(100), text: "界".repeat(200), value: null,
    url: `https://example.com/${"a".repeat(2_028)}`, actions: ["click"],
    visible: true, bounds: { x: 0, y: index, width: 100, height: 20 },
  }));
  const snapshot = await sendRequest("snapshot-byte-budget", "page.snapshot.read", { leaseId: acquire.result.leaseId });
  assert.equal(snapshot.ok, true);
  const retained = snapshot.result.nodes;
  assert.ok(retained.length > 0 && retained.length < 500);
  assert.equal(snapshot.result.summary.nodeCount, retained.length);
  assert.equal(snapshot.result.frames[0].nodeCount, retained.length);
  assert.equal(snapshot.result.summary.truncated, true);
  assert.ok(snapshot.result.summary.truncationReasons.includes("encoded_size_limit"));
  assert.ok(new TextEncoder().encode(JSON.stringify(snapshot)).byteLength < 1_048_576);
  const clicked = await sendRequest("click-byte-budget", "page.element.click", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId, nodeId: retained.at(-1).nodeId,
  });
  assert.equal(clicked.ok, true);
  assert.equal(lastClickedLocalNode, `source-${retained.length - 1}`);
  const omitted = await sendRequest("click-omitted-byte-budget", "page.element.click", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0,
    snapshotId: snapshot.result.snapshotId, nodeId: `n${retained.length + 1}`,
  });
  assert.equal(omitted.ok, false);
  assert.equal(omitted.error.code, "node_stale");
});

test("in-flight snapshot capture preserves invalidation and takeover evidence", async (t) => {
  webFrames = [
    { frameId: 0, parentFrameId: -1, url: "https://example.com/top" },
    { frameId: 7, parentFrameId: 0, url: "https://example.net/child" },
  ];
  t.after(() => {
    snapshotReplyHook = null;
    webFrames = [{ frameId: 0, parentFrameId: -1, url: "https://example.com/fixture" }];
  });
  for (const cause of ["mutation", "takeover"]) {
    const acquire = await sendRequest(`acquire-inflight-${cause}`, "lease.acquire", { mode: "create" });
    snapshotReplyHook = async (tabId, frameId) => {
      if (frameId !== 7) return;
      snapshotReplyHook = null;
      if (cause === "mutation") {
        runtimeMessageListeners[0](
          { type: "nativeagent.page.mutated", snapshotIds: ["snapshot-frame-0"] },
          { tab: { id: tabId }, frameId: 0 },
        );
      } else {
        activatedListeners[0]({ tabId });
        await eventFor("lease.yielded", acquire.result.leaseId);
      }
    };
    const snapshot = await sendRequest(`snapshot-inflight-${cause}`, "page.snapshot.read", { leaseId: acquire.result.leaseId });
    assert.equal(snapshot.ok, false);
    assert.equal(snapshot.error.code, cause === "mutation" ? "snapshot_stale" : "lease_not_found");
    if (cause === "mutation") {
      const retry = await sendRequest("snapshot-inflight-retry", "page.snapshot.read", { leaseId: acquire.result.leaseId });
      assert.equal(retry.ok, true);
      assert.equal(retry.result.nodes.length, 2);
    }
  }
});

test("a newer snapshot supersedes an older pending capture without stale publication", async (t) => {
  t.after(() => { snapshotReplyHook = null; });
  const acquire = await sendRequest("acquire-superseded", "lease.acquire", { mode: "create" });
  let releaseFirst;
  let firstEntered;
  const paused = new Promise((resolve) => { releaseFirst = resolve; });
  const entered = new Promise((resolve) => { firstEntered = resolve; });
  snapshotReplyHook = async () => {
    snapshotReplyHook = null;
    firstEntered();
    await paused;
  };
  const first = sendRequest("snapshot-superseded-first", "page.snapshot.read", { leaseId: acquire.result.leaseId });
  await entered;
  const second = await sendRequest("snapshot-superseded-second", "page.snapshot.read", { leaseId: acquire.result.leaseId });
  releaseFirst();
  const obsolete = await first;
  assert.equal(second.ok, true);
  assert.equal(obsolete.ok, false);
  assert.equal(obsolete.error.code, "snapshot_superseded");
});

test("navigation completion after takeover is unknown rather than a false success", async (t) => {
  t.after(() => { tabUpdateHook = null; });
  const acquire = await sendRequest("acquire-navigation-takeover", "lease.acquire", { mode: "create" });
  tabUpdateHook = async (tab) => {
    tabUpdateHook = null;
    activatedListeners[0]({ tabId: tab.id });
    await eventFor("lease.yielded", acquire.result.leaseId);
  };
  const response = await sendRequest("navigate-takeover", "navigate", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0, url: "https://example.com/requested",
  });
  assert.equal(response.ok, true);
  assert.equal(response.result.outcome, "outcome_unknown");
  assert.equal(response.result.receipt.retry, "never_automatic");
  assert.equal(response.result.verified, false);
  assert.equal(updatedListeners.length, 0);
});

test("navigation completion preserves redirects without claiming verified causality", async (t) => {
  t.after(() => { tabUpdateHook = null; });
  const acquire = await sendRequest("acquire-navigation-redirect", "lease.acquire", { mode: "create" });
  tabUpdateHook = async (tab) => { tabUpdateHook = null; tab.url = "https://example.com/redirected"; };
  const response = await sendRequest("navigate-redirect", "navigate", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0, url: "https://example.com/requested",
  });
  assert.equal(response.result.status, "complete");
  assert.equal(response.result.requestedUrl, "https://example.com/requested");
  assert.equal(response.result.url, "https://example.com/redirected");
  assert.equal(response.result.verified, false);
  assert.equal(response.result.receipt.verification, "not_verified");
});

test("superseded navigation cannot claim the newer page as its own completion", async (t) => {
  t.after(() => { tabUpdateHook = null; });
  const acquire = await sendRequest("acquire-navigation-superseded", "lease.acquire", { mode: "create" });
  let releaseFirst;
  let firstEntered;
  const paused = new Promise((resolve) => { releaseFirst = resolve; });
  const entered = new Promise((resolve) => { firstEntered = resolve; });
  tabUpdateHook = async () => { tabUpdateHook = null; firstEntered(); await paused; };
  const first = sendRequest("navigate-superseded-first", "navigate", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0, url: "https://example.com/first",
  });
  await entered;
  const second = await sendRequest("navigate-superseded-second", "navigate", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0, url: "https://example.com/second",
  });
  releaseFirst();
  const obsolete = await first;
  assert.equal(obsolete.result.outcome, "outcome_unknown");
  assert.equal(obsolete.result.error.code, "navigation_superseded");
  assert.equal(second.result.url, "https://example.com/second");
  assert.equal(second.result.requestedUrl, "https://example.com/second");
  assert.equal(second.result.status, "complete");
  assert.equal(second.result.verified, false);
  assert.equal(second.result.receipt.verification, "not_verified");
  assert.equal(updatedListeners.length, 0);
});

test("pending navigation wait is released promptly on lease takeover", async (t) => {
  t.after(() => { tabUpdateHook = null; });
  const acquire = await sendRequest("acquire-navigation-pending", "lease.acquire", { mode: "create" });
  tabUpdateHook = async (tab) => { tabUpdateHook = null; tab.status = "loading"; };
  const pending = sendRequest("navigate-pending-takeover", "navigate", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0, url: "https://example.com/loading",
  });
  for (let count = 0; count < 50 && updatedListeners.length === 0; count += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(updatedListeners.length, 1);
  activatedListeners[0]({ tabId: acquire.result.tabId });
  const response = await pending;
  assert.equal(response.result.outcome, "outcome_unknown");
  assert.equal(response.result.error.code, "lease_not_found");
  assert.equal(updatedListeners.length, 0);
});

test("navigation settlement rereads the tab instead of verifying an old complete event", async (t) => {
  t.after(() => { tabGetHook = null; });
  const acquire = await sendRequest("acquire-navigation-settle", "lease.acquire", { mode: "create" });
  tabs.get(acquire.result.tabId).status = "complete";
  let reads = 0;
  tabGetHook = async (tab) => {
    reads += 1;
    if (reads === 2) { tab.status = "loading"; tabGetHook = null; }
  };
  const response = await sendRequest("wait-navigation-fresh", "page.wait", {
    leaseId: acquire.result.leaseId, expectedUserSequence: 0, condition: "navigation_settled", timeoutMs: 100,
  });
  assert.equal(response.ok, true);
  assert.equal(response.result.matched, false);
  assert.equal(response.result.outcome, "not_settled");
  assert.equal(response.result.receipt.verification, "not_verified");
  assert.equal(updatedListeners.length, 0);
});

test("node wait revalidates its lease before publishing a matched receipt", async (t) => {
  t.after(() => { waitReplyHook = null; });
  let clock = Date.now();
  t.mock.method(Date, "now", () => clock);
  for (const cause of ["release", "takeover", "expiry"]) {
    const acquire = await sendRequest(`acquire-node-wait-${cause}`, "lease.acquire", { mode: "create" });
    assert.equal(acquire.ok, true);
    const lease = acquire.result;
    const snapshot = await sendRequest(`snapshot-node-wait-${cause}`, "page.snapshot.read", { leaseId: lease.leaseId });
    waitReplyHook = async (tabId, message) => {
      waitReplyHook = null;
      assert.equal(message.leaseId, lease.leaseId);
      if (cause === "release") {
        await sendRequest("release-node-wait", "lease.release", { leaseId: lease.leaseId, closeCreatedTab: false });
      } else if (cause === "takeover") {
        runtimeMessageListeners[0]({ type: "nativeagent.user-touch", kind: "pointer" }, { tab: { id: tabId } });
        await eventFor("lease.yielded", lease.leaseId);
      } else {
        clock = message.leaseExpiresAtMs + 1;
      }
    };
    const response = await sendRequest(`node-wait-${cause}`, "page.wait", {
      leaseId: lease.leaseId, expectedUserSequence: 0, condition: "element_state",
      snapshotId: snapshot.result.snapshotId, nodeId: snapshot.result.nodes[0].nodeId,
      state: "enabled", timeoutMs: 100,
    });
    assert.equal(response.ok, false, "a late matched=true page response is not a current verified receipt");
    assert.equal(response.error.code, cause === "expiry" ? "lease_expired" : "lease_not_found");
    if (cause === "expiry") {
      await sendRequest("release-expired-node-wait", "lease.release", { leaseId: lease.leaseId, closeCreatedTab: false });
    }
  }
});
