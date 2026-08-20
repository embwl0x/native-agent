import assert from "node:assert/strict";
import test from "node:test";

const listeners = new Map();
const messages = [];
globalThis.window = {
  addEventListener(name, listener, options) { listeners.set(name, { listener, options }); },
};
globalThis.chrome = {
  runtime: {
    async sendMessage(message) { messages.push(message); },
  },
};

await import("../src/user-touch.js");

test("content script reports trusted pointer, keyboard, wheel, and touch evidence", async () => {
  const expected = [
    ["pointerdown", "pointer"],
    ["keydown", "keyboard"],
    ["wheel", "scroll"],
    ["touchstart", "touch"],
  ];
  for (const [domEvent, kind] of expected) {
    assert.equal(listeners.get(domEvent).options.capture, true);
    listeners.get(domEvent).listener({ isTrusted: true });
    assert.deepEqual(messages.at(-1), { type: "nativeagent.user-touch", kind });
  }
  const count = messages.length;
  listeners.get("pointerdown").listener({ isTrusted: false });
  assert.equal(messages.length, count, "synthetic page events must not yield an agent lease");
});
