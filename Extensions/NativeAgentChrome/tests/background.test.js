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
  tabs: {
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
      return structuredClone(tab);
    },
    async update(tabId, options) {
      assert.equal("active" in options, false, "navigation must never request tab activation");
      const tab = tabs.get(tabId);
      if (!tab) throw new Error("tab missing");
      tab.url = options.url;
      tab.status = "complete";
      return structuredClone(tab);
    },
    async sendMessage(tabId, message, options = {}) {
      assert.ok(tabs.has(tabId));
      if (message.type === "nativeagent.page.snapshot") {
        return { ok: true, result: {
          snapshotId: `snapshot-frame-${options.frameId ?? 0}`, leaseId: message.leaseId, tabId,
          userSequence: message.userSequence,
          url: webFrames.find((frame) => frame.frameId === (options.frameId ?? 0))?.url,
          title: options.frameId === 0 ? "Fixture" : "Child",
          language: "en",
          viewport: { width: 1200, height: 800, scrollX: 0, scrollY: 0, documentWidth: 1200, documentHeight: 2000 },
          summary: { text: options.frameId === 0 ? "Top frame" : "Child frame", nodeCount: 1, truncated: false, truncationReasons: [] },
          frame: { name: options.frameId === 0 ? "Fixture" : "Child", url: webFrames.find((frame) => frame.frameId === (options.frameId ?? 0))?.url },
          nodes: [{ nodeId: "n1", parentNodeId: null, actions: ["click", "fill", "type", "select", "keypress", "set_checked", "double_click", "wait"] }],
        } };
      }
      if (message.type === "nativeagent.page.click") {
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, clicked: true } };
      }
      if (message.type === "nativeagent.page.fill") {
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, filled: true, valueLength: message.value.length } };
      }
      if (message.type === "nativeagent.page.type") {
        typeDispatchCount += 1;
        if (rejectNextTypeReply) {
          rejectNextTypeReply = false;
          throw new Error("frame navigated");
        }
        return { ok: true, result: { snapshotId: message.snapshotId, nodeId: message.nodeId, typed: true, characterCount: message.text.length } };
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
      if (message.type === "nativeagent.page.wait") {
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
  assert.deepEqual(createdTabs[0], { active: false, url: "https://example.com/" });
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
