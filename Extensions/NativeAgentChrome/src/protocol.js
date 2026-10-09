export const HOST_ID = "com.nativeagent.chrome";
export const PROTOCOL_VERSION = 1;

export const ACTIONS = Object.freeze([
  "attach",
  "extension.reload",
  "tab.close",
  "navigate",
  "page.snapshot.read",
  "page.element.click",
  "page.element.fill",
  "page.element.type",
  "page.element.select",
  "page.element.keypress",
  "page.element.set_checked",
  "page.element.double_click",
  "page.element.drag",
  "page.wait",
  "page.scroll",
  "page.media",
]);

const ACTION_SET = new Set(ACTIONS);
const ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

export class ProtocolError extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = "ProtocolError";
    this.code = code;
    this.details = details;
  }
}

export function validateRequest(value) {
  if (!isObject(value)) {
    throw new ProtocolError("invalid_envelope", "Request must be a JSON object.");
  }
  if (value.version !== PROTOCOL_VERSION) {
    throw new ProtocolError(
      "unsupported_version",
      `Protocol version ${String(value.version)} is not supported.`,
      { supportedVersions: [PROTOCOL_VERSION] },
    );
  }
  if (value.type !== "request") {
    throw new ProtocolError("invalid_envelope", "Request type must be 'request'.");
  }
  requireId(value.id, "id");
  if (!ACTION_SET.has(value.action)) {
    throw new ProtocolError("unknown_action", `Unknown action '${String(value.action)}'.`);
  }
  const payload = value.payload ?? {};
  if (!isObject(payload)) {
    throw new ProtocolError("invalid_payload", "Request payload must be a JSON object.");
  }
  validatePayload(value.action, payload);
  return { ...value, payload };
}

export function successResponse(request, result) {
  return {
    version: PROTOCOL_VERSION,
    type: "response",
    id: request.id,
    action: request.action,
    ok: true,
    result,
  };
}

export function errorResponse(request, error) {
  const normalized = error instanceof ProtocolError
    ? error
    : new ProtocolError("internal_error", `The extension could not complete the request: ${String(error?.message ?? error).slice(0, 300)}`);
  return {
    version: PROTOCOL_VERSION,
    type: "response",
    id: validId(request?.id) ? request.id : "invalid-request",
    action: validId(request?.action) ? request.action : "invalid-action",
    ok: false,
    error: {
      code: normalized.code,
      message: normalized.message,
      ...(normalized.details === undefined ? {} : { details: normalized.details }),
    },
  };
}

export function eventEnvelope(event, payload) {
  if (!ID_PATTERN.test(event)) {
    throw new ProtocolError("invalid_event", "Event name is invalid.");
  }
  return {
    version: PROTOCOL_VERSION,
    type: "event",
    event,
    occurredAt: new Date().toISOString(),
    payload,
  };
}

export function requireHttpURL(value, field = "url") {
  if (typeof value !== "string" || value.length > 8192) {
    throw new ProtocolError("invalid_payload", `${field} must be a bounded URL string.`);
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new ProtocolError("invalid_url", `${field} is not a valid URL.`);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new ProtocolError("url_scheme_not_allowed", `${field} must use http or https.`);
  }
  return parsed.href;
}

