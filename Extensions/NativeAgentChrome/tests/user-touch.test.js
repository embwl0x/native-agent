import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const source = readFileSync(new URL("../src/user-touch.js", import.meta.url), "utf8");

function fixture(sendMessage) {
  const listeners = new Map();
  const removed = [];
  const messages = [];
  const context = {
    window: {
      addEventListener(name, listener, options) { listeners.set(name, { listener, options }); },
      removeEventListener(name, listener, options) {
        assert.equal(listeners.get(name).listener, listener);
        assert.equal(listeners.get(name).options, options);
        removed.push(name);
        listeners.delete(name);
      },
    },
    chrome: { runtime: { sendMessage: sendMessage ?? (async (message) => { messages.push(message); }) } },
  };
  runInNewContext(source, context);
  return { context, listeners, removed, messages };
}

test("content script reports trusted pointer, keyboard, wheel, and touch evidence", async () => {
  const { listeners, messages } = fixture();
  const expected = [
    ["pointerdown", "pointer"],
    ["keydown", "keyboard"],
    ["wheel", "scroll"],
    ["touchstart", "touch"],
  ];
  for (const [domEvent, kind] of expected) {
    assert.equal(listeners.get(domEvent).options.capture, true);
    listeners.get(domEvent).listener({ isTrusted: true });
    assert.deepEqual(JSON.parse(JSON.stringify(messages.at(-1))), { type: "nativeagent.user-touch", kind });
  }
  const count = messages.length;
  listeners.get("pointerdown").listener({ isTrusted: false });
  assert.equal(messages.length, count, "synthetic page events must not yield an agent lease");
});

for (const missing of ["chrome", "runtime", "sendMessage"]) {
  test(`stale page listeners retire safely when ${missing} disappears`, () => {
    const f = fixture();
    const oldListener = f.listeners.get("pointerdown").listener;
    if (missing === "chrome") delete f.context.chrome;
    else if (missing === "runtime") delete f.context.chrome.runtime;
    else delete f.context.chrome.runtime.sendMessage;
    assert.doesNotThrow(() => oldListener({ isTrusted: true }));
    assert.equal(f.listeners.size, 0);
    assert.equal(f.removed.length, 4);
    assert.doesNotThrow(() => oldListener({ isTrusted: true }));
    assert.equal(f.removed.length, 4, "cleanup is idempotent");
    assert.equal(f.messages.length, 0);
  });
}

for (const asynchronous of [false, true]) {
  test(`context invalidation retires listeners (${asynchronous ? "rejection" : "synchronous throw"})`, async () => {
    const f = fixture(() => {
      const error = new Error("Extension context invalidated.");
      if (asynchronous) return Promise.reject(error);
      throw error;
    });
    assert.doesNotThrow(() => f.listeners.get("keydown").listener({ isTrusted: true }));
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(f.listeners.size, 0);
    assert.equal(f.removed.length, 4);
  });
}

test("temporary receiver failures preserve trusted takeover reporting", async () => {
  let calls = 0;
  const f = fixture(() => {
    calls++;
    if (calls === 1) return Promise.reject(new Error("Receiving end does not exist."));
    return Promise.resolve();
  });
  f.listeners.get("wheel").listener({ isTrusted: true });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.listeners.size, 4);
  f.listeners.get("wheel").listener({ isTrusted: true });
  assert.equal(calls, 2);
  assert.equal(f.removed.length, 0);
});
