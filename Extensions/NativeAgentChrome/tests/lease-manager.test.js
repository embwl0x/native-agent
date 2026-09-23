import assert from "node:assert/strict";
import test from "node:test";

import { LEASE_STORAGE_KEY, TabLeaseManager } from "../src/lease-manager.js";

function fixture({ now = Date.parse("2026-08-18T12:00:00.000Z"), storage = {} } = {}) {
  const tabs = new Map();
  const events = [];
  const alarms = new Map();
  let session = structuredClone(storage);
  const chromeApi = {
    alarms: {
      async create(name, options) { alarms.set(name, options); },
      async clear(name) { return alarms.delete(name); },
    },
    storage: {
      session: {
        async get() { return structuredClone(session); },
        async set(value) { session = { ...session, ...structuredClone(value) }; },
      },
    },
    tabs: {
      async create(options) {
        const tab = { id: 1, windowId: 2, active: options.active, title: "", url: options.url ?? "chrome://newtab/" };
        tabs.set(tab.id, tab);
        return structuredClone(tab);
      },
      async get(tabId) {
        if (!tabs.has(tabId)) throw new Error("missing tab");
        return structuredClone(tabs.get(tabId));
      },
      async remove(tabId) { tabs.delete(tabId); },
    },
  };
  const manager = new TabLeaseManager({
    chromeApi,
    emitEvent(event, payload) { events.push({ event, payload }); },
    now: () => now,
    uuid: () => "lease-fixed",
  });
  return {
    alarms,
    chromeApi,
    events,
    manager,
    setNow(value) { now = value; },
    session() { return structuredClone(session); },
    tabs,
  };
}

function renderedFixture() {
  const value = fixture();
  const work = { id: 22, focused: false, state: "normal", type: "normal", tabs: [] };
  value.chromeApi.windows = {
    async getLastFocused() { return { id: 2, focused: true }; },
    async create(options) {
      assert.equal(options.focused, false);
      const tab = { id: 33, windowId: 22, active: true, title: "X", url: options.url };
      work.tabs = [tab]; value.tabs.set(tab.id, tab);
      return structuredClone(work);
    },
    async get(id) { assert.equal(id, 22); return structuredClone(work); },
  };
  return { ...value, work };
}

test("rendered work tab uses only its own unfocused window and closes only its tab", async () => {
  const value = renderedFixture();
  const lease = await value.manager.acquire({ mode: "create", renderingMode: "visible_work_window", initialUrl: "https://x.com/home" });
  assert.equal(lease.renderingMode, "visible_work_window");
  await value.manager.verifyRenderingWindow(lease.leaseId);
  const released = await value.manager.release({ leaseId: lease.leaseId });
  assert.equal(released.tabClosed, true);
  assert.equal(value.tabs.size, 0);
});

test("X post creation automatically selects the proven rendered route", async () => {
  for (const host of ["x.com", "www.x.com", "twitter.com", "www.twitter.com"]) {
    const value = renderedFixture();
    const lease = await value.manager.acquire({ mode: "create", initialUrl: `https://${host}/MiaAI_lab/status/2101466550133788888` });
    assert.equal(lease.renderingMode, "visible_work_window");
    assert.equal(lease.tabId, 33);
  }
});

test("explicit grouped background overrides X post routing; unrelated and deceptive URLs stay grouped", async () => {
  const value = fixture();
  const lease = await value.manager.acquire({ mode: "create", initialUrl: "https://x.com/A/status/123", renderingMode: "grouped_background" });
  assert.equal(lease.renderingMode, undefined);
  assert.equal(lease.originalTab.active, false);
  for (const url of ["https://x.com/home", "https://x.com/A/status/123/photo/1", "https://x.com.evil.test/A/status/123",
    "https://evil.test/x.com/A/status/123", "https://user:pass@x.com/A/status/123", "https://x.com:8443/A/status/123", "file://x.com/A/status/123"]) {
    const other = fixture();
    const grouped = await other.manager.acquire({ mode: "create", initialUrl: url });
    assert.equal(grouped.renderingMode, undefined, url);
    assert.equal(grouped.originalTab.active, false);
  }
});