function validatePayload(action, payload) {
  switch (action) {
    case "attach":
      optionalString(payload.clientName, "clientName", 128);
      optionalString(payload.clientVersion, "clientVersion", 64);
      return;
    case "extension.reload":
      requireId(payload.reloadId, "reloadId");
      return;
    case "tab.close":
      requireInteger(payload.tabId, "tabId", 0);
      optionalInteger(payload.expectedUserSequence, "expectedUserSequence", 0, Number.MAX_SAFE_INTEGER);
      return;
    case "navigate":
      optionalInteger(payload.tabId, "tabId", 0, Number.MAX_SAFE_INTEGER);
      optionalInteger(payload.expectedUserSequence, "expectedUserSequence", 0, Number.MAX_SAFE_INTEGER);
      // "back" / "forward" walk the owned tab's own history.
      if (payload.url !== "back" && payload.url !== "forward") requireHttpURL(payload.url);
      return;
    case "page.snapshot.read":
      requireInteger(payload.tabId, "tabId", 0);
      optionalInteger(payload.expectedUserSequence, "expectedUserSequence", 0, Number.MAX_SAFE_INTEGER);
      if (payload.readCursor !== undefined) {
        const cursor = requireObject(payload.readCursor, "readCursor");
        requireHttpURL(cursor.url);
        optionalString(cursor.frameURL, "frameURL", 8192);
        requireInteger(cursor.frameId, "frameId", 0);
        optionalString(cursor.elementPath, "elementPath", 32768);
        optionalString(cursor.addressFragment, "addressFragment", 256);
        optionalInteger(cursor.textOffset, "textOffset", 0, Number.MAX_SAFE_INTEGER);
        optionalInteger(cursor.optionOffset, "optionOffset", 0, Number.MAX_SAFE_INTEGER);
        optionalBoolean(cursor.elementOnly, "elementOnly");
        if (cursor.viewportObservationId !== undefined) {
          requireId(cursor.viewportObservationId, "viewportObservationId");
          if (cursor.elementPath !== undefined || cursor.elementOnly !== undefined || cursor.textOffset !== undefined || cursor.optionOffset !== undefined) {
            throw new ProtocolError("invalid_payload", "A scroll viewport address cannot also be a folded continuation.");
          }
        }
        if ((cursor.elementOnly === true || cursor.optionOffset !== undefined) && !cursor.elementPath) {
          throw new ProtocolError("invalid_payload", "A control continuation requires its element path.");
        }
      }
      optionalInteger(payload.maxNodes, "maxNodes", 1, 500);
      optionalInteger(payload.maxTextChars, "maxTextChars", 1, 50000);
      if (payload.scope !== undefined && !["page", "main_content"].includes(payload.scope)) {
        throw new ProtocolError("invalid_payload", "Snapshot scope must be page or main_content.");
      }
      return;
    case "page.element.click":
      requireTabAndSequence(payload);
      requireId(payload.snapshotId, "snapshotId");
      requireId(payload.nodeId, "nodeId");
      optionalString(payload.button, "button", 16);
      return;
    case "page.element.fill":
      requireSnapshotNodeAction(payload);
      requireBoundedText(payload.value, "value", 50_000);
      return;
    case "page.element.type":
      requireSnapshotNodeAction(payload);
      requireBoundedText(payload.text, "text", 50_000);
      optionalInteger(payload.delayMs, "delayMs", 0, 250);
      return;
    case "page.element.select":
      requireSnapshotNodeAction(payload);
      requireStringArray(payload.values, "values", 1, 100, 1_024);
      return;
    case "page.element.keypress":
      requireSnapshotNodeAction(payload);
      requireKeySpec(payload.key);
      return;
    case "page.element.set_checked":
      requireSnapshotNodeAction(payload);
      requireBoolean(payload.checked, "checked");
      return;
    case "page.element.double_click":
      requireSnapshotNodeAction(payload);
      return;
    case "page.element.drag":
      requireSnapshotNodeAction(payload);
      requireId(payload.targetNodeId, "targetNodeId");
      return;
    case "page.wait":
      requireTabAndSequence(payload);
      if (payload.condition === "element_state") {
        requireId(payload.snapshotId, "snapshotId");
        requireId(payload.nodeId, "nodeId");
        if (!["visible", "hidden", "enabled", "disabled"].includes(payload.state)) {
          throw new ProtocolError("invalid_payload", "page.wait state is unsupported.");
        }
      } else if (payload.condition !== "navigation_settled") {
        throw new ProtocolError("invalid_payload", "page.wait condition is unsupported.");
      }
      optionalInteger(payload.timeoutMs, "timeoutMs", 100, 10_000);
      optionalInteger(payload.settleMs, "settleMs", 0, 2_000);
      return;
    case "page.media":
      requireTabAndSequence(payload);
      if (!["play", "pause", "seek"].includes(payload.operation)) {
        throw new ProtocolError("invalid_payload", "Media operation must be play, pause or seek.");
      }
      if (payload.operation === "seek") requireFiniteNumber(payload.seconds, "seconds", 0, Number.MAX_SAFE_INTEGER);
      return;
    case "page.scroll":
      requireTabAndSequence(payload);
      optionalId(payload.snapshotId, "snapshotId");
      optionalId(payload.targetNodeId, "targetNodeId");
      requireFiniteNumber(payload.deltaX, "deltaX", -100000, 100000);
      requireFiniteNumber(payload.deltaY, "deltaY", -100000, 100000);
      return;
    default:
      throw new ProtocolError("unknown_action", `Unknown action '${action}'.`);
  }
}

