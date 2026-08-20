import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  ACTIONS,
  HOST_ID,
  PROTOCOL_VERSION,
  ProtocolError,
  errorResponse,
  eventEnvelope,
  successResponse,
  validateRequest,
} from "../src/protocol.js";

function request(action, payload = {}) {
  return {
    version: PROTOCOL_VERSION,
    type: "request",
    id: "request-1",
    action,
    payload,
  };
}

test("pins the v1 host identity and complete action vocabulary", () => {
  assert.equal(HOST_ID, "com.nativeagent.chrome");
  assert.equal(PROTOCOL_VERSION, 1);
  assert.deepEqual(ACTIONS, [
    "attach",
    "lease.acquire",
    "lease.renew",
    "lease.resume",
    "lease.release",
    "navigate",
    "page.snapshot.read",
    "page.element.click",
    "page.element.fill",
    "page.element.type",
    "page.element.select",
    "page.element.keypress",
    "page.element.set_checked",
    "page.element.double_click",
    "page.wait",
    "page.scroll",
  ]);
});

test("manifest is MV3 and declares the bounded Chrome transport permissions", async () => {
  const manifest = JSON.parse(await readFile(new URL("../manifest.json", import.meta.url), "utf8"));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background.type, "module");
  assert.deepEqual(new Set(manifest.permissions), new Set([
    "alarms",
    "nativeMessaging",
    "storage",
    "tabs",
    "webNavigation",
  ]));
  assert.deepEqual(manifest.host_permissions, ["http://*/*", "https://*/*"]);
  assert.equal(manifest.content_scripts[0].all_frames, true);
  assert.equal(manifest.content_scripts[0].match_about_blank, true);
  assert.equal(manifest.content_scripts[0].match_origin_as_fallback, true);
  assert.deepEqual(manifest.content_scripts[0].js, ["src/user-touch.js"]);
  assert.equal(manifest.content_scripts[1].all_frames, true);
  assert.equal(manifest.content_scripts[1].match_about_blank, true);
  assert.equal(manifest.content_scripts[1].match_origin_as_fallback, true);
  assert.deepEqual(manifest.content_scripts[1].js, ["src/page-agent.js"]);
  const schema = JSON.parse(await readFile(
    new URL("../protocol/protocol-v1.schema.json", import.meta.url),
    "utf8",
  ));
  assert.ok(schema.$defs.structuredPageSnapshot);
  assert.ok(schema.$defs.pageNode);
});

test("accepts an inactive-create lease request with an HTTP URL", () => {
  const value = request("lease.acquire", {
    mode: "create",
    initialUrl: "https://example.com/path",
  });
  assert.deepEqual(validateRequest(value), value);
});