test("claim of an X post never creates or changes its presentation", async () => {
  const value = fixture();
  const tab = { id: 7, windowId: 2, active: false, url: "https://x.com/A/status/123", title: "X" };
  value.tabs.set(tab.id, tab);
  const lease = await value.manager.acquire({ mode: "claim", tabId: tab.id, expectedTab: { url: tab.url, title: tab.title } });
  assert.equal(lease.renderingMode, undefined);
  assert.equal(lease.ownership, "claimed");
  assert.equal(value.tabs.size, 1);
});

test("rendered work window focus immediately blocks effects and yields without closing", async () => {
  const value = renderedFixture();
  const lease = await value.manager.acquire({ mode: "create", renderingMode: "visible_work_window" });
  value.work.focused = true;
  value.manager.windowFocused(22);
  assert.throws(() => value.manager.requireActiveLease(lease.leaseId));
  await value.manager.pendingOperation;
  assert.equal(value.tabs.has(33), true);
  assert.equal(value.manager.leases.size, 0);
});

test("rendered work guard yields if user adds another tab, preserving both", async () => {
  const value = renderedFixture();
  const lease = await value.manager.acquire({ mode: "create", renderingMode: "visible_work_window" });
  value.work.tabs.push({ id: 34, windowId: 22, active: false });
  await assert.rejects(value.manager.verifyRenderingWindow(lease.leaseId), /changed/);
  assert.equal(value.tabs.has(33), true);
  assert.equal(value.manager.leases.size, 0);
});

test("rendered work expiry does not close a focused window even if focus event was missed", async () => {
  const value = renderedFixture();
  const lease = await value.manager.acquire({ mode: "create", renderingMode: "visible_work_window" });
  value.work.focused = true;
  const released = await value.manager.release({ leaseId: lease.leaseId });
  assert.equal(released.tabClosed, false);
  assert.equal(value.tabs.has(33), true);
});

test("restores an active lease across a service-worker restart", async () => {
  const first = fixture();
  const lease = await first.manager.acquire({ mode: "create", leaseDurationMs: 120_000 });
  const persisted = first.session();

  const restarted = fixture({ storage: persisted });
  restarted.tabs.set(lease.tabId, {
    id: lease.tabId,
    windowId: lease.windowId,
    active: false,
    title: "",
    url: "chrome://newtab/",
  });
  await restarted.manager.restore();

  assert.equal(restarted.manager.requireLease(lease.leaseId).tabId, lease.tabId);
  assert.equal(restarted.session()[LEASE_STORAGE_KEY].length, 1);
  assert.equal(restarted.alarms.size, 1);
  assert.deepEqual(restarted.events, [], "restart recovery must not replay lease.granted");
});

test("restart drops expired, malformed, duplicate-tab, and missing-tab records", async () => {
  const active = {
    leaseId: "active", tabId: 5, windowId: 2, ownership: "claimed", state: "active",
    userSequence: 0, createdAt: "2026-08-18T11:59:00.000Z", renewedAt: "2026-08-18T11:59:00.000Z",
    expiresAt: "2026-08-18T12:01:00.000Z", originalTab: { active: false, title: "A", url: "https://example.com" },
  };
  const expired = { ...active, leaseId: "expired", tabId: 6, expiresAt: "2026-08-18T11:59:59.000Z" };
  const duplicate = { ...active, leaseId: "duplicate" };
  const missing = { ...active, leaseId: "missing", tabId: 7 };
  const value = fixture({ storage: { [LEASE_STORAGE_KEY]: [active, expired, duplicate, missing, { nope: true }] } });
  value.tabs.set(active.tabId, { id: active.tabId, windowId: 2, active: false });
  await value.manager.restore();
  assert.deepEqual(value.session()[LEASE_STORAGE_KEY].map((row) => row.leaseId), ["active"]);
});

