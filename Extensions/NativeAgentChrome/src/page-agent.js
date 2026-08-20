(() => {
  const MAX_AGGREGATE_NODE_TEXT = 200_000;
  const snapshots = new Map();
  let domGeneration = 0;

  new MutationObserver(() => {
    domGeneration += 1;
    const invalidatedSnapshotIds = [...snapshots.keys()];
    snapshots.clear();
    if (invalidatedSnapshotIds.length > 0) {
      if (typeof chrome.runtime.sendMessage === "function") {
        void chrome.runtime.sendMessage({
          type: "nativeagent.page.mutated",
          snapshotIds: invalidatedSnapshotIds,
        }).catch(() => {});
      }
    }
  }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message?.type?.startsWith("nativeagent.page.")) return false;
    try {
      switch (message.type) {
        case "nativeagent.page.snapshot":
          sendResponse({ ok: true, result: createSnapshot(message) });
          break;
        case "nativeagent.page.click":
          sendResponse({ ok: true, result: clickNode(message) });
          break;
        case "nativeagent.page.fill":
          sendResponse({ ok: true, result: fillNode(message) });
          break;
        case "nativeagent.page.type":
          void typeIntoNode(message).then(
            (result) => sendResponse({ ok: true, result }),
            (error) => sendPageError(sendResponse, error),
          );
          return true;
        case "nativeagent.page.select":
          sendResponse({ ok: true, result: selectNode(message) });
          break;
        case "nativeagent.page.keypress":
          sendResponse({ ok: true, result: keypressNode(message) });
          break;
        case "nativeagent.page.set_checked":
          sendResponse({ ok: true, result: setCheckedNode(message) });
          break;
        case "nativeagent.page.double_click":
          sendResponse({ ok: true, result: doubleClickNode(message) });
          break;
        case "nativeagent.page.wait":
          void waitForNodeState(message).then(
            (result) => sendResponse({ ok: true, result }),
            (error) => sendPageError(sendResponse, error),
          );
          return true;
        case "nativeagent.page.scroll":
          sendResponse({ ok: true, result: scrollPage(message) });
          break;
        default:
          sendResponse({ ok: false, error: { code: "unknown_page_action", message: "Unknown page action." } });
      }
    } catch (error) {
      sendPageError(sendResponse, error);
    }
    return false;
  });

  function createSnapshot(message) {
    const maxNodes = clampInteger(message.maxNodes, 1, 500, 500);
    const maxTextChars = clampInteger(message.maxTextChars, 1, 50_000, 50_000);
    const snapshotId = crypto.randomUUID();
    const elementByNodeId = new Map();
    const actionNodeIds = new Map();
    const nodeIdByElement = new Map();
    const nodes = [];
    const truncationReasons = [];
    const walk = composedElementWalk(document.body);
    const candidates = walk.elements;
    let aggregateNodeText = 0;
    if (walk.truncated) truncationReasons.push("walk_limit");

    for (const element of candidates) {
      if (nodes.length >= maxNodes) {
        truncationReasons.push("node_limit");
        break;
      }
      if (!isVisible(element)) continue;
      const kind = elementKind(element);
      const text = bounded(normalizedText(element.innerText ?? element.textContent ?? ""), 1_000);
      const name = bounded(accessibleName(element, text), 500);
      if (!name && !text && kind === "other") continue;
      const nodeTextCost = text.length + name.length;
      if (aggregateNodeText + nodeTextCost > MAX_AGGREGATE_NODE_TEXT) {
        truncationReasons.push("encoded_size_limit");
        break;
      }
      aggregateNodeText += nodeTextCost;

      const nodeId = `n${nodes.length + 1}`;
      nodeIdByElement.set(element, nodeId);
      elementByNodeId.set(nodeId, element);
      const rect = element.getBoundingClientRect();
      const role = element.getAttribute("role") ?? implicitRole(element);
      const actions = [];
      if (isClickable(element, role)) actions.push("click", "double_click");
      if (isEditable(element)) actions.push("fill", "type");
      if (isSelectable(element)) actions.push("select");
      if (isCheckable(element, role)) actions.push("set_checked");
      if (isKeypressable(element, role)) actions.push("keypress");
      if (!isPasswordField(element)) actions.push("wait");
      if (isScrollable(element)) actions.push("scroll");

      if (isPasswordField(element)) actions.length = 0;

      let parent = composedParent(element);
      while (parent && !nodeIdByElement.has(parent)) parent = composedParent(parent);
      nodes.push({
        nodeId,
        parentNodeId: parent ? nodeIdByElement.get(parent) : null,
        kind,
        role,
        name,
        text,
        value: safeValue(element),
        level: headingLevel(element),
        visible: true,
        states: {
          disabled: Boolean(element.disabled) || element.getAttribute("aria-disabled") === "true",
          checked: ariaBoolean(element, "aria-checked", "checked"),
          selected: ariaBoolean(element, "aria-selected", "selected"),
          expanded: nullableAriaBoolean(element.getAttribute("aria-expanded")),
          editable: isEditable(element),
        },
        actions,
        url: safeURL(element),
        bounds: {
          x: finite(rect.x), y: finite(rect.y), width: Math.max(0, finite(rect.width)), height: Math.max(0, finite(rect.height)),
        },
        scrollable: actions.includes("scroll"),
      });
      for (const action of actions) {
        if (!actionNodeIds.has(action)) actionNodeIds.set(action, new Set());
        actionNodeIds.get(action).add(nodeId);
      }
    }

    const rawSummary = normalizedText(document.body?.innerText ?? document.body?.textContent ?? "");
    const summaryText = bounded(rawSummary, maxTextChars);
    if (summaryText.length < rawSummary.length) truncationReasons.push("text_limit");
    const snapshot = {
      snapshotId,
      leaseId: message.leaseId,
      tabId: message.tabId,
      userSequence: message.userSequence,
      capturedAt: new Date().toISOString(),
      url: location.href,
      title: bounded(document.title ?? "", 1_024),
      language: bounded(document.documentElement?.lang ?? navigator.language ?? "", 64),
      viewport: {
        width: finite(window.innerWidth),
        height: finite(window.innerHeight),
        scrollX: finite(window.scrollX),
        scrollY: finite(window.scrollY),
        documentWidth: finite(document.documentElement?.scrollWidth),
        documentHeight: finite(document.documentElement?.scrollHeight),
      },
      summary: {
        text: summaryText,
        nodeCount: nodes.length,
        truncated: truncationReasons.length > 0,
        truncationReasons: [...new Set(truncationReasons)],
      },
      nodes,
      frame: {
        name: bounded(frameName(), 500),
        url: location.href,
      },
    };
    snapshots.clear();
    snapshots.set(snapshotId, { domGeneration, elementByNodeId, actionNodeIds });
    return snapshot;
  }

  function clickNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "click");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    element.click();
    return { snapshotId: message.snapshotId, nodeId: message.nodeId, clicked: true };
  }

  function fillNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "fill");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    focusWithoutActivation(element);
    replaceEditableValue(element, message.value);
    dispatchEditableEvent(element, "input", message.value);
    dispatchEditableEvent(element, "change", message.value);
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      filled: true,
      valueLength: message.value.length,
    };
  }

  async function typeIntoNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "type");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    focusWithoutActivation(element);
    let typedCount = 0;
    for (const character of [...message.text]) {
      if (!element.isConnected) {
        throw pageError(
          typedCount > 0 ? "action_outcome_unknown" : "node_stale",
          typedCount > 0
            ? "The editable node was replaced after typing began; the partial outcome is unknown."
            : "The snapshot node is no longer attached.",
        );
      }
      appendEditableValue(element, character);
      dispatchEditableEvent(element, "input", character);
      typedCount += 1;
      if (message.delayMs > 0) await delay(message.delayMs);
    }
    dispatchEditableEvent(element, "change", message.text);
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      typed: true,
      characterCount: typedCount,
    };
  }

  function selectNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "select");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    const requested = new Set(message.values);
    const options = Array.from(element.options ?? []);
    const knownValues = new Set(options.map((option) => String(option.value)));
    const missing = message.values.filter((value) => !knownValues.has(value));
    if (missing.length > 0) {
      throw pageError("option_not_found", "At least one requested option value was not in the observed select node.");
    }
    if (!element.multiple && message.values.length !== 1) {
      throw pageError("invalid_selection", "A single-select node requires exactly one option value.");
    }
    for (const option of options) option.selected = requested.has(String(option.value));
    dispatchEditableEvent(element, "input", null);
    dispatchEditableEvent(element, "change", null);
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      selected: true,
      values: options.filter((option) => option.selected).map((option) => String(option.value)),
    };
  }

  function keypressNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "keypress");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    const spec = parseKeySpec(message.key);
    focusWithoutActivation(element);
    const downAccepted = dispatchKeyboardEvent(element, "keydown", spec);
    if (downAccepted) applyKeyDefault(element, spec);
    dispatchKeyboardEvent(element, "keyup", spec);
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      keypressed: true,
      key: message.key,
      defaultPrevented: !downAccepted,
    };
  }

  function setCheckedNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "set_checked");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    const role = element.getAttribute("role") ?? implicitRole(element);
    const before = checkedState(element);
    if (before !== message.checked) {
      if (isNativeCheckable(element)) {
        element.checked = message.checked;
        dispatchEditableEvent(element, "input", null);
        dispatchEditableEvent(element, "change", null);
      } else {
        element.click();
      }
    }
    const after = checkedState(element);
    if (after !== message.checked) {
      throw pageError("checked_state_not_applied", `The ${role || "checkable"} node did not reach the requested state.`);
    }
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      setChecked: true,
      checked: after,
      changed: before !== after,
    };
  }

  function doubleClickNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "double_click");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    element.click();
    element.click();
    if (typeof MouseEvent === "function") {
      element.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, composed: true, detail: 2, button: 0 }));
    }
    return { snapshotId: message.snapshotId, nodeId: message.nodeId, doubleClicked: true };
  }

  async function waitForNodeState(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "wait");
    const deadline = Date.now() + message.timeoutMs;
    while (true) {
      if (nodeMatchesState(element, message.state)) {
        return {
          snapshotId: message.snapshotId,
          nodeId: message.nodeId,
          state: message.state,
          matched: true,
        };
      }
      if (Date.now() >= deadline) {
        return {
          snapshotId: message.snapshotId,
          nodeId: message.nodeId,
          state: message.state,
          matched: false,
        };
      }
      await delay(Math.min(50, Math.max(1, deadline - Date.now())));
    }
  }

  function scrollPage(message) {
    let target = window;
    if (message.targetNodeId) {
      target = requireSnapshotNode(message.snapshotId, message.targetNodeId);
    }
    target.scrollBy({ left: message.deltaX, top: message.deltaY, behavior: "auto" });
    return {
      snapshotId: message.snapshotId ?? null,
      targetNodeId: message.targetNodeId ?? null,
      scrolled: true,
      scrollX: finite(window.scrollX),
      scrollY: finite(window.scrollY),
    };
  }

  function requireSnapshotNode(snapshotId, nodeId) {
    const snapshot = requireSnapshot(snapshotId);
    const element = snapshot.elementByNodeId.get(nodeId);
    if (!element?.isConnected) throw pageError("node_stale", "The snapshot node is no longer attached.");
    return element;
  }

  function requireActionableSnapshotNode(snapshotId, nodeId, action) {
    const snapshot = requireSnapshot(snapshotId);
    if (!snapshot.actionNodeIds.get(action)?.has(nodeId)) {
      throw pageError("node_not_actionable", `The snapshot node did not advertise a ${action} action.`);
    }
    return requireSnapshotNode(snapshotId, nodeId);
  }

  function requireSnapshot(snapshotId) {
    const snapshot = snapshots.get(snapshotId);
    if (!snapshot || snapshot.domGeneration !== domGeneration) {
      throw pageError("snapshot_stale", "The page changed after this snapshot was captured.");
    }
    return snapshot;
  }

  function elementKind(element) {
    const tag = element.tagName.toLowerCase();
    const role = element.getAttribute("role") ?? "";
    if (/^h[1-6]$/.test(tag) || role === "heading") return "heading";
    if (tag === "a" || role === "link") return "link";
    if (tag === "button" || role === "button") return "button";
    if (["input", "textarea"].includes(tag)) return "input";
    if (tag === "select") return "select";
    if (tag === "option") return "option";
    if (tag === "img") return "image";
    if (["ul", "ol"].includes(tag)) return "list";
    if (tag === "li") return "listitem";
    if (tag === "table") return "table";
    if (tag === "tr") return "row";
    if (["td", "th"].includes(tag)) return "cell";
    if (role === "dialog") return "dialog";
    if (role === "menu") return "menu";
    if (role === "menuitem") return "menuitem";
    if (role === "tab") return "tab";
    if (role === "tabpanel") return "tabpanel";
    if (["main", "nav", "aside", "header", "footer", "section"].includes(tag)) return "landmark";
    return "other";
  }

  function implicitRole(element) {
    const kind = elementKind(element);
    return kind === "other" ? "" : kind;
  }

  function accessibleName(element, fallback) {
    return element.getAttribute("aria-label")
      ?? element.getAttribute("alt")
      ?? element.getAttribute("title")
      ?? element.labels?.[0]?.innerText
      ?? fallback;
  }

  function safeValue(element) {
    if (!("value" in element)) return null;
    if (element.tagName.toLowerCase() === "input" && element.type?.toLowerCase() === "password") return null;
    return bounded(String(element.value ?? ""), 500);
  }

  function safeURL(element) {
    const raw = element.href;
    if (typeof raw !== "string") return null;
    try {
      const parsed = new URL(raw, location.href);
      return parsed.protocol === "http:" || parsed.protocol === "https:" ? bounded(parsed.href, 2_048) : null;
    } catch { return null; }
  }

  function isVisible(element) {
    const style = getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function isClickable(element, role) {
    const tag = element.tagName.toLowerCase();
    return ["a", "button", "summary", "option"].includes(tag)
      || ["button", "link", "menuitem", "tab", "checkbox", "radio"].includes(role)
      || typeof element.onclick === "function";
  }

  function isEditable(element) {
    const tag = element.tagName.toLowerCase();
    if (tag === "textarea" || element.isContentEditable) return true;
    if (tag !== "input" || isPasswordField(element)) return false;
    const type = (element.type || "text").toLowerCase();
    return ["text", "search", "email", "url", "tel", "number", "date", "datetime-local", "month", "time", "week"].includes(type);
  }

  function isSelectable(element) {
    return element.tagName.toLowerCase() === "select" && !element.disabled;
  }

  function isNativeCheckable(element) {
    const tag = element.tagName.toLowerCase();
    const type = element.type?.toLowerCase();
    return tag === "input" && (type === "checkbox" || type === "radio");
  }

  function isCheckable(element, role) {
    return isNativeCheckable(element) || ["checkbox", "radio", "switch"].includes(role);
  }

  function isKeypressable(element, role) {
    if (isPasswordField(element)) return false;
    const tag = element.tagName.toLowerCase();
    return isEditable(element) || isSelectable(element) || isClickable(element, role)
      || element.tabIndex >= 0 || ["combobox", "listbox", "option"].includes(role);
  }

  function isPasswordField(element) {
    return element.tagName.toLowerCase() === "input" && element.type?.toLowerCase() === "password";
  }

  function focusWithoutActivation(element) {
    if (typeof element.focus !== "function") return;
    try { element.focus({ preventScroll: true }); } catch { element.focus(); }
  }

  function replaceEditableValue(element, value) {
    if (element.isContentEditable) {
      element.textContent = value;
      return;
    }
    setNativeValue(element, value);
  }

  function appendEditableValue(element, value) {
    if (element.isContentEditable) {
      element.textContent = `${element.textContent ?? ""}${value}`;
      return;
    }
    setNativeValue(element, `${element.value ?? ""}${value}`);
  }

  function setNativeValue(element, value) {
    const prototype = Object.getPrototypeOf(element);
    const setter = prototype ? Object.getOwnPropertyDescriptor(prototype, "value")?.set : undefined;
    if (setter) setter.call(element, value);
    else element.value = value;
  }

  function dispatchEditableEvent(element, type, data) {
    if (typeof element.dispatchEvent !== "function") return;
    let event;
    if (type === "input" && typeof InputEvent === "function") {
      event = new InputEvent(type, { bubbles: true, composed: true, inputType: "insertText", data });
    } else {
      event = new Event(type, { bubbles: true, composed: true });
    }
    element.dispatchEvent(event);
  }

  function checkedState(element) {
    if (typeof element.checked === "boolean" && isNativeCheckable(element)) return element.checked;
    return nullableAriaBoolean(element.getAttribute("aria-checked"));
  }

  function parseKeySpec(value) {
    const parts = String(value).split("+");
    const namedKey = parts.pop();
    return {
      key: namedKey === "Space" ? " " : namedKey,
      altKey: parts.includes("Alt"),
      ctrlKey: parts.includes("Control"),
      metaKey: parts.includes("Meta"),
      shiftKey: parts.includes("Shift"),
    };
  }

  function dispatchKeyboardEvent(element, type, spec) {
    if (typeof KeyboardEvent !== "function") return true;
    return element.dispatchEvent(new KeyboardEvent(type, { ...spec, bubbles: true, composed: true, cancelable: true }));
  }

  function applyKeyDefault(element, spec) {
    const selectAll = spec.key === "A" && (spec.ctrlKey || spec.metaKey);
    if (selectAll && typeof element.select === "function") {
      element.select();
      return;
    }
    if (spec.key === "Tab") {
      moveFocus(element, spec.shiftKey ? -1 : 1);
      return;
    }
    if (spec.key === "Enter") {
      const tag = element.tagName.toLowerCase();
      if (["button", "a", "summary"].includes(tag)) element.click();
      else if (element.form && typeof element.form.requestSubmit === "function") element.form.requestSubmit();
      return;
    }
    if (spec.key === " " && (isNativeCheckable(element) || isClickable(element, element.getAttribute("role") ?? implicitRole(element)))) {
      element.click();
      return;
    }
    if (["Backspace", "Delete"].includes(spec.key)) {
      deleteFromEditable(element, spec.key === "Backspace");
      return;
    }
    if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(spec.key)) {
      moveEditableCaret(element, spec.key);
    }
  }

  function moveFocus(element, direction) {
    const focusable = composedElementWalk(document.body).elements.filter((candidate) => {
      if (!isVisible(candidate) || candidate.disabled) return false;
      const tag = candidate.tagName.toLowerCase();
      return candidate.tabIndex >= 0 || ["a", "button", "input", "select", "textarea", "summary"].includes(tag);
    });
    if (focusable.length === 0) return;
    const current = focusable.indexOf(element);
    const next = current < 0
      ? (direction > 0 ? 0 : focusable.length - 1)
      : (current + direction + focusable.length) % focusable.length;
    focusWithoutActivation(focusable[next]);
  }

  function deleteFromEditable(element, backward) {
    if (!("value" in element) || typeof element.selectionStart !== "number" || typeof element.selectionEnd !== "number") return;
    let start = element.selectionStart;
    let end = element.selectionEnd;
    if (start === end) {
      if (backward && start > 0) start -= 1;
      if (!backward && end < String(element.value ?? "").length) end += 1;
    }
    if (start === end) return;
    const current = String(element.value ?? "");
    setNativeValue(element, `${current.slice(0, start)}${current.slice(end)}`);
    if (typeof element.setSelectionRange === "function") element.setSelectionRange(start, start);
    dispatchEditableEvent(element, "input", null);
  }

  function moveEditableCaret(element, key) {
    if (!("value" in element) || typeof element.selectionStart !== "number") return;
    const length = String(element.value ?? "").length;
    let caret = element.selectionStart;
    if (key === "ArrowLeft") caret = Math.max(0, caret - 1);
    if (key === "ArrowRight") caret = Math.min(length, caret + 1);
    if (key === "Home") caret = 0;
    if (key === "End") caret = length;
    if (typeof element.setSelectionRange === "function") element.setSelectionRange(caret, caret);
  }

  function composedElementWalk(root, maximum = 5_000) {
    if (!root) return { elements: [], truncated: false };
    const result = [];
    const stack = Array.from(root.children ?? []).reverse();
    while (stack.length > 0 && result.length < maximum) {
      const element = stack.pop();
      result.push(element);
      const descendants = [
        ...Array.from(element.shadowRoot?.children ?? []),
        ...Array.from(element.children ?? []),
      ];
      for (let index = descendants.length - 1; index >= 0; index -= 1) stack.push(descendants[index]);
    }
    return { elements: result, truncated: stack.length > 0 };
  }

  function composedParent(element) {
    if (element.parentElement) return element.parentElement;
    const root = typeof element.getRootNode === "function" ? element.getRootNode() : null;
    return root?.host ?? null;
  }

  function frameName() {
    try {
      return document.title || window.name || document.documentElement?.getAttribute("aria-label") || "";
    } catch {
      return document.title || "";
    }
  }

  function nodeMatchesState(element, state) {
    switch (state) {
      case "visible": return element.isConnected && isVisible(element);
      case "hidden": return !element.isConnected || !isVisible(element);
      case "enabled": return element.isConnected && !element.disabled && element.getAttribute("aria-disabled") !== "true";
      case "disabled": return !element.isConnected || Boolean(element.disabled) || element.getAttribute("aria-disabled") === "true";
      default: throw pageError("invalid_wait_state", "The requested element wait state is unsupported.");
    }
  }

  function sendPageError(sendResponse, error) {
    sendResponse({
      ok: false,
      error: {
        code: error.code ?? "page_action_failed",
        message: error.message ?? "The page action failed.",
      },
    });
  }

  function delay(milliseconds) { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }

  function isScrollable(element) {
    const style = getComputedStyle(element);
    return /(auto|scroll)/.test(`${style.overflow} ${style.overflowX} ${style.overflowY}`)
      && (element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth);
  }

  function headingLevel(element) {
    const tag = element.tagName.toLowerCase();
    if (/^h[1-6]$/.test(tag)) return Number(tag[1]);
    const value = Number(element.getAttribute("aria-level"));
    return Number.isInteger(value) && value >= 1 && value <= 9 ? value : null;
  }

  function ariaBoolean(element, ariaName, propertyName) {
    const aria = nullableAriaBoolean(element.getAttribute(ariaName));
    if (aria !== null) return aria;
    return typeof element[propertyName] === "boolean" ? element[propertyName] : null;
  }

  function nullableAriaBoolean(value) {
    if (value === "true") return true;
    if (value === "false") return false;
    return null;
  }

  function normalizedText(value) { return String(value).replace(/\s+/g, " ").trim(); }
  function bounded(value, maximum) { return String(value).slice(0, maximum); }
  function finite(value) { return Number.isFinite(Number(value)) ? Number(value) : 0; }
  function clampInteger(value, minimum, maximum, fallback) {
    return Number.isInteger(value) ? Math.min(maximum, Math.max(minimum, value)) : fallback;
  }
  function pageError(code, message) { return Object.assign(new Error(message), { code }); }
})();
