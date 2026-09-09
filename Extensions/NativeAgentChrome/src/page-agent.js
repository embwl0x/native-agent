(() => {
  const MAX_AGGREGATE_NODE_TEXT = 200_000;
  // Leave ten seconds of the host's thirty-second request deadline for the
  // content reply, extension receipt, and native-messaging transport.
  const MAX_TYPING_DURATION_MS = 20_000;
  const TYPE_YIELD_EVERY = 32;
  const snapshots = new Map();
  const typingRuns = new Set();
  const waitingRuns = new Set();
  let domGeneration = 0;

  for (const kind of ["pointerdown", "keydown", "wheel", "touchstart"]) {
    window.addEventListener(kind, (event) => {
      if (event.isTrusted !== true) return;
      snapshots.clear();
      for (const run of typingRuns) run.stopReason = "user_takeover";
      for (const run of waitingRuns) run.stopReason = "user_takeover";
    }, { capture: true, passive: true });
  }

  const MUTATION_SCOPE = { subtree: true, childList: true, attributes: true, characterData: true };
  // 2026-09-06: a MutationObserver on `document` does not see inside an open
  // shadow root, but the snapshot walker does — so a component that swapped its
  // own button out left every node id looking fresh. Each root the walker
  // entered is observed too.
  // Strong, on purpose: a MutationObserver already holds every node it observes
  // strongly, so a WeakSet only hid the roots from us — it never let one go.
  const observedShadowRoots = new Set();
  const domObserver = new MutationObserver((records) => {
    domGeneration += 1;
    const invalidatedSnapshotIds = [...snapshots.keys()];
    const retainedNavigationNodes = {};
    for (const [id, snapshot] of snapshots) {
      for (const [nodeId, proof] of snapshot.navigationProofs) {
        if (!records.length || records.some((record) =>
          !record.target || withinElement(record.target, proof.scope)
          || (record.type === "attributes" && withinElement(proof.element, record.target))
          || Array.from(record.removedNodes ?? []).some((node) => withinElement(proof.element, node)))
          || !navigationProofMatches(proof, snapshot)) snapshot.navigationProofs.delete(nodeId);
      }
      if (snapshot.navigationProofs.size) retainedNavigationNodes[id] = [...snapshot.navigationProofs.keys()];
      else snapshots.delete(id);
    }
    if (invalidatedSnapshotIds.length > 0) {
      if (typeof chrome.runtime?.sendMessage === "function") {
        void chrome.runtime.sendMessage({
          type: "nativeagent.page.mutated",
          snapshotIds: invalidatedSnapshotIds,
          retainedNavigationNodes,
        }).catch(() => {});
      }
    }
  });
  domObserver.observe(document, MUTATION_SCOPE);

  function observeShadowRoots(roots) {
    for (const root of roots) {
      if (!root || observedShadowRoots.has(root)) continue;
      observedShadowRoots.add(root);
      try {
        domObserver.observe(root, MUTATION_SCOPE);
      } catch {
        // A root that cannot be observed simply keeps the old behaviour for
        // its subtree; it must never cost the caller the whole snapshot.
        observedShadowRoots.delete(root);
      }
    }
  }

  // 2026-09-06: a MutationObserver cannot drop one of its targets, so every
  // shadow root the walker ever entered stayed observed — and alive — for the
  // life of the page, long after its host left the document. Each snapshot
  // rebuilds the observation set from the roots still attached. Records queued
  // before the rebuild describe a DOM the snapshot about to be taken already
  // reflects, so losing them costs nothing.
  function pruneObservedShadowRoots() {
    let stale = false;
    for (const root of observedShadowRoots) {
      if (root.host?.isConnected !== true) {
        observedShadowRoots.delete(root);
        stale = true;
      }
    }
    if (!stale) return;
    domObserver.disconnect();
    domObserver.observe(document, MUTATION_SCOPE);
    for (const root of observedShadowRoots) {
      try {
        domObserver.observe(root, MUTATION_SCOPE);
      } catch {
        observedShadowRoots.delete(root);
      }
    }
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message?.type?.startsWith("nativeagent.page.")) return false;
    try {
      switch (message.type) {
        case "nativeagent.page.lease.invalidated":
          for (const run of typingRuns) {
            if (run.leaseId === message.leaseId) run.stopReason = "lease_revoked";
          }
          for (const run of waitingRuns) {
            if (run.leaseId === message.leaseId) run.stopReason = "lease_revoked";
          }
          for (const [id, snapshot] of snapshots) {
            if (snapshot.leaseId === message.leaseId) snapshots.delete(id);
          }
          sendResponse({ ok: true, result: { invalidated: true } });
          break;
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
        case "nativeagent.page.drag":
          sendResponse({ ok: true, result: dragNode(message) });
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
    const identityByNodeId = new Map();
    const navigationProofs = new Map();
    const selectProofs = new Map();
    const nodeIdByElement = new Map();
    const nodes = [];
    const truncationReasons = [];
    const walk = composedElementWalk(document.body);
    pruneObservedShadowRoots();
    observeShadowRoots(walk.shadowRoots);
    const candidates = walk.elements;
    const modals = candidates.filter((element) => isVisible(element) && isModal(element));
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
      // Layout wrappers repeat the entire feed at every nesting level. Keep
      // semantic containers and controls, and preserve direct/leaf text instead.
      if (isRedundantLayoutWrapper(element, kind)) continue;
      if (!name && !text && kind === "other") continue;
      const selectInfo = element.tagName.toLowerCase() === "select" ? selectDescription(element) : null;
      const nodeTextCost = text.length + name.length + (selectInfo ? JSON.stringify(selectInfo).length : 0);
      if (aggregateNodeText + nodeTextCost > MAX_AGGREGATE_NODE_TEXT) {
        truncationReasons.push("encoded_size_limit");
        break;
      }
      aggregateNodeText += nodeTextCost;

      const nodeId = `n${nodes.length + 1}`;
      nodeIdByElement.set(element, nodeId);
      elementByNodeId.set(nodeId, element);
      // 2026-09-06: what this id claimed to be, so an action can refuse a node
      // that is now something else. A shadow-root swap keeps the same element
      // object and connection while the label and role move on.
      identityByNodeId.set(nodeId, nodeIdentity(element, name));
      if (selectInfo) selectProofs.set(nodeId, JSON.stringify(selectInfo));
      const navigationProof = captureNavigationProof(element);
      if (navigationProof) navigationProofs.set(nodeId, navigationProof);
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
      if (element.draggable === true) actions.push("drag");
      if (!isPasswordField(element) && !isEditable(element)) actions.push("drop");

      if (isPasswordField(element)) actions.length = 0;
      const blockedByModal = modals.length > 0
        && (modals.length !== 1 || !withinElement(element, modals[0]));
      if (blockedByModal) actions.length = 0;

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
        ...(selectInfo ? { select: selectInfo } : {}),
        ...(!isPasswordField(element) && element.validity ? {
          formState: {
            required: element.required === true,
            readOnly: element.readOnly === true,
            valid: element.validity.valid === true,
            failures: ["valueMissing", "typeMismatch", "patternMismatch", "tooLong", "tooShort", "rangeUnderflow", "rangeOverflow", "stepMismatch", "badInput", "customError"]
              .filter((key) => element.validity[key] === true),
          },
        } : {}),
        level: headingLevel(element),
        visible: true,
        states: {
          disabled: isEffectivelyDisabled(element),
          checked: ariaBoolean(element, "aria-checked", "checked"),
          selected: ariaBoolean(element, "aria-selected", "selected"),
          expanded: nullableAriaBoolean(element.getAttribute("aria-expanded")),
          editable: isEditable(element),
          blockedByModal,
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
    snapshots.set(snapshotId, {
      leaseId: message.leaseId, domGeneration, elementByNodeId, actionNodeIds, identityByNodeId,
      navigationProofs, selectProofs, capturedAt: Date.now(), pageURL: location.href,
    });
    return snapshot;
  }

  function clickNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "click");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    // 2026-09-06: clicking a disabled control is a no-op the page never sees,
    // and it used to come back as clicked: true — a refusal reported as done.
    requireEnabledNode(element, "click");
    element.click();
    return { snapshotId: message.snapshotId, nodeId: message.nodeId, clicked: true };
  }

  function fillNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "fill");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    // 2026-09-06: a mutation is refused by a disabled control the same way a
    // click is. Only `clickNode`/`keypressNode` asked, so a fill into a control
    // inside a `<fieldset disabled>` came back reported as done.
    requireEnabledNode(element, "fill");
    focusWithoutActivation(element);
    const contentEditable = element.isContentEditable;
    try {
      replaceEditableValue(element, message.value);
      dispatchEditableEvent(element, "input", message.value);
      dispatchEditableEvent(element, "change", message.value);
      const observed = String((contentEditable ? element.textContent : element.value) ?? "");
      if (!element.isConnected || observed !== message.value) throw new Error("fill_readback_mismatch");
    } catch {
      throw pageError("action_outcome_unknown", "Fill was dispatched but its immediate value could not be confirmed. Observe before retrying; do not blindly repeat the fill.");
    }
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      filled: true,
      valueLength: message.value.length,
    };
  }

  async function typeIntoNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "type");
    // 2026-09-06: see fillNode — inherited disabled state is a refusal here too.
    requireEnabledNode(element, "type");
    const snapshot = requireSnapshot(message.snapshotId);
    const identity = editableIdentity(element);
    const parent = composedParent(element);
    const characters = Array.from(message.text);
    const startedAt = performance.now();
    const leaseExpiresAt = message.leaseExpiresAtMs;
    const run = { leaseId: snapshot.leaseId, stopReason: null };
    let typedCount = 0;
    let nextUTF16Offset = 0;
    let appendInFlight = false;
    const valueBefore = readEditableValue(element);
    function currentStopReason() {
      if (run.stopReason) return run.stopReason;
      if (!Number.isFinite(leaseExpiresAt) || message.leaseId !== snapshot.leaseId) return "lease_unavailable";
      if (Date.now() >= leaseExpiresAt) return "lease_expired";
      if (performance.now() - startedAt >= MAX_TYPING_DURATION_MS) return "execution_deadline";
      if (!element.isConnected) return "target_detached";
      if (composedParent(element) !== parent || editableIdentity(element) !== identity) return "target_changed";
      if (!isEditable(element)) return "target_not_editable";
      if (!isVisible(element)) return "target_not_visible";
      return null;
    }
    typingRuns.add(run);
    try {
      run.stopReason = currentStopReason();
      if (!run.stopReason && characters.length > 0) focusWithoutActivation(element);
      for (const character of characters) {
        run.stopReason = currentStopReason();
        if (run.stopReason) break;
        appendInFlight = true;
        appendEditableValue(element, character);
        typedCount += 1;
        nextUTF16Offset += character.length;
        appendInFlight = false;
        dispatchEditableEvent(element, "input", character);
        if (typedCount < characters.length && (message.delayMs > 0 || typedCount % TYPE_YIELD_EVERY === 0)) {
          const remaining = Math.min(
            MAX_TYPING_DURATION_MS - (performance.now() - startedAt),
            leaseExpiresAt - Date.now(),
          );
          await delay(Math.max(0, Math.min(message.delayMs ?? 0, remaining)));
        }
      }
      run.stopReason = currentStopReason();
      if (typedCount > 0 && !run.stopReason) dispatchEditableEvent(element, "change", null);
    } catch (error) {
      if (appendInFlight) {
        throw pageError("action_outcome_unknown", "The editable value setter failed after dispatch; observe before retrying.");
      }
      if (typedCount === 0) throw error;
      run.stopReason = "page_event_failed";
    } finally {
      typingRuns.delete(run);
    }
    // 2026-09-06: read the field back rather than trusting the loop's count.
    // A sanitising input (number, date, time, week, month) or a page that
    // reformats on input can keep less — or something other — than what was
    // appended, and reporting the attempt as the outcome sent the caller on
    // with a field it believes it filled. A mismatch is a partial result.
    let valueAfter = null;
    let enteredText = null;
    let valueRetained = true;
    // 2026-09-06: what was ENTERED is the difference between the readback and
    // the value the field held before the loop. When the old value is not a
    // prefix of the new one the page rewrote what was already there — a date
    // input reformatting "12/2026" into "05/2026" — and reporting the whole
    // readback as entered counted pre-existing, reformatted content as typed
    // text, which the caller then read as a partial success. That case is now
    // its own outcome, carrying both values, and nothing is claimed as typed.
    let valueRewritten = false;
    try {
      valueAfter = readEditableValue(element);
      valueRewritten = !valueAfter.startsWith(valueBefore);
      enteredText = valueRewritten ? null : valueAfter.slice(valueBefore.length);
      valueRetained = valueAfter === valueBefore + characters.slice(0, typedCount).join("");
      // Same policy as `safeValue`: never echo a secret back, even though the
      // type action is only ever advertised on non-password editables.
      if (isPasswordField(element)) {
        enteredText = null;
        valueAfter = null;
      }
    } catch {
      valueRetained = false;
    }
    if (!valueRetained && run.stopReason === null) {
      run.stopReason = valueRewritten ? "value_rewritten" : "value_not_retained";
    }
    const completed = typedCount === characters.length && valueRetained
      && !valueRewritten && run.stopReason === null;
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      typed: completed,
      completed,
      characterCount: typedCount,
      requestedCharacterCount: characters.length,
      remainingCharacterCount: characters.length - typedCount,
      characterUnit: "unicode_code_point",
      nextCharacterIndex: typedCount,
      nextUTF16Offset,
      valueRetained,
      valueRewritten,
      // Only on a rewrite, and only where echoing is allowed: the caller needs
      // to see what the field turned its text into to decide what to do next.
      valueBefore: valueRewritten && valueAfter !== null ? bounded(valueBefore, 500) : null,
      valueAfter: valueRewritten && valueAfter !== null ? bounded(valueAfter, 500) : null,
      enteredText: enteredText === null ? null : bounded(enteredText, 500),
      // A rewrite entered nothing the caller asked for. Reporting 0 rather than
      // null matters: null means "this page agent predates the readback" and
      // sends the app back to the attempted count.
      enteredCharacterCount: valueRewritten
        ? 0
        : enteredText === null ? null : Array.from(enteredText).length,
      elapsedMs: Math.max(0, Math.round(performance.now() - startedAt)),
      stopReason: completed ? null : run.stopReason,
    };
  }

  function editableIdentity(element) {
    return JSON.stringify([
      element.tagName, element.type ?? "", Boolean(element.isContentEditable),
      ...["id", "name", "role", "aria-label", "aria-labelledby"].map((name) => element.getAttribute(name)),
    ]);
  }

  function selectNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "select");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    // 2026-09-06: see fillNode — inherited disabled state is a refusal here too.
    requireEnabledNode(element, "select");
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
    const description = selectDescription(element);
    if (requireSnapshot(message.snapshotId).selectProofs.get(message.nodeId) !== JSON.stringify(description)) {
      throw pageError("node_stale", "The select choices changed. Read a fresh snapshot before selecting.");
    }
    for (const value of requested) {
      const matches = description.options.filter((option) => option.value === value);
      if (!matches.length) throw pageError("option_not_observed", "The requested value was outside the bounded observed choices.");
      if (matches.some((option) => option.disabled)) throw pageError("option_disabled", "The requested choice is disabled, including its option group.");
    }
    let values;
    try {
      for (const option of options) option.selected = requested.has(String(option.value));
      dispatchEditableEvent(element, "input", null);
      dispatchEditableEvent(element, "change", null);
      // Event handlers may replace the options collection, not only change
      // the originally observed option objects.
      values = Array.from(element.options ?? [])
        .filter((option) => option.selected).map((option) => String(option.value));
      const observed = new Set(values);
      if (!element.isConnected || observed.size !== requested.size
        || [...requested].some((value) => !observed.has(value))) throw new Error("selection_readback_mismatch");
    } catch {
      throw pageError("action_outcome_unknown", "Selection was dispatched but its immediate state could not be confirmed. Observe before retrying; do not blindly repeat the selection.");
    }
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      selected: true,
      values,
    };
  }

  function keypressNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "keypress");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    // 2026-09-06: a keypress is an activation route too — Enter clicks a button
    // or submits a form, Space clicks a checkable. A disabled control receives
    // no key events in a browser, so dispatching them here manufactured an
    // effect the page would never have produced.
    requireEnabledNode(element, "keypress");
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
    // 2026-09-06: see fillNode — inherited disabled state is a refusal here too.
    requireEnabledNode(element, "set_checked");
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
    requireEnabledNode(element, "double click");
    element.click();
    element.click();
    if (typeof MouseEvent === "function") {
      element.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, composed: true, detail: 2, button: 0 }));
    }
    return { snapshotId: message.snapshotId, nodeId: message.nodeId, doubleClicked: true };
  }

  async function waitForNodeState(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "wait");
    const snapshot = requireSnapshot(message.snapshotId);
    const deadline = performance.now() + message.timeoutMs;
    const run = { leaseId: snapshot.leaseId, stopReason: null };
    waitingRuns.add(run);
    try {
      while (true) {
        if (!run.stopReason && (!Number.isFinite(message.leaseExpiresAtMs) || message.leaseId !== snapshot.leaseId)) {
          run.stopReason = "lease_unavailable";
        }
        if (!run.stopReason && Date.now() >= message.leaseExpiresAtMs) run.stopReason = "lease_expired";
        if (run.stopReason) throw pageError(run.stopReason, `The node wait stopped: ${run.stopReason}.`);
        const matched = nodeMatchesState(element, message.state);
        if (matched || performance.now() >= deadline) {
          return {
            snapshotId: message.snapshotId,
            nodeId: message.nodeId,
            state: message.state,
            matched,
          };
        }
        await delay(Math.min(50, Math.max(1, deadline - performance.now())));
      }
    } finally {
      waitingRuns.delete(run);
    }
  }

  function dragNode(message) {
    const source = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "drag");
    const target = requireActionableSnapshotNode(message.snapshotId, message.targetNodeId, "drop");
    if (source === target) throw pageError("invalid_drag_target", "Drag requires two different observed nodes.");
    if (typeof DataTransfer !== "function" || typeof DragEvent !== "function") {
      throw pageError("drag_unavailable", "This page cannot construct HTML drag events.");
    }
    const sourceParent = composedParent(source), targetParent = composedParent(target);
    const check = () => {
      requireActionableSnapshotNode(message.snapshotId, message.nodeId, "drag");
      requireActionableSnapshotNode(message.snapshotId, message.targetNodeId, "drop");
      if (!source.draggable || !isVisible(source) || !isVisible(target)
        || composedParent(source) !== sourceParent || composedParent(target) !== targetParent) {
        throw pageError("node_stale", "A drag endpoint changed.");
      }
      requireEnabledNode(source, "drag"); requireEnabledNode(target, "drop");
      if (composedElementWalk(document.body).elements.some((element) => isVisible(element) && isModal(element)
        && (!withinElement(source, element) || !withinElement(target, element)))) {
        throw pageError("modal_target_required", "Both drag endpoints must remain inside the modal.");
      }
    };
    check();
    const dataTransfer = new DataTransfer();
    dataTransfer.effectAllowed = "all";
    const emit = (element, type, cancelable = true) => element.dispatchEvent(new DragEvent(type, {
      bubbles: true, cancelable, dataTransfer,
    }));
    let started = false, dropDispatched = false, dropAcknowledged = false, reason = null;
    try {
      started = true;
      if (!emit(source, "dragstart")) reason = "dragstart_cancelled";
      else {
        const allowed = dataTransfer.effectAllowed.toLowerCase();
        dataTransfer.dropEffect = ["all", "uninitialized"].includes(allowed) || allowed.includes("move") ? "move"
          : allowed.includes("copy") ? "copy" : allowed.includes("link") ? "link" : "none";
        check(); emit(target, "dragenter");
        check();
        const accepts = !emit(target, "dragover");
        const effect = dataTransfer.dropEffect;
        if (!accepts || effect === "none" || !(allowed === "all" || allowed === "uninitialized" || allowed.includes(effect))) reason = "target_did_not_accept";
        else {
          check();
          // A dragover acceptance only permits delivery. Observe the drop's
          // own handler/effect before claiming that the page acknowledged it.
          const observer = new MutationObserver(() => {});
          observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
          try {
            dropAcknowledged = !emit(target, "drop");
            dropDispatched = true;
            dropAcknowledged ||= observer.takeRecords().length > 0;
          } finally { observer.disconnect(); }
          if (!dropAcknowledged) reason = "dispatched_unconfirmed";
        }
        if (!dropDispatched && target.isConnected) emit(target, "dragleave", false);
      }
      emit(source, "dragend", false);
    } catch {
      if (started) {
        try { emit(source, "dragend", false); } catch {}
        throw pageError("action_outcome_unknown", "Drag events were dispatched but the sequence could not be confirmed. Observe before retrying.");
      }
      throw pageError("drag_unavailable", "The drag could not start.");
    }
    return { snapshotId: message.snapshotId, nodeId: message.nodeId, targetNodeId: message.targetNodeId,
      dropDispatched, dropAcknowledged, reason, inputMechanism: "synthetic_html_drag", verificationRequired: "fresh_snapshot" };
  }

  function scrollPage(message) {
    let target = window;
    if (!message.targetNodeId && composedElementWalk(document.body).elements.some((element) => isVisible(element) && isModal(element))) {
      throw pageError("modal_target_required", "A modal is open; use a fresh scrollable node inside it rather than scrolling the page behind it.");
    }
    if (message.targetNodeId) {
      // 2026-09-06: a targeted scroll used to take the raw snapshot node,
      // skipping both the advertised-action check and the identity re-check
      // every other act goes through — so it could scroll a container the
      // caller never saw. `scroll` is an advertised action; go through the
      // same door.
      target = requireActionableSnapshotNode(message.snapshotId, message.targetNodeId, "scroll");
    }
    const position = () => ({
      x: finite(target === window ? window.scrollX : target.scrollLeft),
      y: finite(target === window ? window.scrollY : target.scrollTop),
    });
    const before = position();
    // `auto` inherits CSS smooth scrolling, so its immediate readback can
    // precede the movement. Explicit instant scrolling also works in inactive
    // tabs without waiting on a throttled animation frame.
    target.scrollBy({ left: message.deltaX, top: message.deltaY, behavior: "instant" });
    const after = position();
    const extent = target === window ? (document.scrollingElement ?? document.documentElement) : target;
    const viewportHeight = target === window ? window.innerHeight : target.clientHeight;
    const maximumY = Math.max(0, finite(extent?.scrollHeight) - finite(viewportHeight));
    const movedX = after.x - before.x;
    const movedY = after.y - before.y;
    let scrollNotification = "browser_managed";
    if ((movedX !== 0 || movedY !== 0) && document.visibilityState === "hidden") {
      // Chrome can defer native scroll events with hidden-page rendering even
      // though layout offsets already changed. Notify ordinary page listeners
      // without activating the tab or manufacturing trusted user input. A later
      // native event is still Chrome's to deliver; never intercept it.
      const eventTarget = target === window ? document : target;
      eventTarget.dispatchEvent(new Event("scroll", { bubbles: target === window }));
      scrollNotification = "supplemental_untrusted_hidden";
    }
    return {
      snapshotId: message.snapshotId ?? null,
      targetNodeId: message.targetNodeId ?? null,
      scrolled: movedX !== 0 || movedY !== 0,
      coordinateScope: target === window ? "window" : "element",
      scrollX: after.x,
      scrollY: after.y,
      movedX,
      movedY,
      scrollNotification,
      remainingUp: Math.max(0, after.y),
      remainingDown: Math.max(0, maximumY - after.y),
      atTop: after.y <= 1,
      atBottom: after.y >= maximumY - 1,
      observationScope: "immediate_position_not_feed_completion",
    };
  }

  function requireSnapshotNode(snapshotId, nodeId) {
    const snapshot = requireSnapshot(snapshotId);
    const element = snapshot.elementByNodeId.get(nodeId);
    if (!element?.isConnected) throw pageError("node_stale", "The snapshot node is no longer attached.");
    return element;
  }

  function nodeIdentity(element, name) {
    const role = element.getAttribute("role") ?? implicitRole(element);
    return `${element.tagName.toLowerCase()}\u0000${role}\u0000${name}`;
  }

  function currentNodeIdentity(element) {
    const text = bounded(normalizedText(element.innerText ?? element.textContent ?? ""), 1_000);
    return nodeIdentity(element, bounded(accessibleName(element, text), 500));
  }

  function requireActionableSnapshotNode(snapshotId, nodeId, action) {
    // A changing feed does not make an unchanged navigation landmark unusable.
    // This narrow exception permits click only, never edits or feed actions.
    const retained = snapshots.get(snapshotId);
    const proof = action === "click" ? retained?.navigationProofs.get(nodeId) : null;
    const allowNavigation = proof && navigationProofMatches(proof, retained);
    const snapshot = allowNavigation ? retained : requireSnapshot(snapshotId);
    if (!snapshot.actionNodeIds.get(action)?.has(nodeId)) {
      throw pageError("node_not_actionable", `The snapshot node did not advertise a ${action} action.`);
    }
    const element = snapshot.elementByNodeId.get(nodeId);
    if (!element?.isConnected) throw pageError("node_stale", "The snapshot node is no longer attached.");
    if (snapshot.domGeneration !== domGeneration) {
      const walk = composedElementWalk(document.body);
      if (walk.truncated || walk.elements.some((candidate) => isVisible(candidate) && isModal(candidate))) {
        throw pageError("snapshot_stale", "Refresh the page before acting across a modal or incomplete page boundary.");
      }
    }
    // 2026-09-06: membership and connection are not identity. Inside an open
    // shadow root a component can relabel the very element this id names
    // without the document observer ever firing, so the act would land on a
    // control the caller never saw.
    const expected = snapshot.identityByNodeId?.get(nodeId);
    if (expected !== undefined && currentNodeIdentity(element) !== expected) {
      throw pageError("node_identity_changed", "The snapshot node is no longer the control it described.");
    }
    return element;
  }

  function captureNavigationProof(element) {
    if (element.tagName.toLowerCase() !== "a" || element.getAttribute("download") !== null
      || (element.getAttribute("target") && element.getAttribute("target") !== "_self")) return null;
    let url;
    try { url = new URL(element.href); } catch { return null; }
    if (!/^https?:$/.test(url.protocol) || url.origin !== new URL(location.href).origin) return null;
    const ancestors = [];
    let scope = null;
    for (let parent = composedParent(element); parent; parent = composedParent(parent)) {
      ancestors.push(parent);
      if (!scope && (parent.tagName?.toLowerCase() === "nav" || parent.getAttribute?.("role") === "navigation")) scope = parent;
    }
    if (!scope) return null;
    return { element, scope, ancestors, href: element.href, identity: currentNodeIdentity(element) };
  }

  function navigationProofMatches(proof, snapshot) {
    if (Date.now() - snapshot.capturedAt > 60_000 || snapshot.pageURL !== location.href
      || !proof.element.isConnected) return false;
    const current = captureNavigationProof(proof.element);
    return current && current.href === proof.href && current.identity === proof.identity
      && current.scope === proof.scope && current.ancestors.length === proof.ancestors.length
      && current.ancestors.every((element, index) => element === proof.ancestors[index]);
  }

  function requireEnabledNode(element, action) {
    if (isEffectivelyDisabled(element)) {
      throw pageError("node_disabled", `The snapshot node is disabled, so the ${action} would do nothing.`);
    }
  }

  function isEffectivelyDisabled(element) {
    // 2026-09-06: `element.disabled` reflects the node's OWN attribute only, so
    // a control inside a `<fieldset disabled>` read as enabled and the act was
    // dispatched into a page that never sees it. `:disabled` is the inherited
    // state the browser itself uses.
    let inheritedDisabled = false;
    try {
      inheritedDisabled = typeof element.matches === "function" && element.matches(":disabled");
    } catch {
      inheritedDisabled = false;
    }
    return inheritedDisabled || Boolean(element.disabled)
      || element.getAttribute("aria-disabled") === "true";
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
    if (tag === "article" || role === "article") return "article";
    if (tag === "table") return "table";
    if (tag === "tr") return "row";
    if (["td", "th"].includes(tag)) return "cell";
    if (tag === "dialog" || role === "dialog" || role === "alertdialog") return "dialog";
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
    const labelIds = element.getAttribute("aria-labelledby")?.trim().split(/\s+/).slice(0, 12) ?? [];
    const root = typeof element.getRootNode === "function" ? element.getRootNode() : document;
    const labelled = labelIds.map((id) => {
      const label = root.getElementById?.(id);
      return normalizedText(label?.innerText ?? label?.textContent ?? "");
    }).filter(Boolean).join(" ");
    if (labelled) return labelled;
    return element.getAttribute("aria-label")
      ?? element.getAttribute("alt")
      ?? element.getAttribute("title")
      ?? element.labels?.[0]?.innerText
      ?? fallback;
  }

  function isRedundantLayoutWrapper(element, kind) {
    if (kind !== "other" || element.getAttribute("role")
      || element.getAttribute("aria-label") || element.getAttribute("aria-labelledby")
      || isEditable(element) || isKeypressable(element, "") || isScrollable(element)
      || element.draggable === true
      || !(element.children?.length > 0)) return false;
    // Direct text mixed with controls is still content, not layout. Avoid a
    // textContent subtraction heuristic that can accidentally erase prose.
    return !Array.from(element.childNodes ?? []).some((node) =>
      node.nodeType === 3 && normalizedText(node.textContent ?? ""));
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

  function isModal(element) {
    if (element.tagName.toLowerCase() === "dialog") {
      try { return element.matches(":modal"); } catch { return false; }
    }
    return ["dialog", "alertdialog"].includes(element.getAttribute("role"))
      && element.getAttribute("aria-modal") === "true";
  }

  function withinElement(element, ancestor) {
    for (let node = element; node; node = composedParent(node)) if (node === ancestor) return true;
    return false;
  }

  function isClickable(element, role) {
    const tag = element.tagName.toLowerCase();
    return ["a", "button", "summary", "option"].includes(tag)
      || (tag === "input" && ["submit", "reset", "button", "image"].includes(element.type?.toLowerCase()))
      || ["button", "link", "menuitem", "tab", "checkbox", "radio"].includes(role)
      || typeof element.onclick === "function";
  }

  function isEditable(element) {
    if (isEffectivelyDisabled(element) || element.readOnly) return false;
    const tag = element.tagName.toLowerCase();
    if (tag === "textarea" || element.isContentEditable) return true;
    if (tag !== "input" || isPasswordField(element)) return false;
    const type = (element.type || "text").toLowerCase();
    return ["text", "search", "email", "url", "tel", "number", "date", "datetime-local", "month", "time", "week"].includes(type);
  }

  function isSelectable(element) {
    return element.tagName.toLowerCase() === "select" && !isEffectivelyDisabled(element);
  }

  function selectDescription(element) {
    const options = Array.from(element.options ?? []);
    return {
      multiple: element.multiple === true,
      optionCount: options.length,
      optionsTruncated: options.length > 100,
      options: options.slice(0, 100).map((option) => {
        const value = String(option.value);
        const group = option.parentElement?.tagName?.toLowerCase() === "optgroup" ? option.parentElement : null;
        return {
          value: value.length <= 1024 ? value : null,
          valueUnavailable: value.length > 1024,
          label: bounded(normalizedText(option.label ?? option.textContent ?? value), 500),
          selected: option.selected === true,
          disabled: option.disabled === true || group?.disabled === true,
          group: group ? bounded(String(group.label ?? ""), 500) : null,
        };
      }),
    };
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

  // 2026-09-06: what the field ACTUALLY holds. Typing counted the characters it
  // attempted, and the setter has no readback — so on an input the browser
  // sanitises (number, date, time, week, month) every appended character was
  // discarded while the result still said typed: true with the full count.
  function readEditableValue(element) {
    if (element.isContentEditable) return String(element.textContent ?? "");
    return String(element.value ?? "");
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
      // 2026-09-06: an unmodified Enter in a multi-line field is a newline, not
      // a submit. Dispatching requestSubmit for any element inside a form sent
      // half-written text the moment a newline was typed.
      else if (tag === "textarea" && !spec.ctrlKey && !spec.metaKey) insertIntoEditable(element, "\n");
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
      if (!isVisible(candidate) || isEffectivelyDisabled(candidate)) return false;
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

  function insertIntoEditable(element, text) {
    if (!isEditable(element) || !("value" in element)) return;
    const current = String(element.value ?? "");
    const hasSelection = typeof element.selectionStart === "number" && typeof element.selectionEnd === "number";
    const start = hasSelection ? element.selectionStart : current.length;
    const end = hasSelection ? element.selectionEnd : current.length;
    setNativeValue(element, `${current.slice(0, start)}${text}${current.slice(end)}`);
    if (hasSelection && typeof element.setSelectionRange === "function") {
      const caret = start + text.length;
      element.setSelectionRange(caret, caret);
    }
    dispatchEditableEvent(element, "input", text);
  }

  function deleteFromEditable(element, backward) {
    if (!isEditable(element) || !("value" in element) || typeof element.selectionStart !== "number" || typeof element.selectionEnd !== "number") return;
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
    if (!root) return { elements: [], truncated: false, shadowRoots: [] };
    const result = [];
    const shadowRoots = [];
    const stack = Array.from(root.children ?? []).reverse();
    while (stack.length > 0 && result.length < maximum) {
      const element = stack.pop();
      result.push(element);
      if (element.shadowRoot) shadowRoots.push(element.shadowRoot);
      const descendants = [
        ...Array.from(element.shadowRoot?.children ?? []),
        ...Array.from(element.children ?? []),
      ];
      for (let index = descendants.length - 1; index >= 0; index -= 1) stack.push(descendants[index]);
    }
    return { elements: result, truncated: stack.length > 0, shadowRoots };
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
      case "enabled": return element.isConnected && !isEffectivelyDisabled(element);
      case "disabled": return !element.isConnected || isEffectivelyDisabled(element);
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
