export const HOST_ID = "com.nativeagent.chrome";
export const PROTOCOL_VERSION = 1;

export const ACTIONS = Object.freeze([
  "attach",
  "extension.reload",
  "tab.close",
  "navigate",
  "page.snapshot.read",
  "page.look",
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

export function tabStripLockError(error) {
  // Chrome supplies no code for its global tab-strip drag lock.
  return String(error?.message ?? error).includes("Tabs cannot be edited right now (user may be dragging a tab)")
    ? new ProtocolError("tab_strip_locked", "Chrome's tab strip is locked in some window: a tab drag that has not ended. None of your tabs is involved. It clears when the drag ends or Chrome is restarted.")
    : undefined;
}

export function errorResponse(request, error) {
  const normalized = tabStripLockError(error) ?? (error instanceof ProtocolError
    ? error
    : new ProtocolError("internal_error", `The extension could not complete the request: ${String(error?.message ?? error).slice(0, 300)}`));
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

// Navigation authority is wider than content-script access. Validate before
// creating a tab: rejected URLs must leave even the tab inventory untouched.
function requireNavigationURL(value, allowViewSource = true) {
  if (typeof value !== "string" || value.length > 8192) {
    throw new ProtocolError("invalid_url", "url must be a bounded URL string; nothing was dispatched.");
  }
  let parsed;
  try { parsed = new URL(value); }
  catch { throw new ProtocolError("invalid_url", "url is not a valid URL; nothing was dispatched."); }
  if (parsed.protocol === "view-source:" && allowViewSource) {
    return requireNavigationURL(value.slice("view-source:".length), false);
  }
  if (!["http:", "https:", "chrome:", "about:", "file:"].includes(parsed.protocol)) {
    throw new ProtocolError("url_scheme_not_allowed", `Navigation does not support ${parsed.protocol}; nothing was dispatched.`);
  }
  // These are browser process commands, not pages a tab can display.
  const command = parsed.protocol === "about:" ? parsed.pathname.split(/[/?#]/)[0].toLowerCase() : parsed.hostname;
  if (["chrome:", "about:"].includes(parsed.protocol) && ["crash", "crashdump", "kill", "hang", "shorthang", "quit", "restart", "inducebrowsercrashforrealz", "memory-exhaust"].includes(command)) {
    throw new ProtocolError("navigation_url_blocked", `${parsed.href} is a browser process command, not a readable page; nothing was dispatched.`);
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
    case "page.look":
      requireInteger(payload.tabId, "tabId", 0);
      optionalInteger(payload.expectedUserSequence, "expectedUserSequence", 0, Number.MAX_SAFE_INTEGER);
      return;
    case "navigate":
      optionalInteger(payload.tabId, "tabId", 0, Number.MAX_SAFE_INTEGER);
      optionalInteger(payload.expectedUserSequence, "expectedUserSequence", 0, Number.MAX_SAFE_INTEGER);
      // "back" / "forward" walk the owned tab's own history.
      if (payload.url !== "back" && payload.url !== "forward") requireNavigationURL(payload.url);
      return;
    case "page.snapshot.read":
      requireInteger(payload.tabId, "tabId", 0);
      optionalInteger(payload.expectedUserSequence, "expectedUserSequence", 0, Number.MAX_SAFE_INTEGER);
      if (payload.readCursor !== undefined) {
        const cursor = requireObject(payload.readCursor, "readCursor");
        requireHttpURL(cursor.url);
        optionalString(cursor.frameURL, "frameURL", 8192);
        requireInteger(cursor.frameId, "frameId", 0);
        if (cursor.position !== undefined) {
          const position = requireObject(cursor.position, "position");
          for (const key of ["scrollX", "scrollY", "x", "y"]) {
            requireFiniteNumber(position[key], `position.${key}`, -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
          }
          requireFiniteNumber(position.distance, "position.distance", 0, Number.MAX_SAFE_INTEGER);
          requireInteger(position.ordinal, "position.ordinal", 0);
        }
        optionalInteger(cursor.textOffset, "textOffset", 0, Number.MAX_SAFE_INTEGER);
        optionalInteger(cursor.optionOffset, "optionOffset", 0, Number.MAX_SAFE_INTEGER);
        optionalBoolean(cursor.elementOnly, "elementOnly");
        if (cursor.viewportObservationId !== undefined) {
          requireId(cursor.viewportObservationId, "viewportObservationId");
        }
        if ((cursor.elementOnly === true || cursor.optionOffset !== undefined || cursor.textOffset !== undefined) && !cursor.position) {
          throw new ProtocolError("invalid_payload", "A folded continuation requires its page position.");
        }
        if (cursor.elementPath !== undefined || cursor.addressFragment !== undefined) {
          throw new ProtocolError("invalid_payload", "Read continuations use page positions; read the current viewport to get a new continuation.");
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
  trustedKeyEvents(value);
}

// The wire contract owns key spelling and CDP encoding. The page never
// implements keyboard defaults; Chrome and the focused editor own them.
export function trustedKeyEvents(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 64) {
    throw new ProtocolError("invalid_payload", "key must be a bounded key specification.");
  }
  const parts = [];
  let base = value, match;
  while ((match = /^(Alt|Control|Meta|Shift)\+/.exec(base))) {
    if (parts.includes(match[1])) throw new ProtocolError("invalid_payload", "A key modifier may occur only once.");
    parts.push(match[1]); base = base.slice(match[0].length);
  }
  const named = { Enter: ["Enter", 13, "\r"], Tab: ["Tab", 9], Escape: ["Escape", 27],
    ArrowDown: ["ArrowDown", 40], ArrowUp: ["ArrowUp", 38], ArrowLeft: ["ArrowLeft", 37], ArrowRight: ["ArrowRight", 39],
    Home: ["Home", 36], End: ["End", 35], PageUp: ["PageUp", 33], PageDown: ["PageDown", 34],
    Backspace: ["Backspace", 8], Delete: ["Delete", 46], Space: ["Space", 32, " "], F5: ["F5", 116],
    // Physical keypad definitions match Playwright's server/usKeyboardLayout.ts.
    NumpadEnter: ["NumpadEnter", 13, "\r", "Enter"],
    Numpad5: ["Numpad5", 12, "", "Clear", { key: "5", keyCode: 101, text: "5" }],
    NumpadSubtract: ["NumpadSubtract", 109, "-", "-"] };
  const printable = [...base].length === 1 && !/[\p{C}\p{Zl}\p{Zp}]/u.test(base);
  if (!named[base] && !printable) throw new ProtocolError("invalid_payload", "Use a named navigation/editing key or one printable character, with optional modifiers.");
  const modifiers = (parts.includes("Alt") ? 1 : 0) | (parts.includes("Control") ? 2 : 0)
    | (parts.includes("Meta") ? 4 : 0) | (parts.includes("Shift") ? 8 : 0);
  const shiftedNamed = parts.includes("Shift") ? named[base]?.[4] : undefined;
  let key = shiftedNamed?.key ?? named[base]?.[3] ?? (base === "Space" ? " " : base);
  let code = named[base]?.[0] ?? "", windowsVirtualKeyCode = shiftedNamed?.keyCode ?? named[base]?.[1] ?? 0;
  if (/^[a-z]$/i.test(base)) {
    key = parts.includes("Shift") ? base.toUpperCase() : base;
    code = `Key${base.toUpperCase()}`; windowsVirtualKeyCode = base.toUpperCase().charCodeAt(0);
  } else if (/^[0-9]$/.test(base)) {
    code = `Digit${base}`; windowsVirtualKeyCode = base.charCodeAt(0);
    if (parts.includes("Shift")) key = ")!@#$%^&*("[Number(base)];
  } else if (printable && !named[base]) {
    const physical = { "`": ["Backquote", 192], "~": ["Backquote", 192], "-": ["Minus", 189], "_": ["Minus", 189],
      "=": ["Equal", 187], "+": ["Equal", 187], "[": ["BracketLeft", 219], "{": ["BracketLeft", 219],
      "]": ["BracketRight", 221], "}": ["BracketRight", 221], "\\": ["Backslash", 220], "|": ["Backslash", 220],
      ";": ["Semicolon", 186], ":": ["Semicolon", 186], "'": ["Quote", 222], '"': ["Quote", 222],
      ",": ["Comma", 188], "<": ["Comma", 188], ".": ["Period", 190], ">": ["Period", 190], "/": ["Slash", 191], "?": ["Slash", 191] };
    if (physical[base]) [code, windowsVirtualKeyCode] = physical[base];
    if (parts.includes("Shift")) {
      const plain = "`-=[]\\;',./", shifted = '~_+{}|:"<>?';
      const index = plain.indexOf(base);
      if (index >= 0) key = shifted[index];
    }
    const shiftedDigit = ")!@#$%^&*(".indexOf(base);
    if (shiftedDigit >= 0) { code = `Digit${shiftedDigit}`; windowsVirtualKeyCode = 48 + shiftedDigit; }
  }
  const text = modifiers & (1 | 2 | 4) ? "" : shiftedNamed?.text ?? named[base]?.[2] ?? (printable ? key : "");
  const common = { key, code, windowsVirtualKeyCode, modifiers,
    ...(code.startsWith("Numpad") ? { location: 3, isKeypad: true } : {}) };
  return { expectedKeydown: { key, altKey: !!(modifiers & 1), ctrlKey: !!(modifiers & 2),
    metaKey: !!(modifiers & 4), shiftKey: !!(modifiers & 8) }, events: [
    // Combined keyDown lets Chromium generate (and cancel) its own character.
    // Without text, keyDown has rawKeyDown semantics. Never send a second char.
    { ...common, type: "keyDown", ...(text ? { text, unmodifiedText: text } : {}), commands: macEditingCommands(code, modifiers) },
    { ...common, type: "keyUp" },
  ] };
}

// CDP bypasses AppKit's NSStandardKeyBindingResponding translation. Complete
// Playwright macEditingCommands table (including multi-command entries):
// https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/macEditingCommands.ts
// Chromium command vocabulary:
// https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/editing/commands/editor_command_names.h
// Chromium also defines Shift+Meta+KeyV in its macOS editing menu accelerators:
// https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/cocoa/accelerators_cocoa.mm
// Keep exact modifier+code entries; never infer a command from a partial match.
/*
 * Copyright 2017 Google Inc. All rights reserved.
 * Modifications copyright (c) Microsoft Corporation.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *     http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
const MAC_EDITING_COMMANDS = {
  'Backspace': 'deleteBackward:',
  'Enter': 'insertNewline:',
  'NumpadEnter': 'insertNewline:',
  'Escape': 'cancelOperation:',
  'ArrowUp': 'moveUp:',
  'ArrowDown': 'moveDown:',
  'ArrowLeft': 'moveLeft:',
  'ArrowRight': 'moveRight:',
  'F5': 'complete:',
  'Delete': 'deleteForward:',
  'Home': 'scrollToBeginningOfDocument:',
  'End': 'scrollToEndOfDocument:',
  'PageUp': 'scrollPageUp:',
  'PageDown': 'scrollPageDown:',
  'Shift+Backspace': 'deleteBackward:',
  'Shift+Enter': 'insertNewline:',
  'Shift+NumpadEnter': 'insertNewline:',
  'Shift+Escape': 'cancelOperation:',
  'Shift+ArrowUp': 'moveUpAndModifySelection:',
  'Shift+ArrowDown': 'moveDownAndModifySelection:',
  'Shift+ArrowLeft': 'moveLeftAndModifySelection:',
  'Shift+ArrowRight': 'moveRightAndModifySelection:',
  'Shift+F5': 'complete:',
  'Shift+Delete': 'deleteForward:',
  'Shift+Home': 'moveToBeginningOfDocumentAndModifySelection:',
  'Shift+End': 'moveToEndOfDocumentAndModifySelection:',
  'Shift+PageUp': 'pageUpAndModifySelection:',
  'Shift+PageDown': 'pageDownAndModifySelection:',
  'Shift+Numpad5': 'delete:',
  'Control+Tab': 'selectNextKeyView:',
  'Control+Enter': 'insertLineBreak:',
  'Control+NumpadEnter': 'insertLineBreak:',
  'Control+Quote': 'insertSingleQuoteIgnoringSubstitution:',
  'Control+KeyA': 'moveToBeginningOfParagraph:',
  'Control+KeyB': 'moveBackward:',
  'Control+KeyD': 'deleteForward:',
  'Control+KeyE': 'moveToEndOfParagraph:',
  'Control+KeyF': 'moveForward:',
  'Control+KeyH': 'deleteBackward:',
  'Control+KeyK': 'deleteToEndOfParagraph:',
  'Control+KeyL': 'centerSelectionInVisibleArea:',
  'Control+KeyN': 'moveDown:',
  'Control+KeyO': ['insertNewlineIgnoringFieldEditor:', 'moveBackward:'],
  'Control+KeyP': 'moveUp:',
  'Control+KeyT': 'transpose:',
  'Control+KeyV': 'pageDown:',
  'Control+KeyY': 'yank:',
  'Control+Backspace': 'deleteBackwardByDecomposingPreviousCharacter:',
  'Control+ArrowUp': 'scrollPageUp:',
  'Control+ArrowDown': 'scrollPageDown:',
  'Control+ArrowLeft': 'moveToLeftEndOfLine:',
  'Control+ArrowRight': 'moveToRightEndOfLine:',
  'Shift+Control+Enter': 'insertLineBreak:',
  'Shift+Control+NumpadEnter': 'insertLineBreak:',
  'Shift+Control+Tab': 'selectPreviousKeyView:',
  'Shift+Control+Quote': 'insertDoubleQuoteIgnoringSubstitution:',
  'Shift+Control+KeyA': 'moveToBeginningOfParagraphAndModifySelection:',
  'Shift+Control+KeyB': 'moveBackwardAndModifySelection:',
  'Shift+Control+KeyE': 'moveToEndOfParagraphAndModifySelection:',
  'Shift+Control+KeyF': 'moveForwardAndModifySelection:',
  'Shift+Control+KeyN': 'moveDownAndModifySelection:',
  'Shift+Control+KeyP': 'moveUpAndModifySelection:',
  'Shift+Control+KeyV': 'pageDownAndModifySelection:',
  'Shift+Control+Backspace': 'deleteBackwardByDecomposingPreviousCharacter:',
  'Shift+Control+ArrowUp': 'scrollPageUp:',
  'Shift+Control+ArrowDown': 'scrollPageDown:',
  'Shift+Control+ArrowLeft': 'moveToLeftEndOfLineAndModifySelection:',
  'Shift+Control+ArrowRight': 'moveToRightEndOfLineAndModifySelection:',
  'Alt+Backspace': 'deleteWordBackward:',
  'Alt+Enter': 'insertNewlineIgnoringFieldEditor:',
  'Alt+NumpadEnter': 'insertNewlineIgnoringFieldEditor:',
  'Alt+Escape': 'complete:',
  'Alt+ArrowUp': ['moveBackward:', 'moveToBeginningOfParagraph:'],
  'Alt+ArrowDown': ['moveForward:', 'moveToEndOfParagraph:'],
  'Alt+ArrowLeft': 'moveWordLeft:',
  'Alt+ArrowRight': 'moveWordRight:',
  'Alt+Delete': 'deleteWordForward:',
  'Alt+PageUp': 'pageUp:',
  'Alt+PageDown': 'pageDown:',
  'Shift+Alt+Backspace': 'deleteWordBackward:',
  'Shift+Alt+Enter': 'insertNewlineIgnoringFieldEditor:',
  'Shift+Alt+NumpadEnter': 'insertNewlineIgnoringFieldEditor:',
  'Shift+Alt+Escape': 'complete:',
  'Shift+Alt+ArrowUp': 'moveParagraphBackwardAndModifySelection:',
  'Shift+Alt+ArrowDown': 'moveParagraphForwardAndModifySelection:',
  'Shift+Alt+ArrowLeft': 'moveWordLeftAndModifySelection:',
  'Shift+Alt+ArrowRight': 'moveWordRightAndModifySelection:',
  'Shift+Alt+Delete': 'deleteWordForward:',
  'Shift+Alt+PageUp': 'pageUp:',
  'Shift+Alt+PageDown': 'pageDown:',
  'Control+Alt+KeyB': 'moveWordBackward:',
  'Control+Alt+KeyF': 'moveWordForward:',
  'Control+Alt+Backspace': 'deleteWordBackward:',
  'Shift+Control+Alt+KeyB': 'moveWordBackwardAndModifySelection:',
  'Shift+Control+Alt+KeyF': 'moveWordForwardAndModifySelection:',
  'Shift+Control+Alt+Backspace': 'deleteWordBackward:',
  'Meta+NumpadSubtract': 'cancel:',
  'Meta+Backspace': 'deleteToBeginningOfLine:',
  'Meta+ArrowUp': 'moveToBeginningOfDocument:',
  'Meta+ArrowDown': 'moveToEndOfDocument:',
  'Meta+ArrowLeft': 'moveToLeftEndOfLine:',
  'Meta+ArrowRight': 'moveToRightEndOfLine:',
  'Shift+Meta+NumpadSubtract': 'cancel:',
  'Shift+Meta+Backspace': 'deleteToBeginningOfLine:',
  'Shift+Meta+ArrowUp': 'moveToBeginningOfDocumentAndModifySelection:',
  'Shift+Meta+ArrowDown': 'moveToEndOfDocumentAndModifySelection:',
  'Shift+Meta+ArrowLeft': 'moveToLeftEndOfLineAndModifySelection:',
  'Shift+Meta+ArrowRight': 'moveToRightEndOfLineAndModifySelection:',
  'Meta+KeyA': 'selectAll:',
  'Meta+KeyC': 'copy:',
  'Meta+KeyX': 'cut:',
  'Meta+KeyV': 'paste:',
  'Meta+KeyZ': 'undo:',
  'Shift+Meta+KeyZ': 'redo:',
  'Shift+Meta+KeyV': 'pasteAndMatchStyle:',
};

function macEditingCommands(code, modifiers) {
  // Same canonical spelling and CDP conversion as Playwright's crInput.ts:
  // https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/chromium/crInput.ts
  const shortcut = [["Shift", 8], ["Control", 2], ["Alt", 1], ["Meta", 4]]
    .filter(([, mask]) => modifiers & mask).map(([name]) => name).concat(code).join("+");
  if (!Object.hasOwn(MAC_EDITING_COMMANDS, shortcut)) return [];
  const entry = MAC_EDITING_COMMANDS[shortcut];
  // CDP does not support AppKit insert* selectors as editing commands. Chrome
  // receives text through the combined keyDown instead, as in Playwright.
  return (Array.isArray(entry) ? entry : [entry])
    .filter(command => !command.startsWith("insert")).map(command => command.slice(0, -1));
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
