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
