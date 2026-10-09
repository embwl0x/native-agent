(() => {
  // A repeated attach or concurrent manifest injection replaces the reader
  // coherently, including its observers, timers and trusted-input listeners.
  globalThis.__nativeAgentPageAgent?.();
  // Leave ten seconds of the host's thirty-second request deadline for the
  // content reply, extension receipt, and native-messaging transport.
  const MAX_TYPING_DURATION_MS = 20_000;
  const TYPE_YIELD_EVERY = 32;
  const snapshots = new Map();
  let scrollObservation = null;
  const documentIdentity = crypto.randomUUID();
  const elementIdentities = new WeakMap();
  const elementFragments = new WeakMap();
  const fragmentCounts = new Map();
  const allocatedFragments = new Set();
  let documentLinkTargets = new WeakMap();
  const typingRuns = new Set();
  const waitingRuns = new Set();
  const cancelledActions = new Set();
  let domGeneration = 0;
  // Coalesce mutation bursts in the page. This is a publication cadence, not
  // an action deadline: continuous changes still deliver one notice per turn.
  const CHANGE_DEBOUNCE_MS = 250;
  let observedTab = null;
  let changeTimer = null;
  const changeObserver = new MutationObserver(queuePageChange);
  const inputBindings = [];

  for (const kind of ["pointerdown", "keydown", "wheel", "touchstart"]) {
    const listener = (event) => {
      if (event.isTrusted !== true) return;
      stopChangeStream();
      snapshots.clear();
      scrollObservation = null;
      for (const run of typingRuns) run.stopReason = "user_takeover";
      for (const run of waitingRuns) run.stopReason = "user_takeover";
    };
    inputBindings.push([kind, listener]);
    window.addEventListener(kind, listener, { capture: true, passive: true });
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
      notifyHost({
        type: "nativeagent.page.mutated",
        snapshotIds: invalidatedSnapshotIds,
        retainedNavigationNodes,
      });
    }
  });
  domObserver.observe(document, MUTATION_SCOPE);

  function stopChangeStream() {
    observedTab = null;
    changeObserver.disconnect();
    clearTimeout(changeTimer);
    changeTimer = null;
  }

  function startChangeStream(message) {
    const newlyAttached = observedTab?.tabId !== message.tabId;
    observedTab = { tabId: message.tabId, userSequence: message.userSequence };
    changeObserver.disconnect();
    changeObserver.observe(document, MUTATION_SCOPE);
    for (const root of observedShadowRoots) {
      if (root.host?.isConnected === true) changeObserver.observe(root, MUTATION_SCOPE);
    }
    if (newlyAttached) queuePageChange();
  }

  function queuePageChange() {
    if (!observedTab || changeTimer !== null) return;
    changeTimer = setTimeout(() => {
      changeTimer = null;
      if (!observedTab) return;
      notifyHost({
        type: "nativeagent.page.changed",
        tabId: observedTab.tabId, userSequence: observedTab.userSequence,
      });
    }, CHANGE_DEBOUNCE_MS);
  }

  function observeShadowRoots(roots) {
    for (const root of roots) {
      if (!root || observedShadowRoots.has(root)) continue;
      observedShadowRoots.add(root);
      try {
        domObserver.observe(root, MUTATION_SCOPE);
        if (observedTab) changeObserver.observe(root, MUTATION_SCOPE);
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
    changeObserver.disconnect();
    if (observedTab) changeObserver.observe(document, MUTATION_SCOPE);
    for (const root of observedShadowRoots) {
      try {
        domObserver.observe(root, MUTATION_SCOPE);
        if (observedTab) changeObserver.observe(root, MUTATION_SCOPE);
      } catch {
        observedShadowRoots.delete(root);
      }
    }
  }

  const messageListener = (message, _sender, sendResponse) => {
    if (!message?.type?.startsWith("nativeagent.page.")) return false;
    try {
      switch (message.type) {
        case "nativeagent.page.observe":
          startChangeStream(message);
          sendResponse({ ok: true, result: { observing: observedTab !== null,
            ready: document.readyState !== "loading", url: location.href } });
          break;
        case "nativeagent.page.tab.invalidated":
          if (observedTab?.tabId === message.tabId) stopChangeStream();
          if (scrollObservation?.tabId === message.tabId) scrollObservation = null;
          for (const run of typingRuns) {
            if (run.tabId === message.tabId) run.stopReason = "tab_not_owned";
          }
          for (const run of waitingRuns) {
            if (run.tabId === message.tabId) run.stopReason = "tab_not_owned";
          }
          for (const [id, snapshot] of snapshots) {
            if (snapshot.tabId === message.tabId) snapshots.delete(id);
          }
          sendResponse({ ok: true, result: { invalidated: true } });
          break;
        case "nativeagent.page.action.cancel":
          cancelledActions.add(message.requestId);
          if (cancelledActions.size > 128) cancelledActions.delete(cancelledActions.values().next().value);
          for (const run of typingRuns) if (run.actionId === message.requestId) run.stopReason = "action_cancelled";
          for (const run of waitingRuns) if (run.actionId === message.requestId) run.stopReason = "action_cancelled";
          sendResponse({ ok: true, result: { cancelled: true } });
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
        case "nativeagent.page.history":
          // After the reply, so it is not lost to the page unloading.
          setTimeout(() => history.go(message.delta < 0 ? -1 : 1), 0);
          sendResponse({ ok: true, result: { length: history.length } });
          break;
        case "nativeagent.page.scroll":
          void scrollPage(message).then(
            (result) => sendResponse({ ok: true, result }),
            (error) => sendPageError(sendResponse, error),
          );
          return true;
        case "nativeagent.page.media":
          void controlMedia(message).then(
            (result) => sendResponse({ ok: true, result }),
            (error) => sendPageError(sendResponse, error),
          );
          return true;
        default:
          sendResponse({ ok: false, error: { code: "unknown_page_action", message: "Unknown page action." } });
      }
    } catch (error) {
      sendPageError(sendResponse, error);
    }
    return false;
  };
  chrome.runtime.onMessage.addListener(messageListener);
  const runtime = chrome.runtime;
  const teardown = () => {
    document.removeEventListener("DOMContentLoaded", announcePageReady);
    stopChangeStream();
    domObserver.disconnect();
    observedShadowRoots.clear();
    snapshots.clear();
    scrollObservation = null;
    for (const [kind, listener] of inputBindings) window.removeEventListener(kind, listener, { capture: true });
    for (const run of typingRuns) run.stopReason = "tab_not_owned";
    for (const run of waitingRuns) run.stopReason = "tab_not_owned";
    // An invalidated extension context has already lost its runtime listener.
    if (runtime.id) runtime.onMessage.removeListener(messageListener);
  };
  globalThis.__nativeAgentPageAgent = teardown;

  // A reloaded or updated extension orphans this copy: its runtime is gone and
  // every send throws "Extension context invalidated". Stop quietly instead.
  function notifyHost(message) {
    if (!chrome.runtime?.id) { teardown(); return; }
    try { void chrome.runtime.sendMessage(message).catch(() => {}); }
    catch { teardown(); }
  }

  // document_start installs the reader before the new page's headings exist.
  // Announce readiness from the document's own lifecycle, so navigation news
  // reads its content rather than an empty document still being parsed.
  function announcePageReady() {
    notifyHost({ type: "nativeagent.page.ready", url: location.href });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", announcePageReady, { once: true });
  else announcePageReady();

  function createSnapshot(message) {
    // Authored anchors and section labels are evidence of this capture only.
    documentLinkTargets = new WeakMap();
    const maxNodes = clampInteger(message.maxNodes, 1, 500, 120);
    const maxTextChars = clampInteger(message.maxTextChars, 1, 50_000, 12_000);
    const readingScope = message.scope ?? "page";
    if (!["page", "main_content"].includes(readingScope)) throw pageError("invalid_snapshot_scope", "Read the page or its semantic main content.");
    const snapshotId = crypto.randomUUID();
    const elementByNodeId = new Map();
    const actionNodeIds = new Map();
    const identityByNodeId = new Map();
    const navigationProofs = new Map();
    const selectProofs = new Map();
    const nodeIdByElement = new Map();
    const nodes = [];
    const truncationReasons = [];
    if (message.readCursor && (message.readCursor.frameURL ?? message.readCursor.url) !== location.href) throw pageError("page_changed", "This continuation belongs to another page. Read the current page again.");
    const viewportObservationId = message.readCursor?.viewportObservationId;
    const observation = viewportObservationId ? scrollObservation : null;
    if (viewportObservationId && (!observation || observation.id !== viewportObservationId
      || observation.tabId !== message.tabId || (observation.target !== window && !observation.target.isConnected))) {
      throw pageError("read_address_missing", "The scroll viewport is no longer available. Read the page again.");
    }
    const viewportRoot = observation?.target === window ? document.body : observation?.target;
    languageNavigationCache = new WeakMap();
    let walk = composedElementWalk(viewportRoot ?? document.body, 5_000, Boolean(observation), message.readCursor?.elementPath);
    const viewportChanged = observation ? viewportChange(observation.before, captureViewport(observation.target, walk)) : null;
    pruneObservedShadowRoots();
    observeShadowRoots(walk.shadowRoots);
    const modalSelector = "dialog, [role=dialog][aria-modal=true], [role=alertdialog][aria-modal=true]";
    const modalRoots = new Set([document, ...walk.shadowRoots]);
    let modals = [...new Set([...modalRoots].flatMap(root => [...root.querySelectorAll(modalSelector)]))]
      .filter((element) => isVisible(element) && isModal(element));
    const regionSelector = "main, article, [role=main], [role=article], [role=document], [itemprop~=articleBody]";
    const regions = [...document.querySelectorAll(regionSelector), ...walk.elements,
      ...walk.shadowRoots.flatMap(root => [...root.querySelectorAll(regionSelector)])];
    if (observation) for (let parent = composedParent(viewportRoot); parent; parent = composedParent(parent)) regions.push(parent);
    const mainRegions = [...new Set(regions)].filter((element) => isVisible(element)
      && (element.tagName?.toLowerCase() === "main" || element.getAttribute?.("role") === "main"));
    const articleRegions = [...new Set(regions)].filter((element) => isVisible(element)
      && element.matches("article, [role=article], [role=document], [itemprop~=articleBody]"));
    const bodies = articleRegions.filter(element => !articleRegions.some(other => other !== element && withinElement(element, other)));
    const contentRegions = mainRegions.length ? mainRegions : bodies;
    // Spend the walk budget inside semantic content, not the surrounding nav.
    // A single authored body leads the same main; repeated cards keep DOM order.
    if (readingScope === "main_content" && !observation) {
      const firstBody = bodies.length === 1 && (!mainRegions.length || mainRegions.some(main => withinElement(bodies[0], main))) ? bodies : [];
      const roots = [...new Set([...firstBody, ...contentRegions, ...modals])];
      walk = composedElementWalk(document.body, 5_000, false, message.readCursor?.elementPath, roots, true);
      observeShadowRoots(walk.shadowRoots);
      for (const root of walk.shadowRoots) modalRoots.add(root);
      modals = [...new Set([...modalRoots].flatMap(root => [...root.querySelectorAll(modalSelector)]))]
        .filter((element) => isVisible(element) && isModal(element));
    }
    if (message.readCursor?.elementPath && message.readCursor?.addressFragment) {
      const target = walk.elements.find(element => stableElementPath(element) === message.readCursor.elementPath);
      const expected = message.readCursor.addressFragment.replace(/^frame\/\d+\//, "");
      if (!target || readableElementFragment(target, message.readCursor.name || "") !== expected) {
        throw pageError("read_address_missing", "This reading place changed or disappeared. Read the current page again.");
      }
    }
    // Scope before spending the node/text budget. A long visible sidebar must
    // not consume all available evidence before the adjacent article. The
    // shadow walk cap, redaction, and modal action checks still apply. Scroll
    // readbacks use their observed viewport; ordinary reads retain DOM order.
    let candidates = readingScope === "page" ? walk.elements : walk.elements.filter((element) =>
      modals.some((modal) => withinElement(element, modal))
      || (contentRegions.some((region) => withinElement(element, region)) && !insideNavigation(element)));
    if (message.readCursor?.elementOnly === true) {
      const element = walk.elements.find(element => stableElementPath(element) === message.readCursor.elementPath);
      if (!element || element.tagName.toLowerCase() !== "select") throw pageError("invalid_read_cursor", "The folded select control is no longer present.");
      candidates = [element];
    }
    const glyphCounts = fragmentedTextGlyphCounts(candidates);
    const collapsedText = new Set();
    let nextRead = null;
    let aggregateNodeText = 0;
    // 2026-09-23: node text honors max_text_chars too; only the summary was
    // bounded, so a 1k-char ask still shipped up to 200k chars of nodes.
    // The caller can enlarge both budgets. Oversized controls fold their own
    // content instead of becoming an impassable page continuation.
    const nodeByteBudget = Math.max(12_000, maxTextChars);
    const utf8 = new TextEncoder();
    let aggregateNodeBytes = 0;
    let sectionName = bounded(walk.sectionName || document.title, 160);
    let sectionStart = null, paragraphStart = null, paragraph = null;
    const representedLinks = new Set();
    const checkpoint = (element) => ({ element, count: nodes.length, chars: aggregateNodeText,
      bytes: aggregateNodeBytes, sectionName,
      hasContent: nodes.some(node => !["heading", "landmark", "article"].includes(node.kind) && (node.text || node.name)) });
    const foldAtBoundary = () => {
      // Keep whole sections when they fit. A section larger than a window
      // advances by whole paragraphs; only a first oversized paragraph splits.
      const boundary = sectionStart?.hasContent ? sectionStart : paragraphStart?.count > 0 ? paragraphStart : null;
      if (!boundary) return false;
      for (const node of nodes.splice(boundary.count)) {
        const element = elementByNodeId.get(node.nodeId);
        nodeIdByElement.delete(element); elementByNodeId.delete(node.nodeId);
        identityByNodeId.delete(node.nodeId); navigationProofs.delete(node.nodeId); selectProofs.delete(node.nodeId);
        for (const ids of actionNodeIds.values()) ids.delete(node.nodeId);
      }
      aggregateNodeText = boundary.chars; aggregateNodeBytes = boundary.bytes;
      nextRead = { elementPath: stableElementPath(boundary.element), addressFragment: readableElementFragment(boundary.element, boundary.sectionName), textOffset: 0,
        name: boundary.sectionName };
      return true;
    };
    if (walk.truncated) truncationReasons.push("walk_limit");

    for (const element of candidates) {
      if (collapsedText.has(element)) {
        for (const child of element.children) collapsedText.add(child);
        continue;
      }
      if (!isPageContentElement(element) || !isVisible(element)) continue;
      const kind = elementKind(element);
      if (kind === "image" && !meaningfulImageName(element)) continue;
      if (kind === "link" && representedLinks.has(stableElementPath(element))) continue;
      const fragmented = element.children.length > 0 && glyphCounts.get(element) >= 2 && !element.closest("pre, code");
      const fullText = fragmented ? normalizedText(visibleFragmentedText(element)) : snapshotText(element);
      const textOffset = message.readCursor?.elementPath === stableElementPath(element) ? (message.readCursor.textOffset ?? 0) : 0;
      if (!Number.isSafeInteger(textOffset) || textOffset < 0 || textOffset > fullText.length) throw pageError("invalid_read_cursor", "The page text continuation is no longer present.");
      let text = fullText.slice(textOffset);
      let name = bounded(accessibleName(element, text), 500);
      // Layout wrappers repeat the entire feed at every nesting level. Keep
      // semantic containers and controls, and preserve direct/leaf text instead.
      if (!fragmented && !text && isRedundantLayoutWrapper(element, kind)) continue;
      if (fragmented) for (const child of element.children) collapsedText.add(child);
      if (fragmented && !text) continue;
      if (!name && !text && kind === "other") continue;
      const heading = sectionHeading(element);
      if (heading) { sectionName = bounded(heading, 160); sectionStart = checkpoint(element); }
      const block = readingBlock(element);
      if (block !== paragraph) { paragraph = block; paragraphStart = checkpoint(element); }
      if (nodes.length >= maxNodes) {
        truncationReasons.push("node_limit");
        if (!foldAtBoundary()) nextRead = { elementPath: stableElementPath(element), addressFragment: readableElementFragment(element, sectionName), textOffset: 0, name: sectionName };
        break;
      }
      const optionOffset = message.readCursor?.elementPath === stableElementPath(element) ? (message.readCursor.optionOffset ?? 0) : 0;
      let selectInfo = element.tagName.toLowerCase() === "select" ? selectDescription(element, optionOffset) : null;
      if (selectInfo) name = bounded(accessibleName(element, fullText), 500);
      let elementMore = null;
      if (selectInfo && (optionOffset || selectInfo.optionsTruncated
        || name.length + text.length + JSON.stringify(selectInfo).length > maxTextChars - aggregateNodeText
        || utf8.encode(name + text + JSON.stringify(selectInfo)).length > nodeByteBudget - aggregateNodeBytes)) {
        if (!Number.isSafeInteger(optionOffset) || optionOffset < 0 || optionOffset > selectInfo.optionCount) throw pageError("invalid_read_cursor", "The select option continuation is no longer present.");
        selectInfo.optionOffset = optionOffset;
        const room = maxTextChars - aggregateNodeText - name.length;
        const byteRoom = nodeByteBudget - aggregateNodeBytes - utf8.encode(name).length;
        const offered = selectInfo.options.length;
        let choices = JSON.stringify(selectInfo);
        while (selectInfo.options.length && (choices.length > room || utf8.encode(choices).length > byteRoom)) {
          selectInfo.options.pop();
          selectInfo.optionsTruncated = true;
          choices = JSON.stringify(selectInfo);
        }
        if (choices.length > room || utf8.encode(choices).length > byteRoom || (offered && !selectInfo.options.length)) {
          if (foldAtBoundary()) { truncationReasons.push("text_limit"); break; }
          nextRead = { elementPath: stableElementPath(element), addressFragment: readableElementFragment(element, sectionName), textOffset, optionOffset, ...(message.readCursor?.elementOnly ? { elementOnly: true } : {}), name: sectionName };
          if (!nodes.length) throw pageError("read_budget_too_small", "The read budget cannot hold this control's name and next choice. Increase max_text_chars.");
          truncationReasons.push("text_limit");
          break;
        }
        const textRoom = room - choices.length, textByteRoom = byteRoom - utf8.encode(choices).length;
        let end = 0, bytes = 0;
        for (const character of text) {
          const size = utf8.encode(character).length;
          if (end + character.length > textRoom || bytes + size > textByteRoom) break;
          end += character.length; bytes += size;
        }
        const nextOption = optionOffset + selectInfo.options.length;
        if (end < text.length || nextOption < selectInfo.optionCount) {
          if (!end && nextOption === optionOffset) {
            nextRead = { elementPath: stableElementPath(element), addressFragment: readableElementFragment(element, sectionName), textOffset, optionOffset, ...(message.readCursor?.elementOnly ? { elementOnly: true } : {}), name: sectionName };
            if (!nodes.length) throw pageError("read_budget_too_small", "The read budget cannot hold the next character. Increase max_text_chars.");
            truncationReasons.push("text_limit");
            break;
          }
          elementMore = { url: location.href, elementPath: stableElementPath(element), addressFragment: readableElementFragment(element, sectionName), elementOnly: true,
            textOffset: textOffset + end, optionOffset: nextOption, name: sectionName };
          text = text.slice(0, end);
        }
        if (!optionOffset && !elementMore) delete selectInfo.optionOffset;
      }
      let nodeTextCost = text.length + name.length + (selectInfo ? JSON.stringify(selectInfo).length : 0);
      const choiceText = selectInfo ? JSON.stringify(selectInfo) : "";
      const nameBytes = utf8.encode(name + choiceText).length;
      const textBytes = utf8.encode(text).length;
      if (aggregateNodeText + nodeTextCost > maxTextChars || aggregateNodeBytes + nameBytes + textBytes > nodeByteBudget) {
        truncationReasons.push("text_limit");
        if (foldAtBoundary()) break;
        const room = maxTextChars - aggregateNodeText - name.length - choiceText.length;
        const byteRoom = nodeByteBudget - aggregateNodeBytes - nameBytes;
        if (room <= 0 || byteRoom <= 0) {
          nextRead = { elementPath: stableElementPath(element), addressFragment: readableElementFragment(element, sectionName), textOffset, name: sectionName };
          if (!nodes.length) throw pageError("read_budget_too_small", "The read budget cannot hold this element's name and choices. Increase max_text_chars.");
          break;
        }
        let end = 0, bytes = 0;
        for (const character of text) {
          const size = utf8.encode(character).length;
          if (end + character.length > room || bytes + size > byteRoom) break;
          end += character.length; bytes += size;
        }
        if (!end && text.length) {
          nextRead = { elementPath: stableElementPath(element), addressFragment: readableElementFragment(element, sectionName), textOffset, name: sectionName };
          if (!nodes.length) throw pageError("read_budget_too_small", "The read budget cannot hold the next character. Increase max_text_chars.");
          break;
        }
        text = text.slice(0, end);
        nextRead = { elementPath: stableElementPath(element), addressFragment: readableElementFragment(element, sectionName), textOffset: textOffset + end, name: sectionName };
      } else {
        aggregateNodeText += nodeTextCost;
        aggregateNodeBytes += nameBytes + textBytes;
      }

      const nodeId = `n${nodes.length + 1}`;
      if (!elementIdentities.has(element)) elementIdentities.set(element, `${documentIdentity}:${crypto.randomUUID()}`);
      nodeIdByElement.set(element, nodeId);
      elementByNodeId.set(nodeId, element);
      // 2026-09-06: what this id claimed to be, so an action can refuse a node
      // that is now something else. A shadow-root swap keeps the same element
      // object and connection while the label and role move on.
      // Text compaction changes presentation, not the identity used by wait/drop.
      const identityName = bounded(accessibleName(element, snapshotText(element)), 500);
      identityByNodeId.set(nodeId, nodeIdentity(element, identityName));
      if (selectInfo) selectProofs.set(nodeId, {
        description: JSON.stringify(selectDescription(element, 0, Infinity)),
        observed: selectInfo.options,
      });
      const navigationProof = captureNavigationProof(element);
      if (navigationProof) navigationProofs.set(nodeId, navigationProof);
      const rect = element.getBoundingClientRect();
      const role = element.getAttribute("role") ?? implicitRole(element);
      const blockedByModal = modals.length > 0
        && (modals.length !== 1 || !withinElement(element, modals[0]));
      const actions = snapshotActions(element, role, blockedByModal);

      let parent = composedParent(element);
      while (parent && !nodeIdByElement.has(parent)) parent = composedParent(parent);
      nodes.push({
        nodeId,
        elementIdentity: elementIdentities.get(element),
        elementPath: stableElementPath(element),
        addressFragment: readableElementFragment(element, sectionName),
        parentNodeId: parent ? nodeIdByElement.get(parent) : null,
        kind,
        role,
        name,
        text,
        textOffset,
        sectionName,
        sectionPath: sectionStart ? stableElementPath(sectionStart.element) : null,
        paragraphPath: stableElementPath(paragraph),
        inlineText: fragmented ? [] : inlineTextWindow(element, textOffset, text.length),
        inline: ["inline", "inline-block", "contents"].includes(getComputedStyle(element).display),
        ...readingStructure(element),
        value: safeValue(element),
        ...(selectInfo ? { select: selectInfo } : {}),
        ...(elementMore ? { more: elementMore } : {}),
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
      // Earlier runs of an oversized paragraph are already read. Do not
      // replay their links as ordinary rows after its final text window.
      if (!fragmented) for (const part of inlineText(element)) if (part.elementPath) representedLinks.add(part.elementPath);
      for (const action of actions) {
        if (!actionNodeIds.has(action)) actionNodeIds.set(action, new Set());
        actionNodeIds.get(action).add(nodeId);
      }
      if (nextRead) break;
    }
    if (!message.readCursor?.elementOnly && !nextRead && walk.nextElement) {
      const nextSection = bounded(sectionHeading(walk.nextElement) || sectionName, 160);
      if (!foldAtBoundary()) nextRead = { elementPath: stableElementPath(walk.nextElement), addressFragment: readableElementFragment(walk.nextElement, nextSection), textOffset: 0, name: nextSection };
    }
    // A prose row and the links it names are one semantic unit. Retain their
    // action proofs together, even when the next ordinary row is folded.
    const inlinePaths = new Set(nodes.flatMap(node => node.inlineText ?? []).map(part => part.elementPath).filter(Boolean));
    const inlineSections = new Map(nodes.flatMap(node => (node.inlineText ?? [])
      .filter(part => part.elementPath).map(part => [part.elementPath, node.sectionName])));
    const inlineElements = new Set(candidates);
    for (const element of elementByNodeId.values()) for (const link of element.querySelectorAll("a")) inlineElements.add(link);
    for (const element of inlineElements) {
      if (nodeIdByElement.has(element) || !inlinePaths.has(stableElementPath(element))) continue;
      const nodeId = `n${nodes.length + 1}`, text = snapshotText(element), name = bounded(accessibleName(element, text), 500);
      // A proof is a row like any other: it spends the same node and text
      // budgets (its name is also its text), and running out is truncation.
      const proofBytes = 2 * utf8.encode(name).length;
      if (nodes.length >= maxNodes || aggregateNodeText + 2 * name.length > maxTextChars || aggregateNodeBytes + proofBytes > nodeByteBudget) {
        truncationReasons.push(nodes.length >= maxNodes ? "node_limit" : "text_limit");
        break;
      }
      aggregateNodeText += 2 * name.length;
      aggregateNodeBytes += proofBytes;
      if (!elementIdentities.has(element)) elementIdentities.set(element, `${documentIdentity}:${crypto.randomUUID()}`);
      nodeIdByElement.set(element, nodeId); elementByNodeId.set(nodeId, element);
      identityByNodeId.set(nodeId, nodeIdentity(element, name));
      const navigationProof = captureNavigationProof(element);
      if (navigationProof) navigationProofs.set(nodeId, navigationProof);
      const role = element.getAttribute("role") ?? implicitRole(element);
      const blockedByModal = modals.length > 0 && (modals.length !== 1 || !withinElement(element, modals[0]));
      const actions = snapshotActions(element, role, blockedByModal);
      const rect = element.getBoundingClientRect();
      nodes.push({ nodeId, elementIdentity: elementIdentities.get(element), elementPath: stableElementPath(element),
        addressFragment: readableElementFragment(element, inlineSections.get(stableElementPath(element)) ?? sectionName),
        sectionName: inlineSections.get(stableElementPath(element)) ?? sectionName,
        parentNodeId: null, kind: elementKind(element), role, name, text: name, inlineProof: true, value: null, actions, url: safeURL(element),
        ...readingStructure(element),
        states: { disabled: isEffectivelyDisabled(element), blockedByModal,
          checked: ariaBoolean(element, "aria-checked", "checked"), selected: ariaBoolean(element, "aria-selected", "selected"),
          expanded: nullableAriaBoolean(element.getAttribute("aria-expanded")), editable: isEditable(element) },
        level: headingLevel(element), visible: true, scrollable: actions.includes("scroll"), frameId: 0,
        bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } });
      for (const action of actions) {
        if (!actionNodeIds.has(action)) actionNodeIds.set(action, new Set());
        actionNodeIds.get(action).add(nodeId);
      }
    }

    // A body prefix keeps returning old feed items after scrolling and can
    // consume the budget before replies. Summarize the same viewport evidence
    // as the nodes. Keep container prose too: an article can have direct text
    // followed by buttons, without a separate text leaf for that prose.
    const rawSummary = nodes.length ? nodes.filter(node => !node.inlineProof)
      .map((node) => node.text || node.name).filter(Boolean).join("\n")
      : (!document.body?.children?.length ? normalizedText(document.body?.innerText ?? "") : "");
    const summaryText = bounded(rawSummary, maxTextChars);
    if (summaryText.length < rawSummary.length) truncationReasons.push("text_limit");
    const snapshot = {
      snapshotId,
      tabId: message.tabId,
      userSequence: message.userSequence,
      capturedAt: new Date().toISOString(),
      url: location.href,
      title: bounded(document.title ?? "", 1_024),
      ...(document.contentType === "application/pdf" || (!normalizedText(document.body?.innerText ?? "")
        && document.querySelector('embed[type="application/pdf"], object[type="application/pdf"]'))
        ? { document: { kind: "pdf", status: "unread" } } : {}),
      language: bounded(document.documentElement?.lang ?? navigator.language ?? "", 64),
      rendering: {
        visibility: ["visible", "hidden"].includes(document.visibilityState) ? document.visibilityState : "unknown",
        readyState: ["loading", "interactive", "complete"].includes(document.readyState) ? document.readyState : "unknown",
        scope: "rendered_dom_only",
      },
      reading: { scope: readingScope, mainContentAvailable: contentRegions.length > 0,
        sections: [...new Set(nodes.filter(node => !node.inlineProof).map(node => node.sectionName).filter(Boolean))],
        ...(observation ? { fromViewport: true, viewportChanged } : {}) },
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
      readMore: nextRead ? { url: location.href, ...nextRead, name: bounded(normalizedText(nextRead.name || nextRead.elementPath), 160) } : null,
      frame: {
        name: bounded(frameName(), 500),
        url: location.href,
      },
    };
    if (message.passive === true) {
      for (const [id, previous] of snapshots) {
        if (previous.passive === true) snapshots.delete(id);
      }
    } else snapshots.clear();
    snapshots.set(snapshotId, {
      tabId: message.tabId, domGeneration, elementByNodeId, actionNodeIds, identityByNodeId,
      navigationProofs, selectProofs, capturedAt: Date.now(), pageURL: location.href,
      passive: message.passive === true,
    });
    return snapshot;
  }

  function insideNavigation(element) {
    for (let current = element; current; current = composedParent(current)) {
      const tag = current.tagName?.toLowerCase();
      const role = current.getAttribute?.("role");
      if (["nav", "aside"].includes(tag) || ["navigation", "complementary"].includes(role)) return true;
      if (["ul", "ol"].includes(tag) || role === "list") {
        if (isLanguageNavigation(current)) return true;
      }
      const controlled = current.getAttribute?.("aria-controls")?.trim().split(/\s+/) ?? [];
      if (controlled.some(id => isLanguageNavigation(current.getRootNode().getElementById?.(id)))) return true;
      if (tag === "a" && current.hasAttribute("hreflang")) {
        const peers = [...(composedParent(current)?.children ?? [])];
        if (peers.every(peer => peer.matches("a[hreflang]")) && new Set(peers.map(peer => peer.hreflang)).size > 1) return true;
      }
    }
    return false;
  }

  // One answer per element per capture; lists are asked once per descendant.
  let languageNavigationCache = new WeakMap();
  function isLanguageNavigation(element) {
    if (!element) return false;
    if (languageNavigationCache.has(element)) return languageNavigationCache.get(element);
    let result = false;
    if (element.querySelector("a[hreflang]")) {
      const links = [...element.querySelectorAll("a[href]")];
      result = links.length > 0 && links.every(link => link.hasAttribute("hreflang"))
        && new Set(links.map(link => link.hreflang)).size > 1 && !hasUncontrolledWords(element);
    }
    languageNavigationCache.set(element, result);
    return result;
  }

  function snapshotActions(element, role, blockedByModal) {
    if (isPasswordField(element) || blockedByModal) return [];
    const actions = [];
    // A text field is clickable too: clicking or double-clicking it is normal.
    if (isClickable(element, role) || isEditable(element)) actions.push("click", "double_click");
    if (isEditable(element)) actions.push("fill", "type");
    if (isSelectable(element)) actions.push("select");
    if (isCheckable(element, role)) actions.push("set_checked");
    if (isKeypressable(element, role)) actions.push("keypress");
    actions.push("wait");
    if (isScrollable(element)) actions.push("scroll");
    if (element.draggable === true) actions.push("drag");
    if (!isEditable(element)) actions.push("drop");
    return actions;
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
    const run = { tabId: snapshot.tabId, actionId: message.actionId, stopReason: null };
    let typedCount = 0;
    let nextUTF16Offset = 0;
    let appendInFlight = false;
    const valueBefore = readEditableValue(element);
    function currentStopReason() {
      if (run.stopReason) return run.stopReason;
      if (cancelledActions.has(run.actionId)) return "action_cancelled";
      if (message.tabId !== snapshot.tabId) return "tab_not_owned";
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
          const remaining = MAX_TYPING_DURATION_MS - (performance.now() - startedAt);
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
      cancelledActions.delete(run.actionId);
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
    const description = selectDescription(element, 0, Infinity);
    const proof = requireSnapshot(message.snapshotId).selectProofs.get(message.nodeId);
    if (proof?.description !== JSON.stringify(description)) {
      throw pageError("node_stale", "The select choices changed. Read a fresh snapshot before selecting.");
    }
    for (const value of requested) {
      const matches = proof.observed.filter((option) => option.value === value);
      if (!matches.length) throw pageError("option_not_observed", "The requested value was outside the bounded observed choices.");
      if (description.options.some((option) => option.value === value && option.disabled)) throw pageError("option_disabled", "The requested choice is disabled, including its option group.");
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
    // 2026-09-24: a synthetic key never runs the browser's own default, so
    // page keys (PageDown, Space, arrows, Home/End outside a field) scroll
    // here and say how far; the host judges every other key by its effect.
    const moved = downAccepted ? applyKeyDefault(element, spec) : null;
    dispatchKeyboardEvent(element, "keyup", spec);
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      keypressed: true,
      key: message.key,
      defaultPrevented: !downAccepted,
      ...(moved ? moved : {}),
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
    const run = { tabId: snapshot.tabId, actionId: message.actionId, stopReason: null };
    waitingRuns.add(run);
    try {
      while (true) {
        if (cancelledActions.has(run.actionId)) run.stopReason = "action_cancelled";
        if (!run.stopReason && message.tabId !== snapshot.tabId) {
          run.stopReason = "tab_not_owned";
        }
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
      cancelledActions.delete(run.actionId);
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

  async function controlMedia(message) {
    if (cancelledActions.has(message.actionId)) throw pageError("action_cancelled", "Media control was cancelled before acting.");
    if (message.operation === "seek" && (!Number.isFinite(message.seconds) || message.seconds < 0)) throw pageError("invalid_payload", "Seek requires nonnegative seconds.");
    const elements = composedElementWalk(document.body, Number.MAX_SAFE_INTEGER).elements;
    const modals = elements.filter((element) => isVisible(element) && isModal(element));
    // The one admitted player. Other players, and buttons that merely look
    // like its controls, belong to the page; the click path reaches those.
    const media = elements.find((element) => element.matches("audio,video") && !isEffectivelyDisabled(element)
      && (modals.length === 0 || (modals.length === 1 && withinElement(element, modals[0]))));
    if (!media) throw pageError("media_unavailable", "No audio/video element is available in this page. Read the page to locate its player.");
    if (message.operation === "pause" && !media.paused) media.pause();
    const beforeTime = media.currentTime;
    let advancing = false, resumed = false;
    const state = (completed, reason = null) => ({ operation: message.operation, completed,
      paused: media.paused, currentTime: media.currentTime, beforeTime,
      currentTimeAdvancing: advancing, playbackStarted: message.operation === "play" && advancing, reason });
    // The player's own events prove the effect, not an arbitrary sleep.
    const events = ["play", "playing", "timeupdate", "pause", "ended", "error", "seeked"];
    return new Promise((resolve) => {
      let done = false, timer = null;
      const finish = (completed, reason) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        for (const event of events) media.removeEventListener(event, observe);
        waitingRuns.delete(run);
        resolve(state(completed, reason));
      };
      const observe = (event) => {
        if (message.operation === "pause") {
          advancing ||= media.currentTime !== beforeTime;
          resumed ||= !media.paused || ["play", "playing"].includes(event.type);
        } else if (message.operation === "seek") {
          if (event.type === "seeked") {
            const landed = Math.abs(media.currentTime - message.seconds) < 0.1;
            finish(landed, landed ? null : `The player settled at ${media.currentTime} seconds, not the requested position.`);
          } else if (event.type === "error") finish(false, "The player reported an error before confirming the seek.");
        } else if (event.type === "timeupdate" && !media.paused && media.currentTime > beforeTime) { advancing = true; finish(true); }
        else if (["pause", "ended", "error"].includes(event.type)) finish(false, "Playback did not advance before the player stopped.");
      };
      const run = { tabId: message.tabId, actionId: message.actionId,
        set stopReason(reason) { finish(false, reason); } };
      waitingRuns.add(run);
      for (const event of events) media.addEventListener(event, observe);
      if (message.operation === "pause") {
        // Pause must hold across a bounded observation window, including player-driven resumes.
        timer = setTimeout(() => {
          observe({ type: "observed" });
          const held = media.isConnected && media.paused && !advancing && !resumed;
          finish(held, held ? null : "Pause was not verified: playback resumed, the clock moved, or the page's media elements changed.");
        }, 1500);
        return;
      }
      // Buffering or a background tab can hold the clock still: answer before the control deadline.
      timer = setTimeout(() => finish(false, message.operation === "seek"
        ? "The player did not confirm the seek within 5 seconds."
        : `Playback did not advance within 5 seconds (paused: ${media.paused}).`), 5000);
      if (message.operation === "seek") media.currentTime = message.seconds;
      else void media.play().catch((error) => finish(false, `Playback was refused: ${error.message}`));
    });
  }

  async function scrollPage(message) {
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
    const observation = { id: crypto.randomUUID(), tabId: message.tabId, target, before: captureViewport(target) };
    scrollObservation = observation;
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
    // Yield to the browser's scroll handlers before readback. This task yield
    // is not a feed-completion deadline: later loads arrive through page news.
    const generation = domGeneration;
    if (movedX !== 0 || movedY !== 0) {
      await new Promise((resolve) => setTimeout(resolve, 0));
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
      contentChangedAfterScroll: domGeneration !== generation,
      readCursor: { url: location.href, viewportObservationId: observation.id },
    };
  }

  // Keep the before evidence locally, bound to this exact scroll and tab.
  // The comparison happens in the read itself, so a load between the action
  // reply and readback cannot be mistaken for an unchanged viewport.
  function captureViewport(target, walk = composedElementWalk(target === window ? document.body : target, 5_000, true)) {
    if (walk.truncated) return null;
    const rows = walk.elements.map(element => {
      const rect = element.getBoundingClientRect();
      const text = snapshotText(element);
      return { element, content: JSON.stringify([text, accessibleName(element, text), safeValue(element),
        element.getAttribute("role"), element.getAttribute("aria-expanded"), element.getAttribute("aria-checked"),
        element.getAttribute("aria-selected"), element.checked, element.selected, isEffectivelyDisabled(element),
        element.options ? Array.from(element.options, option => option.selected) : null,
        safeURL(element), rect.x, rect.y, rect.width, rect.height]) };
    });
    return { rows, x: target === window ? window.scrollX : target.scrollLeft,
      y: target === window ? window.scrollY : target.scrollTop };
  }

  function viewportChange(before, after) {
    if (!before || !after) return null;
    return before.x !== after.x || before.y !== after.y || before.rows.length !== after.rows.length
      || before.rows.some((item, index) => item.element !== after.rows[index].element || item.content !== after.rows[index].content);
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
    const text = snapshotText(element);
    return nodeIdentity(element, bounded(accessibleName(element, text), 500));
  }

  function snapshotText(element) {
    // Containers may span the whole retained feed even when only their bottom
    // intersects the viewport. Their descendants carry their own text; copying
    // innerText here would smuggle offscreen posts back into every new read.
    const kind = elementKind(element);
    if (!isPageContentElement(element) || kind === "image") return "";
    if (isPreformatted(element)) return element.innerText ?? element.textContent ?? "";
    if (element.tagName === "TIME") return normalizedText(element.innerText ?? element.textContent ?? "");
    const control = ["button", "link", "tab", "menuitem", "heading", "option", "select", "input"].includes(kind);
    const raw = !control && element.children?.length && element.childNodes
      ? inlineText(element).map((part) => part.text).join("")
      : (["button", "link", "tab", "menuitem", "heading"].includes(kind)
        ? visibleControlText(element) : (element.innerText ?? element.textContent ?? ""));
    return element.querySelector("code") && !element.closest("pre") ? raw : normalizedText(raw);
  }

  // DOM order is the reading order. Inline descendants contribute their text
  // where they occur; links also retain a structural address for their verb.
  function inlineText(element) {
    const parts = [];
    const preformatted = isPreformatted(element);
    function visit(parent, link = null, code = false) {
      for (const child of parent.childNodes ?? []) {
        if (child.nodeType === 3) parts.push({ text: child.textContent ?? "", ...(link ? { elementPath: stableElementPath(link), href: safeURL(link) } : {}), ...(code ? { code: true } : {}) });
        else if (child.nodeType === 1) {
          if (!isPageContentElement(child)) continue;
          if (elementKind(child) === "image") continue;
          if (insideNavigation(child) && !insideNavigation(element)) continue;
          if (child.tagName === "BR") { parts.push({ text: preformatted ? "\n" : " " }); continue; }
          const style = getComputedStyle(child);
          if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) continue;
          if (isTextClipped(child, style)) continue;
          if (preformatted || ["inline", "inline-block", "inline-flex", "contents"].includes(style.display)) visit(child, child.tagName === "A" ? child : link, code || child.tagName === "CODE");
        }
      }
    }
    visit(element, element.tagName === "A" ? element : null, element.tagName === "CODE");
    // Match snapshotText's whitespace normalization without losing run positions.
    let space = true;
    for (const part of parts) {
      if (preformatted) continue;
      if (!part.code) part.text = part.text.replace(/\s+/g, " ");
      if (space && !part.code) part.text = part.text.replace(/^ /, "");
      if (part.text) space = !part.code && part.text.endsWith(" ");
    }
    if (!preformatted && parts.length && !parts[parts.length - 1].code) parts[parts.length - 1].text = parts[parts.length - 1].text.replace(/ $/, "");
    const joined = [];
    for (const part of parts) {
      const previous = joined[joined.length - 1];
      if (previous && previous.elementPath === part.elementPath && previous.code === part.code) previous.text += part.text;
      else joined.push(part);
    }
    return joined;
  }

  function visibleControlText(element) {
    // Preserve the browser's rendered text (including CSS text transforms)
    // unless structure proves that it contains clipped or navigation copies.
    const navigational = insideNavigation(element);
    if (![...element.querySelectorAll("*")].some(child => isTextClipped(child)
      || Number(getComputedStyle(child).opacity) === 0 || (insideNavigation(child) && !navigational))) {
      return element.innerText ?? element.textContent ?? "";
    }
    return [...element.childNodes].map(child => {
      if (child.nodeType === 3) return child.textContent ?? "";
      if (child.nodeType !== 1 || !isPageContentElement(child) || elementKind(child) === "image") return "";
      const style = getComputedStyle(child);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0
        || isTextClipped(child, style) || (insideNavigation(child) && !insideNavigation(element))) return "";
      if (child.tagName === "BR") return "\n";
      const value = visibleControlText(child);
      return ["inline", "inline-block", "inline-flex", "contents"].includes(style.display) ? value : "\n" + value + "\n";
    }).join("");
  }

  function inlineTextWindow(element, offset, length) {
    let position = 0;
    return inlineText(element).flatMap(part => {
      const start = position; position += part.text.length;
      const text = part.text.slice(Math.max(0, offset - start), Math.max(0, Math.min(part.text.length, offset + length - start)));
      return text ? [{ ...part, text }] : [];
    });
  }

  function fragmentedTextGlyphCounts(elements) {
    // Work bottom-up within the existing bounded walk. Only plain inline
    // descendants qualify: never absorb controls, paragraph boundaries, shadow
    // content or offscreen prose. Visibility is applied when assembling text,
    // so transparent glyphs do not prevent their visible siblings collapsing.
    const counts = new Map();
    for (let index = elements.length - 1; index >= 0; index -= 1) {
      const element = elements[index];
      if (elementKind(element) !== "other" || element.getAttribute("role")
        || ["PRE", "CODE"].includes(element.tagName)
        || element.getAttribute("aria-label") || element.getAttribute("aria-labelledby")
        || element.shadowRoot || element.tagName.toLowerCase() === "slot" || !(element instanceof HTMLElement)
        || element.isContentEditable || isKeypressable(element, "")
        || isScrollable(element) || element.draggable === true) continue;
      const children = Array.from(element.children);
      if (children.some((child) => !counts.has(child)
        || !["inline", "inline-block"].includes(getComputedStyle(child).display))) continue;
      const fragments = Array.from(element.childNodes).filter((node) => node.nodeType === 3)
        .map((node) => normalizedText(node.textContent ?? "")).filter(Boolean);
      // 2026-09-28: longer direct text may sit between glyphs ("Read n·o·w
      // please"); only single-character fragments count toward the run.
      const glyphFragments = fragments.filter((text) => [...text].length === 1).length;
      const count = glyphFragments + children.reduce((sum, child) => sum + counts.get(child), 0);
      counts.set(element, count);
    }
    return counts;
  }

  function visibleFragmentedText(element) {
    const raw = Array.from(element.childNodes).map((node) => {
      if (node.nodeType === 3) return node.textContent ?? "";
      if (node.nodeType === 1 && node.tagName === "BR") return "\n";
      return node.nodeType === 1 ? visibleFragmentedText(node) : "";
    }).join("");
    // Keep whitespace-only spans, including those with no measurable box.
    // Normalize only after joining so spaces between visible glyphs survive.
    // A glyph must be seen AND on screen: a run crossing the viewport edge
    // keeps only what is in view, as each glyph row did before collapsing.
    return !normalizedText(raw) || isVisible(element) ? raw : "";
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
    const isTab = element.getAttribute("role") === "tab";
    if ((!isTab && element.tagName.toLowerCase() !== "a") || element.getAttribute("download") !== null
      || (element.getAttribute("target") && element.getAttribute("target") !== "_self")) return null;
    if (!isTab || element.href) {
      let url;
      try { url = new URL(element.href); } catch { return null; }
      if (!/^https?:$/.test(url.protocol) || url.origin !== new URL(location.href).origin) return null;
    }
    const ancestors = [];
    let scope = null;
    for (let parent = composedParent(element); parent; parent = composedParent(parent)) {
      ancestors.push(parent);
      if (!scope && (parent.tagName?.toLowerCase() === "nav" || parent.getAttribute?.("role") === "navigation"
        || (isTab && parent.getAttribute?.("role") === "tablist"))) scope = parent;
    }
    if (!scope) return null;
    return { element, scope, ancestors, href: element.href, identity: currentNodeIdentity(element),
      controls: element.getAttribute("aria-controls"), selected: element.getAttribute("aria-selected") };
  }

  function navigationProofMatches(proof, snapshot) {
    if (Date.now() - snapshot.capturedAt > 60_000 || snapshot.pageURL !== location.href
      || !proof.element.isConnected) return false;
    const current = captureNavigationProof(proof.element);
    return current && current.href === proof.href && current.identity === proof.identity
      && current.controls === proof.controls && current.selected === proof.selected
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
    if (tag === "img" || role === "img") return "image";
    if (["ul", "ol"].includes(tag)) return "list";
    if (tag === "li") return "listitem";
    if (tag === "article" || role === "article") return "article";
    if (tag === "table" || ["table", "grid", "treegrid"].includes(role)) return "table";
    if (tag === "tr" || role === "row") return "row";
    if (["td", "th"].includes(tag) || ["cell", "gridcell", "columnheader", "rowheader"].includes(role)) return "cell";
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
    if (elementKind(element) === "image") return meaningfulImageName(element);
    // datetime/title are metadata, not another rendering of the visible date.
    if (element.tagName === "TIME") return fallback;
    const name = elementAccessibleName(element, fallback);
    if (elementKind(element) !== "link" || normalizedText(fallback)
      || ((element.hasAttribute("aria-label") || element.hasAttribute("aria-labelledby")) && normalizedText(name))) return name;
    // An image link's action belongs to the image's own name/caption. Its
    // destination remains detail, never a replacement for that visible name.
    const images = [...element.querySelectorAll("img, [role=img]")].filter(isVisible);
    if (!images.length) return name;
    const imageNames = images.map(meaningfulImageName).filter(Boolean).join(" ");
    if (imageNames) return imageNames;
    const figure = element.closest("figure");
    const caption = figure?.querySelector("figcaption");
    return caption && isVisible(caption) ? normalizedText(caption.innerText ?? caption.textContent ?? "") : name;
  }

  function elementAccessibleName(element, fallback) {
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

  // HTML raw-text/inert elements are source, never rendered page prose. In
  // particular, noscript's textContent may be literal tracking-image markup.
  function isPageContentElement(element) {
    return !element.matches("script, style, template, noscript");
  }

  function meaningfulImageName(element) {
    for (let current = element; current; current = composedParent(current)) {
      if (!isPageContentElement(current) || current.hidden || current.getAttribute("aria-hidden") === "true") return "";
      const style = getComputedStyle(current);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return "";
    }
    const role = element.getAttribute("role");
    if (role === "presentation" || role === "none") return "";
    const rect = element.getBoundingClientRect();
    if (rect.width <= 1 && rect.height <= 1) return "";
    if (element.tagName === "IMG" && ((element.naturalWidth === 1 && element.naturalHeight === 1)
      || (element.getAttribute("width") === "1" && element.getAttribute("height") === "1"))) return "";
    // An explicitly empty alt is decorative unless ARIA supplies its name.
    const ariaNamed = element.hasAttribute("aria-label") || element.hasAttribute("aria-labelledby");
    if (!ariaNamed && !element.getAttribute("alt")) return "";
    // A failed image's browser replacement is not article content. An
    // authored caption is captured independently, including on its link.
    if (element.tagName === "IMG" && element.complete && element.naturalWidth === 0) return "";
    return normalizedText(elementAccessibleName(element, ""));
  }

  function sectionHeading(element) {
    const kind = elementKind(element);
    if (kind === "heading") return normalizedText(accessibleName(element, snapshotText(element)));
    return "";
  }

  function readingStructure(element) {
    const structure = {};
    if (isPreformatted(element)) structure.preformatted = true;
    if (element.tagName === "TIME") structure.time = true;
    if (elementKind(element) === "link") {
      const name = normalizedText(accessibleName(element, snapshotText(element)));
      const heading = element.querySelector("h1,h2,h3,h4,h5,h6,[role=heading]");
      structure.childTextName = name === normalizedText(visibleControlText(element))
        || (!!heading && name === normalizedText(accessibleName(heading, snapshotText(heading))));
      let previous = element.previousSibling, gap = "";
      while (previous && (previous.nodeType === 8 || (previous.nodeType === 3 && !normalizedText(previous.textContent ?? "")))) {
        if (previous.nodeType === 3) gap = previous.textContent + gap;
        previous = previous.previousSibling;
      }
      if (previous?.nodeType === 1 && elementKind(previous) === "link" && safeURL(element)
        && safeURL(previous) === safeURL(element)) {
        structure.adjacentLinkPath = stableElementPath(previous);
        structure.adjacentLinkGap = normalizedText(gap) || (gap ? " " : "");
      }
    }
    for (let parent = composedParent(element); parent; parent = composedParent(parent)) {
      const kind = elementKind(parent);
      if (!structure.textOwnerPath && (isPreformatted(parent) || parent.tagName === "TIME"
        || ["button", "tab", "menuitem"].includes(kind))) structure.textOwnerPath = stableElementPath(parent);
      if (!structure.contentLinkPath && kind === "link"
        && normalizedText(accessibleName(parent, snapshotText(parent))) === normalizedText(visibleControlText(parent))) {
        structure.contentLinkPath = stableElementPath(parent);
      }
      if (!structure.tableCellPath && kind === "cell") structure.tableCellPath = stableElementPath(parent);
      if (!structure.tableRowPath && kind === "row") structure.tableRowPath = stableElementPath(parent);
    }
    if (elementKind(element) === "cell") {
      structure.tableCellPath = stableElementPath(element);
      structure.columnSpan = element.colSpan || Number(element.getAttribute("aria-colspan")) || 1;
      structure.rowSpan = element.rowSpan || Number(element.getAttribute("aria-rowspan")) || 1;
    }
    if (elementKind(element) === "row") structure.tableRowPath = stableElementPath(element);
    // A sibling action drawn on the heading's line belongs to that heading,
    // rather than a content row. No control-label vocabulary is involved.
    for (let current = element; current && current !== document.body; current = composedParent(current)) {
      const previous = current.previousElementSibling;
      const headings = previous ? (elementKind(previous) === "heading" ? [previous]
        : [...previous.children].filter(child => elementKind(child) === "heading")) : [];
      if (headings.length !== 1) continue;
      const heading = headings[0], a = heading.getBoundingClientRect(), b = current.getBoundingClientRect();
      if (Math.min(a.bottom, b.bottom) <= Math.max(a.top, b.top)) continue;
      if (!isClickable(current, current.getAttribute("role") ?? implicitRole(current))
        && !current.querySelector("a,button,[role=link],[role=button]")) continue;
      if (hasUncontrolledWords(current)) continue;
      structure.sectionControlHeadingPath = stableElementPath(heading);
      break;
    }
    return structure;
  }

  function isPreformatted(element) {
    return element.tagName === "PRE" || (element.tagName === "CODE"
      && !["inline", "inline-block", "inline-flex", "contents"].includes(getComputedStyle(element).display));
  }

  function hasUncontrolledWords(element) {
    if (isClickable(element, element.getAttribute("role") ?? implicitRole(element))) return false;
    return [...element.childNodes].some(child => child.nodeType === 3 ? /[\p{L}\p{N}]/u.test(child.textContent ?? "")
      : child.nodeType === 1 && isPageContentElement(child) && isVisible(child) && hasUncontrolledWords(child));
  }

  function readingBlock(element) {
    for (let current = element; current; current = composedParent(current)) {
      if (!["inline", "inline-block", "inline-flex", "inline-grid", "contents"].includes(getComputedStyle(current).display)) return current;
    }
    return element;
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
    if (rect.width <= 0 || rect.height <= 0 || isTextClipped(element, style)) return false;
    for (let parent = composedParent(element); parent; parent = composedParent(parent)) {
      if (isTextClipped(parent)) return false;
    }
    return true;
  }

  function isTextClipped(element, style = getComputedStyle(element)) {
    const rectangle = style.clip?.match(/^rect\((.*)\)$/);
    if (rectangle) {
      const values = rectangle[1].split(/[\s,]+/).map(Number.parseFloat);
      if (values.length === 4 && (values[2] <= values[0] || values[1] <= values[3])) return true;
    }
    const inset = style.clipPath?.match(/^inset\(([^()]*)\)$/);
    if (!inset) return false;
    const parts = inset[1].split(/\s+round\s+/)[0].trim().split(/\s+/);
    if (parts.length < 1 || parts.length > 4 || parts.some(part => !/^\d+(?:\.\d+)?(?:px|%)?$/.test(part))) return false;
    const [top, right = top, bottom = top, left = right] = parts;
    const box = element.getBoundingClientRect();
    const amount = (part, length) => Number.parseFloat(part) * (part.endsWith("%") ? length / 100 : 1);
    return amount(top, box.height) + amount(bottom, box.height) >= box.height
      || amount(left, box.width) + amount(right, box.width) >= box.width;
  }

  function intersectsViewport(element) {
    const rect = element.getBoundingClientRect();
    let left = Math.max(0, rect.x), top = Math.max(0, rect.y);
    let right = Math.min(window.innerWidth, rect.x + rect.width), bottom = Math.min(window.innerHeight, rect.y + rect.height);
    // A child can intersect the window while lying outside its scrolled box.
    // Use the browser's actual clipping ancestors, including shadow hosts.
    for (let parent = composedParent(element); parent; parent = composedParent(parent)) {
      // The root and the element that scrolls the viewport clip at the window,
      // applied above; their boxes move with the document scroll, so applying
      // them again empties the region after one viewport. A body that scrolls
      // as its own container is a real clipping ancestor and stays.
      if (parent === document.documentElement || parent === document.scrollingElement) continue;
      const style = getComputedStyle(parent), box = parent.getBoundingClientRect();
      if (["auto", "scroll", "hidden", "clip"].includes(style.overflowX)) {
        left = Math.max(left, box.x + parent.clientLeft);
        right = Math.min(right, box.x + parent.clientLeft + parent.clientWidth);
      }
      if (["auto", "scroll", "hidden", "clip"].includes(style.overflowY)) {
        top = Math.max(top, box.y + parent.clientTop);
        bottom = Math.min(bottom, box.y + parent.clientTop + parent.clientHeight);
      }
    }
    return right > left && bottom > top;
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

  function selectDescription(element, offset = 0, limit = 100) {
    const options = Array.from(element.options ?? []);
    return {
      multiple: element.multiple === true,
      optionCount: options.length,
      optionsTruncated: offset > 0 || offset + limit < options.length,
      options: options.slice(offset, offset + limit).map((option) => {
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
    // Page keys scroll only outside anything that moves its own selection or
    // caret with them (fields, selects, list/combo boxes, sliders, menus).
    const ownsKeys = isEditable(element) || element.isContentEditable
      || ["input", "select", "textarea"].includes(element.tagName.toLowerCase())
      || ["listbox", "combobox", "menu", "menubar", "slider", "spinbutton", "radiogroup", "tree", "grid", "tablist", "option"]
        .includes(element.getAttribute("role") ?? implicitRole(element));
    if (!ownsKeys && ["PageDown", "PageUp", " ", "ArrowDown", "ArrowUp", "Home", "End"].includes(spec.key)) {
      return scrollForKey(element, spec);
    }
    if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(spec.key)) {
      moveEditableCaret(element, spec.key);
    }
  }

  // The nearest scrollable box around the element, else the page, moved the
  // way the key would move it natively.
  function scrollForKey(element, spec) {
    let box = element;
    while (box && box !== document.body && box !== document.documentElement && !isScrollable(box)) box = composedParent(box);
    const page = !box || box === document.body || box === document.documentElement;
    const scroller = page ? (document.scrollingElement ?? document.documentElement) : box;
    const view = page ? window.innerHeight : scroller.clientHeight;
    const beforeY = scroller.scrollTop;
    const step = { PageDown: view * 0.875, PageUp: -view * 0.875, " ": (spec.shiftKey ? -1 : 1) * view * 0.875, ArrowDown: 40, ArrowUp: -40 };
    if (spec.key === "Home") scroller.scrollTop = 0;
    else if (spec.key === "End") scroller.scrollTop = scroller.scrollHeight;
    else scroller.scrollTop = beforeY + Math.round(step[spec.key] ?? 0);
    const movedY = Math.round(scroller.scrollTop - beforeY);
    // A hidden tab defers native scroll events; tell the feed, as scrollPage does.
    if (movedY !== 0 && document.visibilityState === "hidden") {
      (page ? document : box).dispatchEvent(new Event("scroll", { bubbles: page }));
    }
    return { movedX: 0, movedY };
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

  function composedElementWalk(root, maximum = 5_000, viewportOnly = false, startPath = null, firstRoots = [], rootsOnly = false) {
    if (!root) return { elements: [], truncated: false, shadowRoots: [] };
    const result = [];
    const shadowRoots = [];
    const stack = viewportOnly ? [root] : [...(rootsOnly ? [] : Array.from(root.children ?? []).reverse()), ...firstRoots.slice().reverse()];
    const visitedRoots = new Set();
    let started = !startPath;
    let sectionName = "";
    if (firstRoots.length) {
      const headings = root.querySelectorAll("h1,h2,h3,h4,h5,h6,[role=heading]");
      for (const heading of headings) {
        if ((heading.compareDocumentPosition(firstRoots[0]) & Node.DOCUMENT_POSITION_FOLLOWING)
          && isVisible(heading) && !insideNavigation(heading)) sectionName = sectionHeading(heading);
      }
    }
    while (stack.length > 0 && result.length < maximum) {
      const element = stack.pop();
      if (!isPageContentElement(element)) continue;
      if (firstRoots.includes(element)) {
        if (visitedRoots.has(element)) continue;
        visitedRoots.add(element);
      }
      if (!started && isVisible(element) && !insideNavigation(element)) {
        const heading = sectionHeading(element);
        if (heading) sectionName = heading;
      }
      if (!started && stableElementPath(element) === startPath) started = true;
      // Offscreen retained elements spend neither the walk nor read budget.
      // Still traverse ancestors: fixed/overflowing descendants may be in view.
      if (started && (!viewportOnly || (isVisible(element) && intersectsViewport(element)))) result.push(element);
      if (element.shadowRoot) shadowRoots.push(element.shadowRoot);
      const descendants = [
        ...Array.from(element.shadowRoot?.children ?? []),
        ...Array.from(element.children ?? []),
      ];
      for (let index = descendants.length - 1; index >= 0; index -= 1) stack.push(descendants[index]);
    }
    if (!started) throw pageError("read_address_missing", "The folded element is no longer on this page. Read the page again.");
    while (stack.length && visitedRoots.has(stack[stack.length - 1])) stack.pop();
    return { elements: result, truncated: stack.length > 0, shadowRoots, nextElement: stack[stack.length - 1], sectionName };
  }

  function composedParent(element) {
    if (element.parentElement) return element.parentElement;
    const root = typeof element.getRootNode === "function" ? element.getRootNode() : null;
    return root?.host ?? null;
  }

  // A structural address is independent of snapshot budgets and row numbers.
  // Include shadow boundaries and same-tag sibling positions so repeated
  // captures can focus the same place without granting action authority.
  function stableElementPath(element) {
    const parts = [];
    for (let current = element; current;) {
      let ordinal = 1;
      for (let sibling = current.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
        if (sibling.localName === current.localName && sibling.namespaceURI === current.namespaceURI) ordinal++;
      }
      parts.unshift(`${encodeURIComponent(current.namespaceURI ?? "")}:${encodeURIComponent(current.localName)}[${ordinal}]`);
      if (current.parentElement) current = current.parentElement;
      else {
        const root = current.getRootNode();
        if (root instanceof ShadowRoot) { parts.unshift("shadow"); current = root.host; }
        else current = null;
      }
    }
    return parts.join("/");
  }

  // Read places come from the nearest heading, never a cell/control's text.
  // Allocation stays stable while the element's semantic place is the
  // same, independent of row numbers and transport folds. Structural paths
  // stay private; a reused element with a new heading gets its new place.
  function readableElementFragment(element, sectionName = "") {
    const slug = value => normalizedText(value).normalize("NFKC")
      .replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 96).replace(/-+$/g, "");
    const heading = sectionHeading(element);
    const name = heading || accessibleName(element, snapshotText(element));
    // An id is transport identity unless the page gives it meaning: its
    // semantic name agrees with it, or a page link actually targets it. This
    // uses authored relationships rather than guessing generated-id prefixes.
    const id = element.id || element.getAttribute("name") || "";
    const semanticID = heading && id && (slug(id).toLocaleLowerCase() === slug(name).toLocaleLowerCase()
      || isDocumentLinkTarget(element, id));
    // A unique authored anchor is already its exact document address. It
    // must not gain an ordinal because a wrapper/heading slug used its label
    // first. Generated places below avoid the document's real anchor names.
    const root = element.getRootNode();
    if (semanticID && root.getElementById?.(id) === element) {
      allocatedFragments.add(id);
      elementFragments.set(element, { base: id, fragment: id });
      return id;
    }
    const anchor = semanticID ? id : heading || sectionName || document.title;
    const base = ((semanticID ? anchor : slug(anchor)) || "page")
      .slice(0, 96).replace(/-+$/g, "");
    const retained = elementFragments.get(element);
    if (retained?.base === base) return retained.fragment;
    let ordinal = (fragmentCounts.get(base) ?? 0) + 1;
    let fragment = ordinal === 1 ? base : `${base}-${ordinal}`;
    while (allocatedFragments.has(fragment) || (root.getElementById?.(fragment) && root.getElementById(fragment) !== element)) {
      ordinal++; fragment = `${base}-${ordinal}`;
    }
    fragmentCounts.set(base, ordinal);
    allocatedFragments.add(fragment);
    elementFragments.set(element, { base, fragment });
    return fragment;
  }

  function isDocumentLinkTarget(element, id) {
    const root = element.getRootNode();
    if (!documentLinkTargets.has(root)) {
      const targets = new Set(), current = new URL(location.href);
      for (const link of root.querySelectorAll?.("a[href]") ?? []) {
        try {
          const target = new URL(link.getAttribute("href"), location.href);
          if (target.origin === current.origin && target.pathname === current.pathname && target.search === current.search
            && target.hash) targets.add(decodeURIComponent(target.hash.slice(1)));
        } catch { /* Invalid links cannot establish an authored reading place. */ }
      }
      documentLinkTargets.set(root, targets);
    }
    return documentLinkTargets.get(root).has(id);
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
