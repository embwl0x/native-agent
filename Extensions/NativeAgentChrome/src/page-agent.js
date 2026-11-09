(() => {
  const existing = globalThis.__nativeAgentPageAgent;
  if (existing?.isActive?.()) return;
  existing?.();
  const snapshots = new Map();
  const inputTargets = new Map();
  let scrollObservation = null;
  const elementIdentities = new WeakMap();
  const elementFragments = new WeakMap();
  const fragmentCounts = new Map();
  const allocatedFragments = new Set();
  let documentLinkTargets = new WeakMap();
  const activeRuns = new Set();
  const frameReadWaits = new Set();
  let disposed = false;
  const cancelledActions = new Set();
  let domGeneration = 0;
  // Coalesce mutation bursts in the page. This is a publication cadence, not
  // an action deadline: continuous changes still deliver one notice per turn.
  const CHANGE_DEBOUNCE_MS = 250;
  // A content check walks the page. Mutations ask for one, and checks are spaced
  // so the reader takes at most a twentieth of the page's time however fast it changes.
  const CONTENT_CHECK_SHARE = 20;
  let contentCheckTimer = null;
  let contentCheckCost = 0;
  let observedTab = null;
  let changeTimer = null;
  let contentPresent = false;
  let contentPresentAt = null;
  let routeContentRoots = null;
  let routeEntryId = window.navigation.currentEntry?.id;
  const inputBindings = [];

  for (const [kind, input] of [["pointerdown", "pointer"], ["keydown", "keyboard"], ["wheel", "scroll"], ["touchstart", "touch"]]) {
    const listener = (event) => {
      if (event.isTrusted !== true) return;
      // The sender arms this keydown on the exact focused host before dispatch.
      // Closed roots hide that host from the window's retargeted event path.
      if (kind === "keydown") for (const target of inputTargets.values()) {
        const expected = target.expectedKeydown;
        if (expected && activeElement() === target.host && performance.now() < target.expiresAt
          && Object.keys(expected).every(key => event[key] === expected[key])) {
          target.expectedKeydown = null;
          return;
        }
      }
      inputTargets.clear();
      for (const wait of [...frameReadWaits]) wait.finish({ known: false, cancelled: true });
      stopChangeStream();
      snapshots.clear();
      scrollObservation = null;
      for (const run of activeRuns) stopRun(run, "user_takeover");
      notifyHost({ type: "nativeagent.user-touch", kind: input });
    };
    inputBindings.push([kind, listener]);
    window.addEventListener(kind, listener, { capture: true, passive: true });
  }

  const MUTATION_SCOPE = { subtree: true, childList: true, attributes: true, characterData: true };
  // Observe shadow roots entered by the walker as well as the document.
  // A MutationObserver retains every root it observes strongly.
  const observedShadowRoots = new Set();
  const domObserver = new MutationObserver(records => pageMutated(records));
  function pageMutated(records, arrived = true) {
    if (arrived && routeContentRoots) for (const record of records) {
      if (record.type === "characterData") routeContentRoots.add(record.target);
      for (const node of record.addedNodes) routeContentRoots.add(node);
    }
    contentCheckDue();
    queuePageChange();
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
  }
  domObserver.observe(document, MUTATION_SCOPE);

  function stopChangeStream() {
    observedTab = null;
    clearTimeout(changeTimer);
    changeTimer = null;
  }

  function startChangeStream(message) {
    const newlyAttached = observedTab?.tabId !== message.tabId;
    observedTab = { tabId: message.tabId, userSequence: message.userSequence };
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
      } catch {
        // An unobservable root must not cost the caller the whole snapshot.
        observedShadowRoots.delete(root);
      }
    }
  }

  // Rebuild observation from attached roots; the next snapshot reflects queued mutations.
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

  const messageListener = (message, _sender, sendResponse) => {
    if (!message?.type?.startsWith("nativeagent.page.")) return false;
    try {
      // The same request identity governs synchronous and suspended handlers.
      if (!["nativeagent.page.input.readback", "nativeagent.page.input.release", "nativeagent.page.input.keyup"].includes(message.type) && cancelledActions.has(message.actionId)) throw pageError("action_cancelled", "The page action was cancelled before dispatch.");
      let result;
      switch (message.type) {
        case "nativeagent.page.observe":
          startChangeStream(message);
          announcePageContent();
          result = { observing: observedTab !== null, ...arrivalEvidence() };
          break;
        case "nativeagent.page.tab.invalidated":
          for (const wait of [...frameReadWaits]) wait.finish({ known: false, cancelled: true });
          for (const target of inputTargets.values()) { target.expectedKeydown = null; target.invalidated = true; }
          if (observedTab?.tabId === message.tabId) stopChangeStream();
          if (scrollObservation?.tabId === message.tabId) scrollObservation = null;
          for (const run of activeRuns) {
            if (run.tabId === message.tabId) stopRun(run, "tab_not_owned");
          }
          for (const [id, snapshot] of snapshots) {
            if (snapshot.tabId === message.tabId) snapshots.delete(id);
          }
          // Only an ended ownership sends this. Her reader stops costing the page at once;
          // it still answers an input's settlement, and a new ownership replaces it.
          retire();
          result = { invalidated: true };
          break;
        case "nativeagent.page.action.cancel":
          cancelledActions.add(message.requestId);
          for (const wait of [...frameReadWaits]) if (wait.actionId === message.requestId) wait.finish({ known: false });
          const inputTarget = inputTargets.get(message.requestId);
          if (inputTarget) inputTarget.expectedKeydown = null;
          if (cancelledActions.size > 128) cancelledActions.delete(cancelledActions.values().next().value);
          for (const run of activeRuns) if (run.actionId === message.requestId) stopRun(run, "action_cancelled");
          result = { cancelled: true };
          break;
        case "nativeagent.page.snapshot":
          result = readFrameSnapshot(message);
          break;
        case "nativeagent.page.document":
          result = documentEvidence(message.scope);
          break;
        case "nativeagent.page.click":
          result = clickNode(message);
          break;
        case "nativeagent.page.input.prepare":
          result = prepareInput(message);
          break;
        case "nativeagent.page.input.focus":
          result = focusInput(message);
          break;
        case "nativeagent.page.input.check":
          result = checkInput(message);
          break;
        case "nativeagent.page.input.atomic":
          checkInput({ ...message, requireFocus: false });
          result = fillAtomic(inputTargets.get(message.actionId).host, message);
          break;
        case "nativeagent.page.input.readback":
          result = readInput(message);
          break;
        case "nativeagent.page.input.release":
          inputTargets.delete(message.actionId);
          result = { released: true };
          break;
        case "nativeagent.page.input.keyup": {
          const target = inputTargets.get(message.actionId);
          if (target) target.expectedKeydown = null;
          result = { settling: true };
          break;
        }
        case "nativeagent.page.select":
          result = selectNode(message);
          break;
        case "nativeagent.page.set_checked":
          result = setCheckedNode(message);
          break;
        case "nativeagent.page.double_click":
          result = doubleClickNode(message);
          break;
        case "nativeagent.page.drag":
          result = dragNode(message);
          break;
        case "nativeagent.page.wait":
          result = waitForNodeState(message);
          break;
        case "nativeagent.page.scroll":
          result = scrollPage(message);
          break;
        case "nativeagent.page.media":
          result = controlMedia(message);
          break;
        default:
          throw pageError("unknown_page_action", "Unknown page action.");
      }
      if (result instanceof Promise) {
        void result.then(
          (value) => sendResponse({ ok: true, result: value }),
          (error) => sendPageError(sendResponse, error),
        );
        return true;
      }
      sendResponse({ ok: true, result });
    } catch (error) {
      sendPageError(sendResponse, error);
    }
    return false;
  };
  chrome.runtime.onMessage.addListener(messageListener);
  window.addEventListener("message", frameReadingListener);
  const runtime = chrome.runtime;
  const retire = () => {
    disposed = true;
    for (const wait of [...frameReadWaits]) wait.finish({ known: false });
    window.removeEventListener("message", frameReadingListener);
    document.removeEventListener("DOMContentLoaded", announceDocumentParsed);
    window.removeEventListener("load", announceDocumentParsed);
    window.navigation.removeEventListener("currententrychange", announcePageRoute);
    stopChangeStream();
    clearTimeout(contentCheckTimer);
    contentCheckTimer = null;
    domObserver.disconnect();
    observedShadowRoots.clear();
    snapshots.clear();
    scrollObservation = null;
    for (const [kind, listener] of inputBindings) window.removeEventListener(kind, listener, { capture: true });
    for (const run of activeRuns) stopRun(run, "tab_not_owned");
  };
  const teardown = () => {
    retire();
    inputTargets.clear();
    // An invalidated extension context has already lost its runtime listener.
    if (runtime.id) runtime.onMessage.removeListener(messageListener);
  };
  teardown.isActive = () => !disposed && Boolean(runtime.id);
  globalThis.__nativeAgentPageAgent = teardown;

  // A reloaded or updated extension orphans this copy: its runtime is gone and
  // every send throws "Extension context invalidated". Stop quietly instead.
  function notifyHost(message) {
    if (!chrome.runtime?.id) { teardown(); return; }
    try { void chrome.runtime.sendMessage(message).catch(() => {}); }
    catch { teardown(); }
  }

  function contentCheckDue() {
    if (contentCheckTimer !== null) return;
    contentCheckTimer = setTimeout(() => {
      contentCheckTimer = null;
      announcePageContent();
    }, Math.max(CHANGE_DEBOUNCE_MS, contentCheckCost * CONTENT_CHECK_SHARE));
  }

  function announcePageContent(force = false) {
    if (disposed) return;
    const hadContent = contentPresent;
    const checkStarted = performance.now();
    contentPresent = !pageReadiness("main_content").busy;
    contentCheckCost = performance.now() - checkStarted;
    if (!contentPresent) contentPresentAt = null;
    else if (contentPresentAt === null) contentPresentAt = performance.timeOrigin + performance.now();
    if (force !== true && contentPresent === hadContent) return;
    notifyHost({ type: "nativeagent.page.ready", ...arrivalEvidence() });
  }

  function arrivalEvidence() {
    return { url: location.href, contentPresent, contentPresentAt };
  }

  // The installed reader and the content it can see are separate evidence.
  // Mutation delivery does not depend on visibility or animation frames.
  function announceDocumentParsed() { announcePageContent(true); }
  function announcePageRoute() {
    const pending = domObserver.takeRecords();
    routeEntryId = window.navigation.currentEntry?.id;
    routeContentRoots = new WeakSet();
    contentPresent = false;
    contentPresentAt = null;
    if (pending.length) pageMutated(pending, false);
    notifyHost({ type: "nativeagent.page.ready", ...arrivalEvidence() });
  }
  window.navigation.addEventListener("currententrychange", announcePageRoute);
  document.addEventListener("DOMContentLoaded", announceDocumentParsed, { once: true });
  window.addEventListener("load", announceDocumentParsed, { once: true });
  queueMicrotask(() => announcePageContent(true));

  function documentEvidence(scope = "page") {
    if (document.contentType === "application/pdf" || (!normalizedText(document.body?.innerText ?? "")
      && document.querySelector('embed[type="application/pdf"], object[type="application/pdf"]'))) return { kind: "pdf", status: "unread" };
    const content = pageReadiness(scope);
    return { kind: document.contentType.startsWith("image/") ? "image" : "dom",
      ...content };
  }

  function pageReadiness(scope) {
    if (!document.body) return { busy: true, busyReason: "The document body has not arrived." };
    // DOMContentLoaded/load do not mean a script shell has rendered. Discover
    // its shadow roots before the first snapshot, and observe hydration there.
    const overlayFor = readingOverlayOwner();
    const { candidates } = readingScopeWalk("main_content", { overlayFor });
    // Header labels, search fields, a logo and a Personalize button do not
    // prove a feed has rendered. Read the actual prose, including shadow roots.
    const prose = candidates.filter(element => !overlayFor(element) && !insideNavigation(element)
      && !inPageChrome(element) && isPageContentElement(element) && isVisible(element)
      && !isSecureReadField(element))
      // Filter each rendered text run before joining: enclosing containers
      // must not bring their excluded controls' labels back into the stamp.
      .map(element => normalizedText(inlineText(element, null, node => !isReadinessControlText(node) && !isHeadingText(node)
        && isRouteContent(node))
        .map(part => part.text).join("")))
      .filter(Boolean).slice(0, 256);
    // Qualifying prose proves content presence, not completion of later script-rendered content.
    // A loaded document also admits one block or a visible control.
    const content = candidates.filter(element => !overlayFor(element) && !insideNavigation(element) && !inPageChrome(element)
      && isVisible(element));
    // The page's own loading indicator in its content says it is still filling in.
    if (content.some(element => element.matches("progress, [role=progressbar]"))) {
      return { busy: true, busyReason: `The ${scope} shows its own loading indicator; the page is still filling in.` };
    }
    const blocks = prose.filter(text => text.length >= 30).length;
    const loaded = document.readyState === "complete";
    const controls = loaded && content.some(element => element.matches("input:not([type=hidden]), textarea, select, button"));
    if (blocks < 3 && !(loaded && (blocks >= 1 || controls))) {
      return { busy: true, busyReason: `The ${scope} has ${blocks} readable block${blocks === 1 ? "" : "s"} so far; the page is still filling in.` };
    }
    // The stamp tracks filtered prose; an explicit page.wait can observe its stability.
    return { busy: false, contentStamp: contentKey(prose.join("\n").slice(0, 32_000)) };
  }

  function isRouteContent(node) {
    if (routeContentRoots === null) return true;
    for (let current = node; current; current = current.assignedSlot ?? current.parentNode ?? current.host) {
      if (routeContentRoots.has(current)) return true;
    }
    return false;
  }

  function isReadinessControlText(node, { includeComplementary = true } = {}) {
    // Follow rendered ancestry through slots and shadow hosts as well as light
    // DOM: a control's nested label is still control text. Article links outside
    // navigation remain prose, including headings nested inside those links.
    for (let current = node.assignedSlot ?? node.parentElement; current;
      current = current.assignedSlot ?? composedParent(current)) {
      if (current.matches("button, input, select, textarea, option, label, summary, menu, img, canvas, svg") || current.isContentEditable
        || (current.getAttribute("role") ?? "").trim().split(/\s+/).some(role =>
          ["button", "checkbox", "combobox", "listbox", "menu", "menubar", "menuitem", "menuitemcheckbox", "menuitemradio",
            "option", "radio", "scrollbar", "searchbox", "slider", "spinbutton", "switch", "tab", "textbox", "treeitem",
            "img", "graphics-document"].includes(role))
        || (includeComplementary ? insideNavigation(current) : current.matches("nav, [role=navigation]"))
        || inPageChrome(current)) return true;
    }
    return false;
  }

  // A page's title or section headings render before its content (x.com shows "Home" over an empty timeline): they are not content.
  function isHeadingText(node) {
    for (let current = node.assignedSlot ?? node.parentElement; current; current = current.assignedSlot ?? composedParent(current)) {
      if (/^h[1-6]$/.test(current.localName) || current.getAttribute("role") === "heading") return true;
    }
    return false;
  }

  function contentKey(text) {
    let hash = 2166136261;
    for (let index = 0; index < text.length; index++) hash = Math.imul(hash ^ text.charCodeAt(index), 16777619);
    return `${text.length}:${hash >>> 0}`;
  }

  function inPageChrome(element) {
    for (let current = element; current; current = composedParent(current)) {
      if (["header", "footer"].includes(current.localName) || ["banner", "contentinfo"].includes(current.getAttribute?.("role"))) return true;
      if (current.localName === "main" || current.getAttribute?.("role") === "main") return false;
    }
    return false;
  }

  // Readiness and capture select the same semantic regions, navigation and overlays.
  function readingScopeWalk(scope, { target = window, viewportRoot = null, position = null,
    overlayFor = readingOverlayOwner(), maximum = 5_000 } = {}) {
    if (!["page", "main_content"].includes(scope)) throw pageError("invalid_snapshot_scope", "Read the page or its semantic main content.");
    languageNavigationCache = new WeakMap();
    let walk = readingElementWalk([viewportRoot ?? document.body], target, maximum, position, overlayFor);
    pruneObservedShadowRoots();
    observeShadowRoots(walk.shadowRoots);
    const modalSelector = "dialog, [role=dialog][aria-modal=true], [role=alertdialog][aria-modal=true]";
    const modalRoots = new Set([document, ...walk.shadowRoots]);
    let modals = [...new Set([...modalRoots].flatMap(root => [...root.querySelectorAll(modalSelector)]))]
      .filter((element) => isVisible(element) && isModal(element));
    const regionSelector = "main, article, [role=main], [role=feed], [role=article], [role=document], [itemprop~=articleBody]";
    const regions = [...document.querySelectorAll(regionSelector), ...walk.elements,
      ...walk.shadowRoots.flatMap(root => [...root.querySelectorAll(regionSelector)])];
    if (viewportRoot) for (let parent = composedParent(viewportRoot); parent; parent = composedParent(parent)) regions.push(parent);
    const mainRegions = [...new Set(regions)].filter((element) => isVisible(element)
      && element.matches("main, [role=main], [role=feed]"));
    const articleRegions = [...new Set(regions)].filter((element) => isVisible(element)
      && element.matches("article, [role=article], [role=document], [itemprop~=articleBody]"));
    const bodies = articleRegions.filter(element => !articleRegions.some(other => other !== element && withinElement(element, other)));
    const mainContentAvailable = mainRegions.length > 0 || bodies.length > 0;
    const contentRegions = mainRegions.length ? mainRegions : bodies.length ? bodies : [document.body].filter(Boolean);
    // Scope and viewport priority apply before either the walk or row budget.
    if (scope === "main_content" && !viewportRoot) {
      const roots = [...new Set([...contentRegions, ...modals, ...walk.elements.map(overlayFor).filter(Boolean)])];
      walk = readingElementWalk(roots, target, maximum, position, overlayFor);
      observeShadowRoots(walk.shadowRoots);
      for (const root of walk.shadowRoots) modalRoots.add(root);
      modals = [...new Set([...modalRoots].flatMap(root => [...root.querySelectorAll(modalSelector)]))]
        .filter((element) => isVisible(element) && isModal(element));
    }
    // A long sidebar must not spend the content budget before the article.
    const candidates = scope === "page" ? walk.elements : walk.elements.filter((element) =>
      overlayFor(element) || modals.some((modal) => withinElement(element, modal))
      || (contentRegions.some((region) => withinElement(element, region)) && !insideNavigation(element)));
    return { walk, candidates, modals, mainContentAvailable };
  }

  // Resolve the actual embedding element by Window identity, including a
  // cross-origin frame. No URL/name guess is an embedding proof. Only layout
  // classification crosses this page message; it carries no action authority.
  async function frameReadingListener(event) {
    const request = event.data;
    if (disposed || request?.type !== "nativeagent.frame.reading" || typeof request.nonce !== "string"
      || request.nonce.length > 64 || event.source === window) return;
    const roots = [document, ...observedShadowRoots];
    const frame = roots.flatMap(root => [...root.querySelectorAll("iframe, frame")])
      .find(element => element.contentWindow === event.source);
    if (!frame) {
      event.source.postMessage({ type: "nativeagent.frame.reading.reply", nonce: request.nonce,
        known: false, overlay: false, cause: "The parent could not find this frame's embedding element." }, "*");
      return;
    }
    const ancestor = await embeddingOverlay(request.actionId);
    if (disposed || ancestor.cancelled || !frame.isConnected) return;
    const overlay = Boolean(readingOverlayOwner()(frame)) || ancestor.overlay === true;
    event.source.postMessage({ type: "nativeagent.frame.reading.reply", nonce: request.nonce,
      known: overlay || ancestor.known, overlay, cause: ancestor.cause }, "*");
  }

  function embeddingOverlay(actionId) {
    if (window === window.top) return Promise.resolve({ known: true, overlay: false });
    return new Promise(resolve => {
      const nonce = crypto.randomUUID();
      const wait = { actionId, finish };
      function finish(evidence) {
        if (!frameReadWaits.delete(wait)) return;
        window.removeEventListener("message", received);
        resolve(evidence);
      }
      function received(event) {
        const reply = event.data;
        if (event.source !== parent || reply?.type !== "nativeagent.frame.reading.reply" || reply.nonce !== nonce
          || typeof reply.known !== "boolean" || typeof reply.overlay !== "boolean") return;
        finish({ known: reply.known, overlay: reply.overlay, cause: reply.cause });
      }
      frameReadWaits.add(wait);
      window.addEventListener("message", received);
      parent.postMessage({ type: "nativeagent.frame.reading", nonce, actionId }, "*");
    });
  }

  async function readFrameSnapshot(message) {
    const embedding = await embeddingOverlay(message.actionId);
    if (disposed) throw pageError("tab_not_owned", "The page reader was replaced before capture.");
    if (cancelledActions.has(message.actionId)) throw pageError("action_cancelled", "The read was cancelled before capture.");
    if (embedding.cancelled) throw pageError("tab_not_owned", "The tab was released before capture.");
    return createSnapshot({ ...message, embedding });
  }

  function createSnapshot(message) {
    // Authored anchors and section labels are evidence of this capture only.
    documentLinkTargets = new WeakMap();
    // Background supplies the protocol owner's resolved limits.
    const maxNodes = message.maxNodes;
    const maxTextChars = message.maxTextChars;
    const readingScope = message.scope ?? "page";
    const snapshotId = crypto.randomUUID();
    const elementByNodeId = new Map();
    const actionNodeIds = new Map();
    const identityByNodeId = new Map();
    const navigationProofs = new Map();
    const selectProofs = new Map();
    const nodeIdByElement = new Map();
    const nodes = [];
    const truncationReasons = [];
    if (!message.embedding.known) truncationReasons.push("frame_overlay_unavailable");
    let pageMoved = Boolean(message.readCursor && (message.readCursor.frameURL ?? message.readCursor.url) !== location.href);
    const viewportObservationId = message.readCursor?.viewportObservationId;
    const observation = viewportObservationId && scrollObservation?.id === viewportObservationId
      && scrollObservation.tabId === message.tabId
      && (scrollObservation.target === window || scrollObservation.target.isConnected) ? scrollObservation : null;
    if (viewportObservationId && !observation) pageMoved = true;
    const target = observation?.target ?? window;
    const viewportRoot = observation?.target === window ? document.body : observation?.target;
    const view = readingViewport(target);
    let cursor = !pageMoved ? message.readCursor : null;
    if (cursor?.position && (cursor.position.scrollX !== view.scrollX || cursor.position.scrollY !== view.scrollY)) {
      pageMoved = true;
      cursor = null;
    }
    const overlayFor = readingOverlayOwner(message.embedding.overlay === true);
    const readLayer = message.readLayer;
    const startPosition = cursor?.position ?? (readLayer === "overlay" ? {
      overlay: true, scrollX: view.scrollX, scrollY: view.scrollY,
      distance: 0, y: -Number.MAX_SAFE_INTEGER, x: -Number.MAX_SAFE_INTEGER,
      flow: [0, 0, -Number.MAX_SAFE_INTEGER, -Number.MAX_SAFE_INTEGER], ordinal: 0,
    } : null);
    let { walk, candidates, modals, mainContentAvailable } = readingScopeWalk(readingScope,
      { target, viewportRoot, position: cursor?.anchor ? null : startPosition, overlayFor, maximum: 20_000 });
    const modalNames = new Map(modals.map(modal => [modal, modalName(modal)]));
    candidates = candidates.filter(element => Boolean(overlayFor(element)) === (readLayer === "overlay"));
    if (message.identityOnly) candidates = [];
    const viewportChanged = observation ? viewportChange(observation.before, captureViewport(observation.target)) : null;
    // A continuation is a place in the rendered page, never a DOM address.
    // Recycled/removed rows simply leave whatever is now beyond that place.
    if (cursor?.anchor) {
      const anchor = candidates.find(element => elementIdentities.get(element) === cursor.anchor.identity
        && readingAnchorKey(element) === cursor.anchor.key);
      if (anchor) {
        const position = walk.positions.get(anchor);
        if (compareReadingPosition(position, cursor.position) !== 0) pageMoved = true;
        cursor = { ...cursor, position };
      } else pageMoved = true;
    }
    if (cursor?.position) candidates = candidates.filter(element => compareReadingPosition(walk.positions.get(element), cursor.position) >= 0);
    const continuedElement = cursor?.position && candidates.find(element => compareReadingPosition(walk.positions.get(element), cursor.position) === 0);
    if (cursor?.position && !continuedElement) pageMoved = true;
    if (cursor?.elementOnly === true) {
      if (continuedElement?.tagName.toLowerCase() === "select") candidates = [continuedElement];
      else { pageMoved = true; cursor = null; }
    }
    const find = message.find ?? cursor?.find;
    let found = false;
    if (find) {
      const needle = normalizedText(find).toLocaleLowerCase();
      const index = candidates.findIndex(element => isVisible(element) && !isSecureReadField(element)
        && normalizedText(snapshotText(element) || accessibleName(element, "")).toLocaleLowerCase().includes(needle));
      found = index >= 0;
      candidates = found ? candidates.slice(index) : [];
    }
    const readAt = (element, offsets = {}) => ({ position: walk.positions.get(element), readLayer,
      anchor: readingAnchor(element),
      ...(find && !found ? { find } : {}),
      ...(observation ? { viewportObservationId: observation.id } : {}), name: sectionName, ...offsets });
    const glyphCounts = fragmentedTextGlyphCounts(candidates);
    const collapsedText = new Set();
    let nextRead = null;
    let aggregateNodeText = 0;
    // Node text shares the summary budget; oversized controls fold their content.
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
      nextRead = readAt(boundary.element, { textOffset: 0, name: boundary.sectionName });
      return true;
    };
    if (walk.truncated) truncationReasons.push("walk_limit");

    function retainNode(element, presentation, fullText, selectInfo = null) {
      const nodeId = `n${nodes.length + 1}`;
      if (!elementIdentities.has(element)) elementIdentities.set(element, crypto.randomUUID());
      nodeIdByElement.set(element, nodeId); elementByNodeId.set(nodeId, element);
      // Presentation compaction never changes the full action identity.
      identityByNodeId.set(nodeId, nodeIdentity(element, bounded(accessibleName(element, fullText), 500)));
      if (selectInfo) selectProofs.set(nodeId, {
        description: JSON.stringify(selectDescription(element, 0, Infinity)), observed: selectInfo.options,
      });
      const navigationProof = captureNavigationProof(element);
      if (navigationProof) navigationProofs.set(nodeId, navigationProof);
      const rect = element.getBoundingClientRect();
      const role = element.getAttribute("role") ?? implicitRole(element);
      const blockedByModal = modals.length > 0 && (modals.length !== 1 || !withinElement(element, modals[0]));
      const blockingDialogs = blockedByModal ? modals.filter(modal => !withinElement(element, modal))
        .map(modal => modalNames.get(modal)).filter(Boolean) : [];
      const actions = snapshotActions(element, role, blockedByModal);
      let parent = composedParent(element);
      while (parent && !nodeIdByElement.has(parent)) parent = composedParent(parent);
      nodes.push({
        nodeId, elementIdentity: elementIdentities.get(element), elementPath: stableElementPath(element),
        readAnchor: readingAnchor(element), readLayer,
        addressFragment: readableElementFragment(element, presentation.sectionName),
        parentNodeId: parent ? nodeIdByElement.get(parent) : null,
        kind: elementKind(element), role, ...readingStructure(element), value: safeValue(element),
        overlay: Boolean(overlayFor(element)),
        ...(!message.embedding.known ? { overlayUnknown: true } : {}),
        level: headingLevel(element), visible: true,
        states: {
          disabled: isEffectivelyDisabled(element), checked: ariaBoolean(element, "aria-checked", "checked"),
          selected: ariaBoolean(element, "aria-selected", "selected"),
          expanded: nullableAriaBoolean(element.getAttribute("aria-expanded")), editable: isEditable(element), blockedByModal,
          ...(blockingDialogs.length ? { blockingDialogs } : {}),
        },
        actions, url: safeURL(element), scrollable: actions.includes("scroll"),
        bounds: { x: finite(rect.x), y: finite(rect.y), width: Math.max(0, finite(rect.width)), height: Math.max(0, finite(rect.height)) },
        ...presentation,
        ...(selectInfo && isSecureReadField(element) ? {
          select: { ...selectInfo, options: selectInfo.options.map(option => ({ ...option, selected: null })) },
        } : {}),
      });
      for (const action of actions) {
        if (!actionNodeIds.has(action)) actionNodeIds.set(action, new Set());
        actionNodeIds.get(action).add(nodeId);
      }
    }

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
      const linksByPath = new Map();
      const runs = fragmented ? [] : inlineText(element, linksByPath);
      const fullText = isSecureReadField(element) ? "" : fragmented ? normalizedText(visibleFragmentedText(element)) : snapshotText(element, runs);
      let textOffset = element === continuedElement ? (cursor?.textOffset ?? 0) : 0;
      if (textOffset > fullText.length) { pageMoved = true; textOffset = 0; }
      let text = fullText.slice(textOffset);
      let name = bounded(accessibleName(element, text), 500);
      if (kind === "image") {
        const box = element.getBoundingClientRect();
        const visual = ["canvas", "svg"].includes(element.localName) ? "chart/graphic" : "image";
        name = `${name} (${visual}, ${Math.round(box.width)} × ${Math.round(box.height)} CSS px)`;
      }
      // Layout wrappers repeat the entire feed at every nesting level. Keep
      // semantic containers and controls, and preserve direct/leaf text instead.
      if (!fragmented && !text && isRedundantLayoutWrapper(element, kind)) continue;
      if (fragmented) for (const child of element.children) collapsedText.add(child);
      if (fragmented && !text) continue;
      if (!name && !text && kind === "other") continue;
      const heading = sectionHeading(element);
      if (nodes.length && nodes[nodes.length - 1].overlay !== Boolean(overlayFor(element))) {
        sectionStart = null; paragraphStart = null; paragraph = null;
      }
      if (heading) { sectionName = bounded(heading, 160); sectionStart = checkpoint(element); }
      const block = readingBlock(element);
      if (block !== paragraph) { paragraph = block; paragraphStart = checkpoint(element); }
      if (nodes.length >= maxNodes) {
        truncationReasons.push("node_limit");
        if (!foldAtBoundary()) nextRead = readAt(element, { textOffset: 0 });
        break;
      }
      let optionOffset = element === continuedElement ? (cursor?.optionOffset ?? 0) : 0;
      if (element.options && optionOffset > element.options.length) { pageMoved = true; optionOffset = 0; }
      let selectInfo = element.tagName.toLowerCase() === "select" ? selectDescription(element, optionOffset) : null;
      if (selectInfo) name = bounded(accessibleName(element, fullText), 500);
      let elementMore = null;
      if (selectInfo && (optionOffset || selectInfo.optionsTruncated
        || name.length + text.length + JSON.stringify(selectInfo).length > maxTextChars - aggregateNodeText
        || utf8.encode(name + text + JSON.stringify(selectInfo)).length > nodeByteBudget - aggregateNodeBytes)) {
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
          nextRead = readAt(element, { textOffset, optionOffset, ...(cursor?.elementOnly ? { elementOnly: true } : {}) });
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
            nextRead = readAt(element, { textOffset, optionOffset, ...(cursor?.elementOnly ? { elementOnly: true } : {}) });
            if (!nodes.length) throw pageError("read_budget_too_small", "The read budget cannot hold the next character. Increase max_text_chars.");
            truncationReasons.push("text_limit");
            break;
          }
          elementMore = { url: location.href, ...readAt(element, { elementOnly: true,
            textOffset: textOffset + end, optionOffset: nextOption }) };
          text = text.slice(0, end);
        }
        if (!optionOffset && !elementMore) delete selectInfo.optionOffset;
      }
      const choiceText = selectInfo ? JSON.stringify(selectInfo) : "";
      // A prose prefix and every link proof it names are budgeted together.
      // Prefix costs only grow, so a bounded binary search finds a window
      // that advances without ever leaving dangling action references.
      const groupFor = value => {
        const inline = inlineTextWindow(runs, textOffset, value.length);
        const proofs = [];
        for (const path of new Set(inline.map(part => part.elementPath).filter(Boolean))) {
          const link = linksByPath.get(path);
          if (!link) throw pageError("inline_proof_unavailable", "An inline link lost its action evidence during capture.");
          if (link === element || nodeIdByElement.has(link)) continue;
          const text = snapshotText(link), name = bounded(accessibleName(link, text), 500);
          proofs.push({ link, text, name, path });
        }
        const chars = name.length + value.length + choiceText.length + proofs.reduce((sum, proof) => sum + 2 * proof.name.length, 0);
        const bytes = utf8.encode(name + value + choiceText).length + proofs.reduce((sum, proof) => sum + 2 * utf8.encode(proof.name).length, 0);
        return { inline, proofs, chars, bytes, fits: nodes.length + 1 + proofs.length <= maxNodes
          && aggregateNodeText + chars <= maxTextChars && aggregateNodeBytes + bytes <= nodeByteBudget };
      };
      let group = groupFor(text);
      if (!group.fits) {
        truncationReasons.push(nodes.length + 1 + group.proofs.length > maxNodes ? "node_limit" : "text_limit");
        if (foldAtBoundary()) break;
        const characters = Array.from(text);
        let low = 0, high = characters.length;
        while (low < high) {
          const middle = Math.ceil((low + high) / 2);
          if (groupFor(characters.slice(0, middle).join("")).fits) low = middle;
          else high = middle - 1;
        }
        const prefix = characters.slice(0, low).join("");
        group = groupFor(prefix);
        if (!group.fits || (!prefix && text)) {
          if (!nodes.length) throw pageError("read_budget_too_small", "The read budget cannot hold the next prose character and its link proof. Increase max_nodes or max_text_chars.");
          nextRead = readAt(element, { textOffset, optionOffset });
          break;
        }
        text = prefix;
        nextRead = readAt(element, { textOffset: textOffset + text.length, optionOffset });
      }
      aggregateNodeText += group.chars;
      aggregateNodeBytes += group.bytes;

      retainNode(element, {
        readPosition: walk.positions.get(element),
        name,
        text,
        textOffset,
        sectionName,
        sectionPath: sectionStart ? stableElementPath(sectionStart.element) : null,
        paragraphPath: stableElementPath(paragraph),
        inlineText: group.inline,
        inline: ["inline", "inline-block", "contents"].includes(getComputedStyle(element).display),
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
      }, fragmented ? snapshotText(element) : fullText, selectInfo);
      for (const proof of group.proofs) retainNode(proof.link, {
        readPosition: walk.positions.get(element), textOffset, sectionName,
        sectionPath: sectionStart ? stableElementPath(sectionStart.element) : null,
        paragraphPath: stableElementPath(paragraph),
        parentNodeId: null, name: proof.name, text: proof.name, inlineProof: true,
      }, proof.text);
      for (const part of group.inline) if (part.elementPath) representedLinks.add(part.elementPath);
      if (nextRead) break;
    }
    if (!message.identityOnly && !cursor?.elementOnly && !nextRead && walk.nextElement
      && Boolean(overlayFor(walk.nextElement)) === (readLayer === "overlay")
      && (!cursor?.position || compareReadingPosition(walk.positions.get(walk.nextElement), cursor.position) > 0)) {
      const nextSection = bounded(sectionHeading(walk.nextElement) || sectionName, 160);
      if (!foldAtBoundary()) nextRead = readAt(walk.nextElement, { textOffset: 0, name: nextSection });
    }
    // A body prefix keeps returning old feed items after scrolling and can
    // consume the budget before replies. Summarize the same viewport evidence
    // as the nodes. Keep container prose too: an article can have direct text
    // followed by buttons, without a separate text leaf for that prose.
    const rawSummary = nodes.length ? nodes.filter(node => !node.inlineProof)
      .map((node) => node.text || node.name).filter(Boolean).join("\n")
      : (!find && !document.body?.children?.length ? normalizedText(document.body?.innerText ?? "") : "");
    const summaryText = bounded(rawSummary, maxTextChars);
    if (summaryText.length < rawSummary.length) truncationReasons.push("text_limit");
    const documentInfo = documentEvidence(readingScope);
    const snapshot = {
      snapshotId,
      tabId: message.tabId,
      userSequence: message.userSequence,
      capturedAt: new Date().toISOString(),
      url: location.href,
      title: bounded(document.title ?? "", 1_024),
      ...(documentInfo.kind === "dom" ? {} : { document: documentInfo }),
      language: bounded(document.documentElement?.lang ?? navigator.language ?? "", 64),
      rendering: {
        visibility: ["visible", "hidden"].includes(document.visibilityState) ? document.visibilityState : "unknown",
        readyState: ["loading", "interactive", "complete"].includes(document.readyState) ? document.readyState : "unknown",
        scope: "rendered_dom_only",
      },
      reading: { scope: readingScope, mainContentAvailable,
        overlayKnown: message.embedding.known,
        ...(find ? { find: { text: find, matched: found, walkLimited: walk.truncated } } : {}),
        sections: [...new Set(nodes.filter(node => !node.inlineProof).map(node => node.sectionName).filter(Boolean))],
        fromViewport: true, pageMoved, viewportObservationId: observation?.id ?? null,
        ...(observation ? { viewportChanged } : {}) },
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
        gaps: message.embedding.known ? [] : [{ code: "frame_overlay_unavailable",
          message: message.embedding.cause }],
      },
      nodes,
      readMore: nextRead ? { url: location.href, ...nextRead, name: bounded(normalizedText(nextRead.name || "Remaining page"), 160) } : null,
      frame: {
        name: bounded(frameName(), 500),
        url: location.href,
      },
    };
    if (message.passive === true) {
      for (const [id, previous] of snapshots) {
        if (previous.passive === true && previous.captureId !== message.captureId) snapshots.delete(id);
      }
    } else if (![...snapshots.values()].some(previous => previous.captureId === message.captureId)) snapshots.clear();
    snapshots.set(snapshotId, {
      tabId: message.tabId, domGeneration, elementByNodeId, actionNodeIds, identityByNodeId,
      navigationProofs, selectProofs, modals, capturedAt: Date.now(), pageURL: location.href,
      passive: message.passive === true, captureId: message.captureId,
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
    if (isEditable(element)) actions.push("fill");
    if (isSequentialEditable(element)) actions.push("type");
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
    requireEnabledNode(element, "click");
    element.click();
    return { snapshotId: message.snapshotId, nodeId: message.nodeId, clicked: true,
      outcome: "succeeded", verification: "page_acknowledged" };
  }

  // Retain the exact host across this action's own DOM mutations for readback.
  function editingHost(element) {
    if (!element.isContentEditable) return element;
    let host = element;
    for (let parent = composedParent(host); parent?.isContentEditable; parent = composedParent(host)) host = parent;
    return host;
  }

  function activeElement() {
    let active = document.activeElement;
    for (let nested = elementShadowRoot(active)?.activeElement; nested; nested = elementShadowRoot(active)?.activeElement) active = nested;
    return active;
  }

  function prepareInput(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, message.action);
    const host = editingHost(element);
    if (!isVisible(element) || !isVisible(host)) throw pageError("node_not_visible", "The editing target is no longer visible.");
    requireEnabledNode(host, message.action);
    if (isPasswordField(host)) throw pageError("node_not_actionable", "Password fields cannot receive this action.");
    const atomic = message.action === "fill" && !isSequentialEditable(host);
    if (atomic && host.type === "file" && message.value !== "") throw pageError("file_value_prohibited", "Chrome only permits clearing a file input through its value setter.");
    for (const [id, target] of inputTargets) if (performance.now() >= target.expiresAt) inputTargets.delete(id);
    inputTargets.set(message.actionId, { host, before: readEditableValue(host), action: message.action,
      identity: inputIdentity(host), parent: composedParent(host), atomic,
      expectedKeydown: null, expiresAt: performance.now() + 20_000 });
    return { prepared: true, mode: atomic ? "atomic" : "keyboard" };
  }

  function focusInput(message) {
    checkInput({ ...message, requireFocus: false });
    const target = inputTargets.get(message.actionId), host = target.host;
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, message.action);
    if (editingHost(element) !== host) throw pageError("node_identity_changed", "The exact editing host changed before focus.");
    focusWithoutActivation(host);
    if (activeElement() !== host || !document.hasFocus()) throw pageError("focus_failed", "The exact target did not take focus; no keys or text were sent.");
    const before = readEditableValue(host);
    let selection = null;
    if (message.action !== "keypress") {
      if (!isSequentialEditable(host)) throw pageError("node_not_editable", "This target does not support sequential text editing.");
      if (host.isContentEditable) {
        const selection = window.getSelection();
        if (!selection) throw pageError("selection_unavailable", "The editing host has no readable selection.");
        const range = document.createRange();
        range.selectNodeContents(host);
        if (message.action === "type") range.collapse(false);
        selection.removeAllRanges(); selection.addRange(range);
      } else if (typeof host.setSelectionRange === "function" && !["email", "number"].includes(host.type)) {
        host.setSelectionRange(message.action === "fill" ? 0 : before.length, before.length);
      } else {
        // Email/number expose no range setter. Chrome positions their caret.
        selection = "native_selection";
      }
    }
    target.before = before;
    return { focused: true, selection };
  }

  function checkInput(message) {
    const target = inputTargets.get(message.actionId);
    if (!target || target.invalidated || performance.now() >= target.expiresAt) throw pageError("input_target_expired", "The admitted input target expired; no further input was sent.");
    const { host } = target;
    if (!host.isConnected || editingHost(host) !== host
      || inputIdentity(host) !== target.identity || composedParent(host) !== target.parent) throw pageError("node_identity_changed", "The admitted editing host changed; no further input was sent.");
    if (!isVisible(host)) throw pageError("node_not_visible", "The editing host is no longer visible.");
    requireEnabledNode(host, target.action);
    if (isPasswordField(host)) throw pageError("node_not_actionable", "The target became a password field.");
    if (message.requireFocus !== false && (activeElement() !== host || !document.hasFocus())) throw pageError("focus_changed", "The admitted editing host lost focus; no further input was sent.");
    if (target.action !== "keypress" && !(target.atomic ? isEditable(host) : isSequentialEditable(host))) throw pageError("node_not_editable", "The target is no longer editable.");
    target.expectedKeydown = message.expectedKeydown ?? null;
    return { current: true };
  }

  function readInput(message) {
    const target = inputTargets.get(message.actionId);
    if (!target) throw pageError("input_readback_unavailable", "The exact input target is unavailable. Observe the page before doing anything further.");
    const { host, before, action } = target;
    if (isPasswordField(host)) throw pageError("input_readback_unavailable", "The target became a password field; its value is protected.");
    if (!host.isConnected) return { outcome: "outcome_unknown", verification: "outcome_unknown", landed: "unknown", reason: "target_detached" };
    const after = readEditableValue(host);
    const expected = action === "fill" ? message.sentText : before + message.sentText;
    const landed = action === "keypress" ? (after === before ? "no_value_change" : "landed")
      : after === expected ? "landed" : after !== before ? "changed_by_page" : "not_landed";
    return { outcome: action === "keypress" || landed !== "not_landed" ? "succeeded" : "refused",
      verification: "page_acknowledged", landed,
      valueBefore: bounded(before, 2000), valueAfter: bounded(after, 2000),
      valueTruncated: before.length > 2000 || after.length > 2000,
      valueRetained: after === expected, valueRewritten: landed === "changed_by_page",
      focused: activeElement() === host };
  }

  function inputIdentity(host) {
    return JSON.stringify([host.tagName, host.type, host.isContentEditable,
      ...["id", "name", "role", "aria-label", "aria-labelledby"].map(key => host.getAttribute(key))]);
  }

  function fillAtomic(element, message) {
    const before = readEditableValue(element);
    if (element.type === "file" && message.value !== "") throw pageError("file_value_prohibited", "Chrome only permits clearing a file input through its value setter.");
    try {
      setNativeValue(element, message.value);
      dispatchEditableEvent(element, "input");
      dispatchEditableEvent(element, "change");
    } catch { throw pageError("action_outcome_unknown", "The atomic value setter or page handler failed; observe before acting again."); }
    if (!element.isConnected) throw pageError("action_outcome_unknown", "The atomic control was replaced after dispatch; observe its state.");
    const after = readEditableValue(element);
    return { mode: "atomic", filled: true, outcome: after === before && after !== message.value ? "refused" : "succeeded",
      verification: "page_acknowledged", landed: after === message.value ? "landed" : after !== before ? "changed_by_page" : "not_landed",
      valueBefore: bounded(before, 2000), valueAfter: bounded(after, 2000), valueRewritten: after !== message.value };
  }

  function selectNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "select");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
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
      outcome: "succeeded", verification: "page_acknowledged",
      values,
    };
  }

  function setCheckedNode(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "set_checked");
    if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
    requireEnabledNode(element, "set_checked");
    const before = checkedState(element);
    let after;
    try {
      if (before !== message.checked) {
        element.click();
      }
      after = checkedState(element);
      if (!element.isConnected || typeof after !== "boolean") throw new Error("checked_readback_unavailable");
    } catch {
      throw pageError("action_outcome_unknown", "Checkable control was dispatched but its immediate state could not be confirmed. Observe before retrying; do not blindly repeat the action.");
    }
    return {
      snapshotId: message.snapshotId,
      nodeId: message.nodeId,
      setChecked: after === message.checked,
      outcome: after === message.checked ? "succeeded" : "refused", verification: "page_acknowledged",
      requestedChecked: message.checked,
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
    return { snapshotId: message.snapshotId, nodeId: message.nodeId, doubleClicked: true,
      outcome: "succeeded", verification: "page_acknowledged" };
  }

  async function waitForNodeState(message) {
    const element = requireActionableSnapshotNode(message.snapshotId, message.nodeId, "wait");
    const snapshot = requireSnapshot(message.snapshotId);
    const deadline = performance.now() + message.timeoutMs;
    const run = { tabId: snapshot.tabId, actionId: message.actionId, stopReason: null };
    activeRuns.add(run);
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
        await delay(Math.min(50, Math.max(1, deadline - performance.now())), run);
      }
    } finally {
      activeRuns.delete(run);
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
      outcome: dropAcknowledged ? "succeeded" : "outcome_unknown", verification: dropAcknowledged ? "page_acknowledged" : "not_verified",
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
      outcome: completed ? "succeeded" : "outcome_unknown", verification: completed ? "verified" : "not_verified",
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
        activeRuns.delete(run);
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
      activeRuns.add(run);
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
      // Targeted scrolling requires an advertised action and captured identity.
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
      outcome: "succeeded", verification: "page_acknowledged",
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
  function captureViewport(target, walk = readingElementWalk([target === window ? document.body : target], target)) {
    if (walk.truncated && walk.positions.get(walk.nextElement).distance === 0) return null;
    const rows = walk.elements.filter(element => isPageContentElement(element) && isVisible(element) && intersectsViewport(element)).map(element => {
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

  function nodeIdentity(element, name) {
    const role = element.getAttribute("role") ?? implicitRole(element);
    return `${element.tagName.toLowerCase()}\u0000${role}\u0000${name}`;
  }

  function currentNodeIdentity(element) {
    const text = snapshotText(element);
    return nodeIdentity(element, bounded(accessibleName(element, text), 500));
  }

  function snapshotText(element, runs = null) {
    if (isSecureReadField(element)) return "";
    // Visible inline runs keep offscreen feed text out of container prose.
    const kind = elementKind(element);
    if (!isPageContentElement(element) || kind === "image") return "";
    if (isPreformatted(element)) return element.innerText ?? element.textContent ?? "";
    if (element.tagName === "TIME") return normalizedText(element.innerText ?? element.textContent ?? "");
    const control = ["button", "link", "tab", "menuitem", "heading", "option", "select", "input"].includes(kind);
    const raw = !control && element.children?.length && element.childNodes
      ? (runs ?? inlineText(element)).map((part) => part.text).join("")
      : (["button", "link", "tab", "menuitem", "heading"].includes(kind)
        ? visibleControlText(element) : (element.innerText ?? element.textContent ?? ""));
    return element.querySelector("code") && !element.closest("pre") ? raw : normalizedText(raw);
  }

  // Inline runs keep DOM order and each link's structural address.
  function inlineText(element, linkTargets, includeText = () => true) {
    const parts = [];
    const preformatted = isPreformatted(element);
    function visit(parent, link = null, code = false) {
      for (const child of parent.childNodes ?? []) {
        if (child.nodeType === 3) {
          if (!includeText(child)) continue;
          if (link) linkTargets?.set(stableElementPath(link), link);
          parts.push({ text: child.textContent ?? "", ...(link ? { elementPath: stableElementPath(link), href: safeURL(link) } : {}), ...(code ? { code: true } : {}) });
        }
        else if (child.nodeType === 1) {
          if (!isPageContentElement(child) || isSecureReadField(child)) continue;
          if (elementKind(child) === "image") continue;
          if (insideNavigation(child) && !insideNavigation(element)) continue;
          if (child.tagName === "BR") { parts.push({ text: preformatted ? "\n" : " " }); continue; }
          const style = getComputedStyle(child);
          if (style.display === "none" || style.visibility === "hidden" || transparent(child, style)) continue;
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
      || transparent(child, getComputedStyle(child)) || (insideNavigation(child) && !navigational))) {
      return element.innerText ?? element.textContent ?? "";
    }
    return [...element.childNodes].map(child => {
      if (child.nodeType === 3) return child.textContent ?? "";
      if (child.nodeType !== 1 || !isPageContentElement(child) || elementKind(child) === "image") return "";
      const style = getComputedStyle(child);
      if (style.display === "none" || style.visibility === "hidden" || transparent(child, style)
        || isTextClipped(child, style) || (insideNavigation(child) && !insideNavigation(element))) return "";
      if (child.tagName === "BR") return "\n";
      const value = visibleControlText(child);
      return ["inline", "inline-block", "inline-flex", "contents"].includes(style.display) ? value : "\n" + value + "\n";
    }).join("");
  }

  function inlineTextWindow(runs, offset, length) {
    let position = 0;
    return runs.flatMap(part => {
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
        || elementShadowRoot(element) || element.tagName.toLowerCase() === "slot" || !(element instanceof HTMLElement)
        || element.isContentEditable || isKeypressable(element, "")
        || isScrollable(element) || element.draggable === true) continue;
      const children = Array.from(element.children);
      if (children.some((child) => !counts.has(child)
        || !["inline", "inline-block"].includes(getComputedStyle(child).display))) continue;
      const fragments = Array.from(element.childNodes).filter((node) => node.nodeType === 3)
        .map((node) => normalizedText(node.textContent ?? "")).filter(Boolean);
      // Only single-character fragments count toward a glyph run.
      const glyphFragments = fragments.filter((text) => [...text].length === 1).length;
      const count = glyphFragments + children.reduce((sum, child) => sum + counts.get(child), 0);
      counts.set(element, count);
    }
    return counts;
  }

  function visibleFragmentedText(element) {
    if (isSecureReadField(element)) return "";
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
    const element = snapshot.elementByNodeId.get(nodeId);
    if (!element?.isConnected) throw pageError("node_stale", "The snapshot node is no longer attached.");
    if (action !== "wait") {
      if (!isVisible(element)) throw pageError("node_not_visible", "The snapshot node is no longer visible.");
      const modals = snapshot.domGeneration === domGeneration ? snapshot.modals
        : composedElementWalk(document.body).elements.filter(candidate => isVisible(candidate) && isModal(candidate));
      const blocking = modals.filter(modal => isVisible(modal) && !withinElement(element, modal));
      if (blocking.length) {
        const names = blocking.map(modalName).filter(Boolean);
        throw pageError("modal_target_required", names.length
          ? `Blocked by the modal dialog ${names.map(name => `"${name}"`).join(", ")}. Nothing was sent.`
          : "Blocked by a modal dialog. Nothing was sent.");
      }
      requireEnabledNode(element, action);
    }
    if (!snapshot.actionNodeIds.get(action)?.has(nodeId)) {
      throw pageError("node_not_actionable", `The snapshot node did not advertise a ${action} action.`);
    }
    if (snapshot.domGeneration !== domGeneration) {
      const walk = composedElementWalk(document.body);
      if (walk.truncated || walk.elements.some((candidate) => isVisible(candidate) && isModal(candidate))) {
        throw pageError("snapshot_stale", "Refresh the page before acting across a modal or incomplete page boundary.");
      }
    }
    // Recheck captured identity even when shadow-root changes bypass the document observer.
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
    // Include inherited browser-disabled state as well as own and ARIA attributes.
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
    if (["img", "canvas", "svg"].includes(tag) || role === "img" || role === "graphics-document") return "image";
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
      if (style.display === "none" || style.visibility === "hidden" || transparent(current, style)) return "";
    }
    const role = element.getAttribute("role");
    if (role === "presentation" || role === "none") return "";
    const rect = element.getBoundingClientRect();
    if (rect.width <= 1 && rect.height <= 1) return "";
    if (element.tagName === "IMG" && ((element.naturalWidth === 1 && element.naturalHeight === 1)
      || (element.getAttribute("width") === "1" && element.getAttribute("height") === "1"))) return "";
    // An explicitly empty alt is decorative unless ARIA supplies its name.
    const ariaNamed = element.hasAttribute("aria-label") || element.hasAttribute("aria-labelledby");
    if (!ariaNamed && element.hasAttribute("alt") && !element.getAttribute("alt")) return "";
    // A failed image's browser replacement is not article content. An
    // authored caption is captured independently, including on its link.
    if (element.tagName === "IMG" && element.complete && element.naturalWidth === 0) return "";
    const authored = normalizedText(elementAccessibleName(element, ""));
    if (authored) return authored;
    const figure = element.closest("figure");
    const caption = figure?.querySelector("figcaption");
    const captionName = caption && isVisible(caption) ? bounded(normalizedText(snapshotText(caption)), 500) : "";
    if (captionName) return captionName;
    const nearby = [element.previousElementSibling, element.nextElementSibling]
      .find(sibling => sibling && isVisible(sibling) && !isSecureReadField(sibling) && sibling.matches("figcaption, h1, h2, h3, h4, p, [role=heading]"));
    const nearbyName = nearby ? bounded(normalizedText(snapshotText(nearby)), 500) : "";
    if (nearbyName) return nearbyName;
    return ["canvas", "svg"].includes(element.localName) ? "Unlabelled chart/graphic" : "Unlabelled image";
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
      // Use HTML's bounded positive span domain for both native and ARIA
      // cells. Page-authored fractions, infinities and unsafe integers cannot
      // become host-side counts; absent/invalid spans occupy one cell.
      const span = (value, maximum) => Number.isSafeInteger(value) && value > 0
        ? Math.min(value, maximum) : 1;
      structure.columnSpan = span(element.colSpan ?? Number(element.getAttribute("aria-colspan")), 1000);
      structure.rowSpan = span(element.rowSpan ?? Number(element.getAttribute("aria-rowspan")), 65534);
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
    if (isSecureReadField(element)) return null;
    return bounded(String(element.value ?? ""), 500);
  }

  // One read verdict for the model's snapshot and the local copy shown in Screen.
  function isSecureReadField(element) {
    const autocomplete = (element.getAttribute("autocomplete") ?? "").toLowerCase();
    return isPasswordField(element) || autocomplete.includes("password") || autocomplete.includes("cc-");
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
    if (style.display === "none" || style.visibility === "hidden" || transparent(element, style)) return false;
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0 || isTextClipped(element, style)) return false;
    for (let parent = composedParent(element); parent; parent = composedParent(parent)) {
      const parentStyle = getComputedStyle(parent);
      if (transparent(parent, parentStyle) || isTextClipped(parent, parentStyle)) return false;
    }
    return true;
  }

  // Opacity 0 held by an unfinished fade (ESPN fades its whole page in) is content appearing, not hidden: Chrome does not run
  // a hidden tab's animations, so the fade never ends there.
  function transparent(element, style) {
    if (Number(style.opacity) !== 0) return false;
    return !element.getAnimations().some(animation => animation.playState !== "finished"
      && animation.effect?.getKeyframes().some(frame => "opacity" in frame));
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

  function modalName(element) {
    const heading = [...element.querySelectorAll("h1, h2, h3, h4, h5, h6, [role=heading]")].find(isVisible);
    return bounded(normalizedText(accessibleName(element, snapshotText(heading ?? element))), 160);
  }

  // One capture-local classification serves the walk, scope and row labels.
  // Coverage is geometry, never a guess from cookie/banner words. Reading
  // behind a cover grants no action through it: modal checks stay unchanged.
  function readingOverlayOwner(embeddedOverlay = false) {
    const owners = new WeakMap();
    function owner(element) {
      if (!element) return null;
      if (owners.has(element)) return owners.get(element);
      const ancestor = composedParent(element);
      const inherited = ancestor ? owner(ancestor) : embeddedOverlay ? element : null;
      const role = element.getAttribute("role"), style = getComputedStyle(element);
      const box = element.getBoundingClientRect();
      const width = Math.max(0, Math.min(innerWidth, box.right) - Math.max(0, box.left));
      const height = Math.max(0, Math.min(innerHeight, box.bottom) - Math.max(0, box.top));
      // Scroll-locking a body's layout does not turn the whole article into
      // the dialog covering it. The embedding frame can still be an overlay.
      const covering = element !== document.body && element !== document.documentElement
        && style.position === "fixed" && width > 0 && height > 0
        && (width * height >= innerWidth * innerHeight * 0.15
          || (width >= innerWidth * 0.5 && height >= 24)
          || (height >= innerHeight * 0.5 && width >= 80));
      const result = inherited || (((covering && coversPageContent(element)) || ["dialog", "alertdialog"].includes(role)
        || element.localName === "dialog") && isVisible(element) ? element : null);
      owners.set(element, result);
      return result;
    }
    return owner;
  }

  function coversPageContent(element) {
    const box = element.getBoundingClientRect();
    const left = Math.max(0, box.left), right = Math.min(innerWidth, box.right);
    const top = Math.max(0, box.top), bottom = Math.min(innerHeight, box.bottom);
    const root = element.getRootNode();
    // A fixed feed can be the page's layout. It is a cover only when the
    // browser's actual stack exposes other page content underneath it.
    return [0.25, 0.5, 0.75].some(fraction => {
      const x = left + (right - left) * fraction, y = top + (bottom - top) * fraction;
      const stack = root.elementsFromPoint(x, y);
      const cover = stack.findIndex(candidate => withinElement(candidate, element));
      return cover >= 0 && stack.slice(cover + 1).some(candidate => candidate !== document.body
        && candidate !== document.documentElement && !withinElement(candidate, element) && !withinElement(element, candidate)
        && !insideNavigation(candidate) && !inPageChrome(candidate) && isVisible(candidate)
        && (elementShadowRoot(candidate) || normalizedText(snapshotText(candidate))));
    });
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
    return ["text", "search", "email", "url", "tel", "number", "date", "datetime-local", "month", "time", "week", "color", "range", "file"].includes(type);
  }

  function isSequentialEditable(element) {
    if (!isEditable(element)) return false;
    return element.isContentEditable || element.tagName.toLowerCase() === "textarea"
      || ["text", "search", "email", "url", "tel", "number"].includes(element.type);
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
    if (tag === "input" && isEditable(element) && !isSequentialEditable(element)) return false;
    return isEditable(element) || isSelectable(element) || isClickable(element, role)
      || element.tabIndex >= 0 || ["combobox", "listbox", "option"].includes(role);
  }

  function isPasswordField(element) {
    return element.tagName.toLowerCase() === "input" && element.type?.toLowerCase() === "password";
  }

  function focusWithoutActivation(element) {
    if (typeof element.focus !== "function") throw pageError("focus_unavailable", "The target cannot take focus.");
    try { element.focus({ preventScroll: true }); }
    catch { throw pageError("focus_failed", "Chrome refused focus on the exact target; no keys or text were sent."); }
  }

  // Read retained field content; attempted character counts do not prove retention.
  function readEditableValue(element) {
    if (element.isContentEditable) return String(element.innerText);
    return String(element.value ?? "");
  }

  function setNativeValue(element, value) {
    const prototype = element instanceof HTMLInputElement ? HTMLInputElement.prototype
      : element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLSelectElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
    if (!setter) throw pageError("value_setter_unavailable", "The native control has no value setter.");
    setter.call(element, value);
  }

  function dispatchEditableEvent(element, type) {
    element.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
  }

  function checkedState(element) {
    if (typeof element.checked === "boolean" && isNativeCheckable(element)) return element.checked;
    return nullableAriaBoolean(element.getAttribute("aria-checked"));
  }

  function readingViewport(target) {
    const box = target === window ? null : target.getBoundingClientRect();
    return {
      left: box ? Math.max(0, box.left + target.clientLeft) : 0,
      top: box ? Math.max(0, box.top + target.clientTop) : 0,
      right: box ? Math.min(window.innerWidth, box.left + target.clientLeft + target.clientWidth) : window.innerWidth,
      bottom: box ? Math.min(window.innerHeight, box.top + target.clientTop + target.clientHeight) : window.innerHeight,
      scrollX: finite(target === window ? window.scrollX : target.scrollLeft),
      scrollY: finite(target === window ? window.scrollY : target.scrollTop),
    };
  }

  function compareReadingPosition(left, right) {
    const layer = Number(left.overlay === true) - Number(right.overlay === true);
    if (layer) return layer;
    for (let index = 0; index < Math.min(left.flow.length, right.flow.length); index++) {
      const difference = left.flow[index] - right.flow[index];
      if (difference) return difference;
    }
    return left.flow.length - right.flow.length || left.ordinal - right.ordinal;
  }

  function readingAnchorKey(element) {
    return contentKey(snapshotText(element) + "\n" + (safeURL(element) ?? ""));
  }

  function readingAnchor(element) {
    if (!elementIdentities.has(element)) elementIdentities.set(element, crypto.randomUUID());
    return { identity: elementIdentities.get(element), key: readingAnchorKey(element) };
  }

  // Expand the nearest layout branches first. Offscreen feed rows cannot
  // exhaust the walk before the viewport is reached. On continuation, the
  // already-read prefix does not spend the next window's walk budget. Still
  // descend through it: overflowing children can occupy an unread position.
  function readingElementWalk(roots, target, maximum = 5_000, startPosition = null, overlayFor = () => null) {
    const view = readingViewport(target), heap = [], entries = [], shadowRoots = [];
    const seen = new Set(), coincident = new Map(), positions = new Map();
    let sequence = 0;
    const geometry = box => ({
      distance: Math.max(0, view.top - box.bottom, box.top - view.bottom)
        + Math.max(0, view.left - box.right, box.left - view.right),
      y: finite(box.top - view.top + view.scrollY), x: finite(box.left - view.left + view.scrollX),
    });
    const columnPrefix = readingColumnPrefixes(geometry, overlayFor);
    const position = element => {
      const place = geometry(element.getBoundingClientRect());
      const complementary = insideNavigation(element) || inPageChrome(element);
      return { scrollX: view.scrollX, scrollY: view.scrollY,
        ...(overlayFor(element) ? { overlay: true } : {}),
        ...(complementary ? { complementary: true } : {}),
        ...place, flow: [...columnPrefix(element), Number(complementary), place.distance, place.y, place.x], ordinal: 0 };
    };
    const compare = (a, b) => compareReadingPosition(a.position, b.position) || a.order - b.order;
    const offer = element => {
      if (!element || seen.has(element)) return;
      seen.add(element);
      const entry = { element, position: position(element), order: sequence++ };
      let index = heap.length;
      heap.push(entry);
      while (index > 0) {
        const parent = (index - 1) >> 1;
        if (compare(heap[parent], entry) <= 0) break;
        heap[index] = heap[parent]; index = parent;
      }
      heap[index] = entry;
    };
    const take = () => {
      const first = heap[0], tail = heap.pop();
      if (heap.length) {
        let index = 0;
        while (index * 2 + 1 < heap.length) {
          let child = index * 2 + 1;
          if (child + 1 < heap.length && compare(heap[child + 1], heap[child]) < 0) child++;
          if (compare(tail, heap[child]) <= 0) break;
          heap[index] = heap[child]; index = child;
        }
        heap[index] = tail;
      }
      return first;
    };
    roots.forEach(offer);
    let next = null;
    while (heap.length) {
      const entry = take(), element = entry.element;
      const key = [entry.position.overlay === true, entry.position.complementary === true,
        ...entry.position.flow].join(":");
      entry.position.ordinal = coincident.get(key) ?? 0;
      coincident.set(key, entry.position.ordinal + 1);
      if (!startPosition || compareReadingPosition(entry.position, startPosition) >= 0) {
        positions.set(element, entry.position);
        if (entries.length >= maximum) { next = entry; break; }
        entries.push(entry);
      }
      if (!isPageContentElement(element) || elementKind(element) === "image") continue;
      const shadow = elementShadowRoot(element);
      if (shadow) {
        shadowRoots.push(shadow);
        Array.from(shadow.children).forEach(offer);
      }
      Array.from(element.children ?? []).forEach(offer);
    }
    entries.sort(compare);
    return { elements: entries.map(entry => entry.element),
      positions, shadowRoots, truncated: Boolean(next), nextElement: next?.element, sectionName: "" };
  }

  // Geometry identifies sibling columns, not site names or landmark roles.
  // Their shared place in the page precedes the prose-ranked column and its
  // own positions. That same key travels with a fold, so more finishes a
  // column rather than returning to rows beside it at the same height.
  function readingColumnPrefixes(geometry, overlayFor) {
    const prefixes = new WeakMap(), groups = new WeakMap(), prose = new WeakMap();
    function proseSize(root) {
      if (prose.has(root)) return prose.get(root);
      const stack = [root];
      let size = 0, visited = 0;
      while (stack.length && visited++ < 2_000 && size < 32_000) {
        const element = stack.pop();
        if (!isPageContentElement(element) || overlayFor(element) || element.matches("nav, [role=navigation]")
          || inPageChrome(element) || isSecureReadField(element)) continue;
        if (isVisible(element)) for (const node of element.childNodes) {
          if (node.nodeType === 3 && !isReadinessControlText(node, { includeComplementary: false })) size += normalizedText(node.textContent ?? "").length;
        }
        stack.push(...Array.from(element.children), ...Array.from(elementShadowRoot(element)?.children ?? []));
      }
      prose.set(root, size);
      return size;
    }
    function columns(parent) {
      if (groups.has(parent)) return groups.get(parent);
      const children = [...Array.from(parent.children ?? []), ...Array.from(elementShadowRoot(parent)?.children ?? [])];
      const candidates = children.filter(element => !overlayFor(element) && isVisible(element))
        .map(element => ({ element, box: element.getBoundingClientRect() }))
        .filter(({ box }) => box.width >= 80 && box.height >= 120);
      const ranks = new Map(), remaining = new Set(candidates);
      // A long, vertically stacked list shares one horizontal strip and has
      // no beside pair. Establish that in one pass before considering pairs.
      if (candidates.length < 2 || Math.max(...candidates.map(item => item.box.left)) + 4
        < Math.min(...candidates.map(item => item.box.right))) {
        groups.set(parent, ranks);
        return ranks;
      }
      const beside = (a, b) => (a.box.right <= b.box.left + 4 || b.box.right <= a.box.left + 4)
        && Math.min(a.box.bottom, b.box.bottom) - Math.max(a.box.top, b.box.top)
          >= Math.max(80, Math.min(a.box.height, b.box.height) * 0.5);
      for (const first of candidates) {
        if (!remaining.delete(first)) continue;
        const group = [first];
        for (let index = 0; index < group.length; index++) for (const other of remaining) {
          if (beside(group[index], other)) { remaining.delete(other); group.push(other); }
        }
        if (group.length < 2) continue;
        const box = { left: Math.min(...group.map(item => item.box.left)), right: Math.max(...group.map(item => item.box.right)),
          top: Math.min(...group.map(item => item.box.top)), bottom: Math.max(...group.map(item => item.box.bottom)) };
        const place = geometry(box);
        // Vertically stacked siblings beside one rail are one column, too.
        const lanes = [];
        for (const item of group.sort((a, b) => a.box.left - b.box.left)) {
          let lane = lanes.find(lane => Math.min(lane.right, item.box.right) - Math.max(lane.left, item.box.left)
            >= Math.min(lane.right - lane.left, item.box.width) * 0.5);
          if (!lane) { lane = { left: item.box.left, right: item.box.right, items: [], prose: 0 }; lanes.push(lane); }
          lane.items.push(item); lane.prose += proseSize(item.element);
          lane.left = Math.min(lane.left, item.box.left); lane.right = Math.max(lane.right, item.box.right);
        }
        lanes.sort((a, b) => b.prose - a.prose || a.left - b.left);
        lanes.forEach((lane, rank) => lane.items.forEach(({ element }) => ranks.set(element, [0, place.distance, place.y, place.x, rank])));
      }
      groups.set(parent, ranks);
      return ranks;
    }
    return function prefix(element) {
      if (prefixes.has(element)) return prefixes.get(element);
      const parent = composedParent(element);
      const value = parent ? [...prefix(parent), ...(columns(parent).get(element) ?? [])] : [];
      prefixes.set(element, value);
      return value;
    };
  }

  function composedElementWalk(root, maximum = 5_000) {
    if (!root) return { elements: [], truncated: false, shadowRoots: [] };
    const result = [];
    const shadowRoots = [];
    const stack = Array.from(root.children ?? []).reverse();
    while (stack.length > 0 && result.length < maximum) {
      const element = stack.pop();
      if (!isPageContentElement(element)) continue;
      result.push(element);
      const shadow = elementShadowRoot(element);
      if (shadow) shadowRoots.push(shadow);
      const descendants = [
        ...Array.from(shadow?.children ?? []),
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

  // Web components' closed roots contain rendered content just like open roots.
  function elementShadowRoot(element) {
    return element instanceof HTMLElement ? chrome.dom.openOrClosedShadowRoot(element) : null;
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
      // Most of the read's transport went on this URL repeated at every depth, three times a node: X's text stopped at 8 KB of a 1 MB read.
      const space = current.namespaceURI === "http://www.w3.org/1999/xhtml" ? "" : `${encodeURIComponent(current.namespaceURI ?? "")}:`;
      parts.unshift(`${space}${encodeURIComponent(current.localName)}[${ordinal}]`);
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

  function stopRun(run, reason) {
    run.stopReason = reason;
    run.wake?.();
  }

  function delay(milliseconds, run) {
    return new Promise((resolve) => {
      const finish = () => {
        clearTimeout(timer);
        if (run?.wake === finish) run.wake = null;
        resolve();
      };
      const timer = setTimeout(finish, milliseconds);
      if (run) { run.wake = finish; if (run.stopReason) finish(); }
    });
  }

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
