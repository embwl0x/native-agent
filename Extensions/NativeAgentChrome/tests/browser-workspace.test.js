import assert from "node:assert/strict";
import test from "node:test";
import { BrowserWorkspace, WORKSPACE_STORAGE_KEY } from "../src/browser-workspace.js";
import { TabLeaseManager } from "../src/lease-manager.js";

function fixture() {
  const tabs = new Map([[1, { id: 1, windowId: 1, active: true, url: "https://example.com/user", title: "User work" }]]);
  const windows = new Map([[1, { id: 1, focused: true, type: "normal" }]]);
  const groups = new Map();
  let storage = {}, nextTab = 2, nextWindow = 2, nextGroup = 1;
  const effects = [];
  const chrome = {
    runtime: { getURL: (path) => `chrome-extension://fixture/${path}` },
    alarms: { async create() {}, async clear() {} },
    storage: { session: { async get() { return structuredClone(storage); },
      async set(value) { storage = { ...storage, ...structuredClone(value) }; } } },
    windows: {
      async getLastFocused() { return structuredClone(windows.get(1)); },
      async get(id) { if (!windows.has(id)) throw Error("missing"); return structuredClone(windows.get(id)); },
      async create(options) {
        effects.push(["window", options]);
        const window = { id: nextWindow++, focused: options.focused, type: options.type };
        const anchor = { id: nextTab++, windowId: window.id, active: true, url: options.url };
        tabs.set(anchor.id, anchor); windows.set(window.id, window);
        return { ...window, tabs: [anchor] };
      },
    },
    tabs: {
      async get(id) { if (!tabs.has(id)) throw Error("missing"); return structuredClone(tabs.get(id)); },
      async create(options) { effects.push(["tab", options]); const tab = { id: nextTab++, ...options }; tabs.set(tab.id, tab); return { ...tab }; },
      async remove(id) { effects.push(["remove", id]); tabs.delete(id); },
      async group(options) {
        const id = options.groupId ?? nextGroup++;
        if (!groups.has(id)) groups.set(id, { id, windowId: options.createProperties.windowId });
        for (const tab of options.tabIds) tabs.get(tab).groupId = id;
        return id;
      },
    },
    tabGroups: {
      async query(query) { return [...groups.values()].filter((group) => group.windowId === query.windowId && group.title === query.title).map((group) => ({ ...group })); },
      async get(id) { if (!groups.has(id)) throw Error("missing"); return { ...groups.get(id) }; },
      async update(id, value) { effects.push(["group", value]); Object.assign(groups.get(id), value); },
    },
  };
  return { chrome, tabs, windows, groups, effects, workspace: new BrowserWorkspace(chrome), storage: () => storage };
}

test("purple group stays in the existing window across worker restart without touching user tabs", async () => {
  const f = fixture();
  const user = structuredClone(f.tabs.get(1));
  const first = await f.workspace.createTab("https://example.com/first");
  f.groups.get(first.groupId).title = "My chosen label";
  f.groups.get(first.groupId).collapsed = true;
  const second = await new BrowserWorkspace(f.chrome).createTab("https://example.com/second");
  assert.equal(first.windowId, second.windowId);
  assert.equal(first.groupId, second.groupId);
  assert.equal(first.windowId, 1);
  assert.equal(f.effects.filter(([kind]) => kind === "window").length, 0);
  assert.deepEqual(f.effects.find(([kind]) => kind === "group")[1], { title: "NativeAgent", color: "purple", collapsed: false });
  assert.equal(f.groups.get(first.groupId).title, "My chosen label");
  assert.equal(f.groups.get(first.groupId).collapsed, true);
  assert.equal(first.active, false); assert.equal(second.active, false);
  assert.deepEqual(f.tabs.get(1), user); assert.equal(f.windows.get(1).focused, true);
});

test("extension reload reuses one visible group without claiming or changing its existing tabs", async () => {
  const f = fixture();
  const first = await f.workspace.createTab("https://example.com/first");
  const original = structuredClone(f.tabs.get(first.id));
  delete f.storage()[WORKSPACE_STORAGE_KEY];
  const second = await new BrowserWorkspace(f.chrome).createTab("https://example.com/second");
  assert.equal(second.groupId, first.groupId);
  assert.equal(f.groups.size, 1);
  assert.deepEqual(f.tabs.get(first.id), original);
  delete f.storage()[WORKSPACE_STORAGE_KEY];
  f.groups.set(99, { id: 99, title: "NativeAgent", windowId: 1 });
  const count = f.tabs.size;
  await assert.rejects(f.workspace.createTab(), (error) => error.code === "workspace_ambiguous");
  assert.equal(f.tabs.size, count);
});

test("old separate-window pointers are retired without moving or deleting their tabs", async () => {
  const f = fixture();
  f.storage()[WORKSPACE_STORAGE_KEY] = { windowId: 9, anchorTabId: 90, groupId: 8 };
  f.tabs.set(90, { id: 90, windowId: 9, active: true });
  const second = await f.workspace.createTab();
  assert.equal(second.windowId, 1);
  assert.equal(f.tabs.get(90).windowId, 9);
  assert.equal(f.storage()[WORKSPACE_STORAGE_KEY].version, 2);
});

test("tab taken over during grouping is preserved and never leased", async () => {
  const f = fixture();
  const group = f.chrome.tabs.group;
  let taken;
  f.chrome.tabs.group = async (options) => { const id = await group(options); taken = options.tabIds[0]; f.tabs.get(taken).active = true; return id; };
  await assert.rejects(f.workspace.createTab(), (error) => error.code === "workspace_changed");
  assert.equal(f.tabs.get(taken).active, true);
  assert.equal(f.effects.some(([kind, id]) => kind === "remove" && id === taken), false);
});

test("group failure removes only the new inactive work tab", async () => {
  const f = fixture();
  f.chrome.tabGroups.update = async () => { throw Error("group failed"); };
  await assert.rejects(f.workspace.createTab(), /group failed/);
  assert.equal(f.tabs.has(1), true);
  assert.equal(f.tabs.size, 1, "only the original user tab remains");
});

test("lease serial lane coalesces concurrent creates and user takeover remains terminal", async () => {
  const f = fixture();
  let seq = 0;
  const manager = new TabLeaseManager({ chromeApi: f.chrome, workspace: f.workspace, emitEvent() {}, uuid: () => `lease-${++seq}` });
  const [a, b] = await Promise.all([manager.acquire({ mode: "create" }), manager.acquire({ mode: "create" })]);
  assert.equal(a.windowId, b.windowId);
  assert.equal(f.effects.filter(([kind]) => kind === "window").length, 0);
  await manager.yieldForTab(a.tabId, "tab_activated");
  assert.throws(() => manager.requireForPageAction({ leaseId: a.leaseId }), /does not exist/);
  assert.equal(f.tabs.has(a.tabId), true);
  await manager.release({ leaseId: b.leaseId });
  assert.equal(f.tabs.has(b.tabId), false); assert.equal(f.tabs.has(a.tabId), true);
});