test("expiry releases a lease and closes only an agent-created tab", async () => {
  const value = fixture();
  const lease = await value.manager.acquire({ mode: "create", leaseDurationMs: 30_000 });
  value.setNow(Date.parse(lease.expiresAt));
  const alarmName = [...value.alarms.keys()][0];
  assert.equal(await value.manager.alarmFired(alarmName), true);
  assert.equal(value.tabs.has(lease.tabId), false);
  assert.equal(value.session()[LEASE_STORAGE_KEY].length, 0);
  assert.equal(value.events.at(-1).event, "lease.released");
  assert.equal(value.events.at(-1).payload.reason, "lease_expired");
});

test("effect-time expiry does not depend on alarm delivery and keeps cleanup available", async () => {
  const value = fixture();
  const lease = await value.manager.acquire({ mode: "create", leaseDurationMs: 30_000 });
  const expiresAt = Date.parse(lease.expiresAt);
  value.setNow(expiresAt - 1);
  assert.equal(value.manager.requireForPageAction({ leaseId: lease.leaseId, expectedUserSequence: 0 }).leaseId, lease.leaseId);
  value.setNow(expiresAt);
  assert.throws(
    () => value.manager.requireForPageAction({ leaseId: lease.leaseId, expectedUserSequence: 0 }),
    (error) => error.code === "lease_expired",
  );
  await assert.rejects(
    value.manager.renew({ leaseId: lease.leaseId, expectedUserSequence: 0 }),
    (error) => error.code === "lease_expired",
  );
  const released = await value.manager.release({ leaseId: lease.leaseId, closeCreatedTab: false });
  assert.equal(released.released, true);
  assert.equal(released.tabClosed, false);
  assert.equal(value.tabs.has(lease.tabId), true);
  assert.equal(value.session()[LEASE_STORAGE_KEY].length, 0);
});

test("release never closes an agent-created tab after it becomes active", async () => {
  const value = fixture();
  const lease = await value.manager.acquire({ mode: "create" });
  value.tabs.get(lease.tabId).active = true;
  const release = await value.manager.release({ leaseId: lease.leaseId });
  assert.equal(release.tabClosed, false);
  assert.equal(value.tabs.has(lease.tabId), true);
});

test("claim is exact and never activates or closes the claimed tab", async () => {
  const value = fixture();
  value.tabs.set(9, { id: 9, windowId: 3, active: false, title: "Exact", url: "https://example.com/exact" });
  await assert.rejects(
    value.manager.acquire({ mode: "claim", tabId: 9, expectedTab: { title: "Wrong", url: "https://example.com/exact" } }),
    (error) => error.code === "tab_identity_changed",
  );
  const lease = await value.manager.acquire({
    mode: "claim", tabId: 9, expectedTab: { title: "Exact", url: "https://example.com/exact" },
  });
  const release = await value.manager.release({ leaseId: lease.leaseId });
  assert.equal(release.tabClosed, false);
  assert.equal(value.tabs.get(9).active, false);
});

test("an unexpected active create result fails closed and removes that tab", async () => {
  const value = fixture();
  value.chromeApi.tabs.create = async () => {
    const tab = { id: 77, windowId: 4, active: true, title: "", url: "chrome://newtab/" };
    value.tabs.set(tab.id, tab);
    return tab;
  };
  await assert.rejects(
    value.manager.acquire({ mode: "create" }),
    (error) => error.code === "focus_invariant_failed",
  );
  assert.equal(value.tabs.has(77), false);
  assert.deepEqual(value.events, []);
});

test("user yield serializes ahead of a later renewal", async () => {
  const value = fixture();
  const lease = await value.manager.acquire({ mode: "create" });
  const yielded = value.manager.yieldForTab(lease.tabId, "user_pointer");
  const renewed = value.manager.renew({
    leaseId: lease.leaseId,
    expectedUserSequence: 0,
  });
  assert.equal(await yielded, true);
  await assert.rejects(renewed, (error) => error.code === "lease_not_found");
  assert.deepEqual(
    value.events.slice(-1).map((event) => event.event),
    ["lease.yielded"],
  );
});