test("validates bounded renewable lease durations", () => {
  const value = request("lease.renew", {
    leaseId: "lease-1",
    expectedUserSequence: 0,
    leaseDurationMs: 45_000,
  });
  assert.deepEqual(validateRequest(value), value);
  assert.throws(
    () => validateRequest(request("lease.renew", {
      leaseId: "lease-1",
      expectedUserSequence: 0,
      leaseDurationMs: 300_001,
    })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
  assert.throws(
    () => validateRequest(request("lease.acquire", {
      mode: "create",
      leaseDurationMs: 29_999,
    })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
});

test("requires exact URL and title when claiming a user tab", () => {
  assert.throws(
    () => validateRequest(request("lease.acquire", { mode: "claim", tabId: 42 })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
  const value = request("lease.acquire", {
    mode: "claim",
    tabId: 42,
    expectedTab: { url: "https://example.com/", title: "Example" },
  });
  assert.deepEqual(validateRequest(value), value);
});

test("refuses non-web navigation schemes", () => {
  assert.throws(
    () => validateRequest(request("navigate", {
      leaseId: "lease-1",
      expectedUserSequence: 0,
      url: "file:///Users/example/secret.txt",
    })),
    (error) => error instanceof ProtocolError && error.code === "url_scheme_not_allowed",
  );
});

test("binds element clicks to a lease, observation sequence, and snapshot node", () => {
  const value = request("page.element.click", {
    leaseId: "lease-1",
    expectedUserSequence: 3,
    snapshotId: "snapshot-1",
    nodeId: "node-17",
  });
  assert.deepEqual(validateRequest(value), value);
});

test("binds fill and type to a current snapshot node and bounds text input", () => {
  const base = {
    leaseId: "lease-1",
    expectedUserSequence: 3,
    snapshotId: "snapshot-1",
    nodeId: "node-17",
  };
  const fill = request("page.element.fill", { ...base, value: "replacement" });
  const type = request("page.element.type", { ...base, text: " appended", delayMs: 25 });
  assert.deepEqual(validateRequest(fill), fill);
  assert.deepEqual(validateRequest(type), type);
  assert.throws(
    () => validateRequest(request("page.element.type", { ...base, text: "x", delayMs: 251 })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
});

test("validates select, keypress, checked-state, and double-click payloads", () => {
  const base = {
    leaseId: "lease-1",
    expectedUserSequence: 3,
    snapshotId: "snapshot-1",
    nodeId: "node-17",
  };
  for (const value of [
    request("page.element.select", { ...base, values: ["pro"] }),
    request("page.element.keypress", { ...base, key: "Shift+Tab" }),
    request("page.element.set_checked", { ...base, checked: true }),
    request("page.element.double_click", base),
  ]) assert.deepEqual(validateRequest(value), value);
  assert.throws(
    () => validateRequest(request("page.element.keypress", { ...base, key: "F13" })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
  assert.throws(
    () => validateRequest(request("page.element.select", { ...base, values: [] })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
});

test("wait supports only bounded element-state or navigation-settled conditions", () => {
  const elementWait = request("page.wait", {
    leaseId: "lease-1",
    expectedUserSequence: 0,
    condition: "element_state",
    snapshotId: "snapshot-1",
    nodeId: "node-17",
    state: "visible",
    timeoutMs: 5000,
  });
  const navigationWait = request("page.wait", {
    leaseId: "lease-1",
    expectedUserSequence: 0,
    condition: "navigation_settled",
    timeoutMs: 5000,
    settleMs: 250,
  });
  assert.deepEqual(validateRequest(elementWait), elementWait);
  assert.deepEqual(validateRequest(navigationWait), navigationWait);
  assert.throws(
    () => validateRequest(request("page.wait", {
      leaseId: "lease-1",
      expectedUserSequence: 0,
      condition: "element_state",
      state: "visible",
    })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
});

test("bounds scroll deltas", () => {
  assert.throws(
    () => validateRequest(request("page.scroll", {
      leaseId: "lease-1",
      expectedUserSequence: 0,
      deltaX: 0,
      deltaY: 100001,
    })),
    (error) => error instanceof ProtocolError && error.code === "invalid_payload",
  );
});

test("success and error envelopes preserve request identity", () => {
  const value = request("attach");
  assert.deepEqual(successResponse(value, { ready: true }), {
    version: 1,
    type: "response",
    id: "request-1",
    action: "attach",
    ok: true,
    result: { ready: true },
  });
  assert.equal(errorResponse(value, new ProtocolError("denied", "No.")).error.code, "denied");
  assert.equal(
    errorResponse({ ...value, action: "future.action" }, new ProtocolError("unknown_action", "No.")).action,
    "future.action",
  );
});

test("lease lifecycle events are versioned and carry no request id", async () => {
  const value = eventEnvelope("lease.yielded", {
    leaseId: "lease-1",
    tabId: 9,
    reason: "user_scroll",
    userSequence: 1,
  });
  assert.equal(value.version, 1);
  assert.equal(value.type, "event");
  assert.equal(value.event, "lease.yielded");
  assert.equal("id" in value, false);
  const schema = JSON.parse(await readFile(
    new URL("../protocol/protocol-v1.schema.json", import.meta.url),
    "utf8",
  ));
  assert.deepEqual(schema.$defs.event.properties.event.enum, [
    "lease.granted",
    "lease.renewed",
    "lease.yielded",
    "lease.released",
  ]);
});