function requireSnapshotNodeAction(payload) {
  requireTabAndSequence(payload);
  requireId(payload.snapshotId, "snapshotId");
  requireId(payload.nodeId, "nodeId");
}

function requireBoundedText(value, field, maximumLength) {
  if (typeof value !== "string" || value.length > maximumLength) {
    throw new ProtocolError("invalid_payload", `${field} must be a bounded string.`);
  }
}

function requireStringArray(value, field, minimumCount, maximumCount, maximumItemLength) {
  if (!Array.isArray(value) || value.length < minimumCount || value.length > maximumCount
      || value.some((item) => typeof item !== "string" || item.length > maximumItemLength)) {
    throw new ProtocolError(
      "invalid_payload",
      `${field} must contain ${minimumCount} through ${maximumCount} bounded strings.`,
    );
  }
}

function requireKeySpec(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 64) {
    throw new ProtocolError("invalid_payload", "key must be a bounded key specification.");
  }
  const parts = value.split("+");
  const base = parts.pop();
  const modifiers = new Set(["Alt", "Control", "Meta", "Shift"]);
  const bases = new Set([
    "Enter", "Tab", "Escape", "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight",
    "Home", "End", "PageUp", "PageDown", "Backspace", "Delete", "Space", "A",
  ]);
  // 2026-09-24: one printable character too (X's j/k, GitHub's "/"): sites
  // read those in their own handlers, which synthetic events do reach.
  const printable = typeof base === "string" && [...base].length === 1 && base.trim().length === 1;
  if ((!bases.has(base) && !printable) || parts.some((part, index) => !modifiers.has(part) || parts.indexOf(part) !== index)) {
    throw new ProtocolError("invalid_payload", "key uses an unsupported key or modifier combination.");
  }
}

function requireTabAndSequence(payload) {
  requireInteger(payload.tabId, "tabId", 0);
  requireInteger(payload.expectedUserSequence, "expectedUserSequence", 0);
}

function validId(value) {
  return typeof value === "string" && ID_PATTERN.test(value);
}

function requireId(value, field) {
  if (!validId(value)) {
    throw new ProtocolError("invalid_payload", `${field} must be a stable identifier.`);
  }
}

function optionalId(value, field) {
  if (value !== undefined) requireId(value, field);
}

function requireString(value, field, maximumLength) {
  if (typeof value !== "string" || value.length === 0 || value.length > maximumLength) {
    throw new ProtocolError("invalid_payload", `${field} must be a non-empty bounded string.`);
  }
}

function optionalString(value, field, maximumLength) {
  if (value !== undefined && (typeof value !== "string" || value.length > maximumLength)) {
    throw new ProtocolError("invalid_payload", `${field} must be a bounded string.`);
  }
}

function requireObject(value, field) {
  if (!isObject(value)) {
    throw new ProtocolError("invalid_payload", `${field} must be a JSON object.`);
  }
  return value;
}

function requireInteger(value, field, minimum) {
  if (!Number.isInteger(value) || value < minimum) {
    throw new ProtocolError("invalid_payload", `${field} must be an integer >= ${minimum}.`);
  }
}

function optionalInteger(value, field, minimum, maximum) {
  if (value !== undefined && (!Number.isInteger(value) || value < minimum || value > maximum)) {
    throw new ProtocolError("invalid_payload", `${field} must be an integer from ${minimum} through ${maximum}.`);
  }
}

function requireFiniteNumber(value, field, minimum, maximum) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new ProtocolError("invalid_payload", `${field} must be a finite number from ${minimum} through ${maximum}.`);
  }
}

function optionalBoolean(value, field) {
  if (value !== undefined && typeof value !== "boolean") {
    throw new ProtocolError("invalid_payload", `${field} must be a boolean.`);
  }
}

function requireBoolean(value, field) {
  if (typeof value !== "boolean") {
    throw new ProtocolError("invalid_payload", `${field} must be a boolean.`);
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
