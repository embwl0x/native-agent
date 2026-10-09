import { BrowserWorkspace } from "./browser-workspace.js";
import {
  ACTIONS,
  HOST_ID,
  PROTOCOL_VERSION,
  ProtocolError,
  errorResponse,
  eventEnvelope,
  successResponse,
  validateRequest,
} from "./protocol.js";

let nativePort = null;
let nativeReady = false;
let reloadingExtension = false;
let nativeRequestsInFlight = 0;
let lastExtensionError = null;
const NATIVE_ERROR_STORAGE_KEY = "nativeAgentLastExtensionErrorV1";
const nativeErrorsReady = chrome.storage.local.get(NATIVE_ERROR_STORAGE_KEY).then((stored) => {
  const error = stored[NATIVE_ERROR_STORAGE_KEY];
  if (!lastExtensionError && typeof error?.message === "string" && typeof error?.at === "string") {
    lastExtensionError = error;
  }
}).catch((error) => console.error("NativeAgent Chrome error history could not be read:", error));
let nativeErrorWrites = nativeErrorsReady;
let reconnectAlarmChanges = Promise.resolve();
const NATIVE_RECONNECT_ALARM = "nativeagent.native-reconnect";
const MAX_SNAPSHOT_FRAMES = 64;
// The relay admits at most 1,048,576 UTF-8 bytes including the response
// envelope. Reserve headroom rather than relying on character/node counts.
const MAX_SNAPSHOT_RESULT_BYTES = 1_000_000;
const PAGE_CHANGE_STORAGE_KEY = "nativeAgentPageChangeGenerationsV1";
const PAGE_VIEW_STORAGE_KEY = "nativeAgentPageSnapshotViewsV1";
const utf8Encoder = new TextEncoder();
const snapshotRoutes = new Map();
const activeSnapshotReads = new Map();
const activeNavigations = new Map();
const activePageActions = new Map();
const cancelledRequests = new Set();
const activeTabWaits = new Map();
// Worker-side waits by request, so the request's action.cancel ends them.
const activeRequestWaits = new Map();
const pageChangeStreams = new Map();
const pageChangeGenerations = new Map();
const pageSnapshotViews = new Map();
// Actual document edges, never a retry clock. A frame's old ready signal
// cannot authorize a capture of its replacement document.
const readyPageFrames = new Map();
let generationWrites = Promise.resolve();
let viewWrites = Promise.resolve();
const workspace = new BrowserWorkspace(chrome, tabOwnershipEnded, tabs => sendEvent("tabs.changed", { tabs }));
const tabsReady = workspace.refresh();
const changesReady = tabsReady.then(async () => {
  const stored = await chrome.storage.session.get([PAGE_CHANGE_STORAGE_KEY, PAGE_VIEW_STORAGE_KEY]);
  for (const [id, generation] of Object.entries(stored[PAGE_CHANGE_STORAGE_KEY] ?? {})) {
    if (workspace.tabs.has(Number(id)) && Number.isSafeInteger(generation) && generation >= 0) {
      pageChangeGenerations.set(Number(id), generation);
    }
  }
  for (const [id, view] of Object.entries(stored[PAGE_VIEW_STORAGE_KEY] ?? {})) {
    if (workspace.tabs.has(Number(id))) pageSnapshotViews.set(Number(id), view);
  }
});

chrome.runtime.onStartup.addListener(connectNativeHost);
chrome.runtime.onInstalled.addListener(connectNativeHost);

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type === "nativeagent.page.ready" && Number.isInteger(sender.tab?.id) && Number.isInteger(sender.frameId)) {
    void changesReady.then(async () => {
      if (!await acceptPageReady(sender.tab.id, sender.frameId, sender.documentId, message.url)) return;
      const ownedTab = workspace.tabForId(sender.tab.id);
      if (ownedTab) {
        const view = pageSnapshotViews.get(ownedTab.tabId);
        if (view?.readCursor && (sender.frameId === 0 || sender.frameId === view.readCursor.frameId)) {
          // Document replacement has a new reading origin, not the old scroll.
          const { readCursor: _oldViewport, ...documentView } = view;
          pageSnapshotViews.set(ownedTab.tabId, documentView);
          persistPageViews(ownedTab);
        }
        await observeOwnedPage(ownedTab, sender.frameId, { documentId: sender.documentId });
        queueSiteChange({ tabId: ownedTab.tabId, userSequence: ownedTab.userSequence }, sender);
      }
    }).catch((error) => reportPageObservationFailure(sender.tab.id, error));
    return;
  }
  if (message?.type === "nativeagent.page.changed" && Number.isInteger(sender.tab?.id) && Number.isInteger(sender.frameId)) {
    void changesReady.then(() => queueSiteChange(message, sender)).catch(() => {});
    return;
  }
  if (message?.type === "nativeagent.page.mutated" && Number.isInteger(sender.frameId)) {
    invalidateFrameSnapshots(sender.tab?.id, sender.frameId, message.snapshotIds, message.retainedNavigationNodes);
    return;
  }
  if (message?.type !== "nativeagent.user-touch" || !Number.isInteger(sender.tab?.id)) return;
  void workspace.yieldForTab(sender.tab.id, `user_${message.kind ?? "input"}`).catch(recordOwnershipFailure);
});

chrome.tabs.onActivated.addListener(({ tabId }) => {
  void workspace.yieldForTab(tabId, "tab_activated").catch(recordOwnershipFailure);
});
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  workspace.tabUpdated(tabId, change, tab);
  if (change.groupId !== undefined) void workspace.refresh().catch(recordOwnershipFailure);
});
chrome.tabGroups.onUpdated.addListener(group => {
  workspace.groupUpdated(group);
  void workspace.refresh().catch(recordOwnershipFailure);
});
chrome.tabGroups.onRemoved.addListener(group => workspace.groupRemoved(group));
chrome.tabs.onRemoved.addListener((tabId) => {
  readyPageFrames.delete(tabId);
  const owned = workspace.tabForId(tabId) !== undefined;
  workspace.tabRemoved(tabId);
  if (owned) sendEvent("tab.closed", { tabId });
});
chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  readyPageFrames.delete(removedTabId);
  workspace.tabRemoved(removedTabId);
  void workspace.refresh().then(async () => {
    const tab = workspace.tabForId(addedTabId);
    if (tab) await observeOwnedPage(tab, 0);
  }).catch(recordOwnershipFailure);
});

chrome.webNavigation.onCommitted.addListener(({ tabId, frameId, url, transitionQualifiers }) => {
  if (frameId === 0) {
    // Chrome supplies actual omnibox navigation evidence. It is user
    // custody even if the already-active tab emitted no activation event.
    const userNavigation = transitionQualifiers?.includes("from_address_bar") === true;
    if (userNavigation) void workspace.yieldForTab(tabId, "user_navigation").catch(recordOwnershipFailure);
    readyPageFrames.delete(tabId);
    // A new document: waits on the old document's frames no longer apply.
    const stream = pageChangeStreams.get(tabId);
    if (stream) stream.waitingFrameId = undefined;
    invalidateTabSnapshots(tabId);
  } else {
    // An ad or tracker iframe loading replaces only that frame's rows.
    readyPageFrames.get(tabId)?.delete(frameId);
    invalidateSubframeSnapshots(tabId, frameId);
  }
  const ownedTab = workspace.tabForId(tabId);
  if (!ownedTab) return;
  const view = pageSnapshotViews.get(ownedTab.tabId);
  if (view?.readCursor && (frameId === 0 || frameId === view.readCursor.frameId)) {
    const { readCursor: _oldCursor, ...documentView } = view;
    pageSnapshotViews.set(ownedTab.tabId, documentView);
    persistPageViews(ownedTab);
  }
  queueSiteChange({ tabId: ownedTab.tabId, userSequence: ownedTab.userSequence }, { tab: { id: tabId }, frameId });
});

chrome.webNavigation.onCompleted.addListener(({ tabId, frameId, documentId, url }) => {
  void changesReady.then(async () => {
    if (!await acceptPageReady(tabId, frameId, documentId, url)) return;
    const ownedTab = workspace.tabForId(tabId);
    if (ownedTab) {
      await observeOwnedPage(ownedTab, frameId, { documentId });
      queueSiteChange({ tabId: ownedTab.tabId, userSequence: ownedTab.userSequence }, { tab: { id: tabId }, frameId });
    }
  }).catch((error) => reportPageObservationFailure(tabId, error));
});

chrome.webNavigation.onHistoryStateUpdated.addListener(({ tabId, frameId }) => {
  void changesReady.then(() => {
    const ownedTab = workspace.tabForId(tabId);
    if (ownedTab) queueSiteChange({ tabId: ownedTab.tabId, userSequence: ownedTab.userSequence }, { tab: { id: tabId }, frameId });
  }).catch((error) => reportPageObservationFailure(tabId, error));
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === NATIVE_RECONNECT_ALARM) {
    // A Port object is not evidence that the app accepted it. A write also
    // exposes a disconnected Port even if its disconnect callback is pending.
    if (nativePort && !nativeReady) {
      postNativeMessage(nativePort, eventEnvelope("extension.connecting", {
        extensionVersion: chrome.runtime.getManifest().version,
      }));
    }
    connectNativeHost();
    return;
  }

});

// Restore input listeners even when the app is absent after extension reload.
const readersReady = changesReady.then(installPageReaders);
void readersReady.catch(recordOwnershipFailure);

// Run on every worker evaluation (including Reload), after listeners exist.
// Alarms belong to Chrome, not to this worker's in-memory lifetime.
connectNativeHost();

function connectNativeHost() {
  reconcileNativeReconnectAlarm();
  if (nativePort) return;
  try {
    const port = chrome.runtime.connectNative(HOST_ID);
    nativePort = port;
    port.onMessage.addListener((message) => void handleNativeMessage(message, port));
    port.onDisconnect.addListener(() => {
      // lastError exists only inside this callback. Retain it before returning.
      const error = chrome.runtime.lastError?.message;
      if (error) recordNativeError(error);
      const reason = error ?? "The native host disconnected.";
      retireNativePort(port, reason);
    });
  } catch (error) {
    recordNativeError(error.message ?? String(error));
    console.warn("NativeAgent Chrome connection failed:", error);
    nativePort = null;
    nativeReady = false;
    reconcileNativeReconnectAlarm();
  }
}

function recordNativeError(message) {
  const error = { message: String(message).slice(0, 1_024), at: new Date().toISOString() };
  lastExtensionError = error;
  nativeErrorWrites = nativeErrorWrites.then(() => chrome.storage.local.set({
    [NATIVE_ERROR_STORAGE_KEY]: error,
  })).catch((failure) => console.error("NativeAgent Chrome error history could not be saved:", failure));
}

function reconcileNativeReconnectAlarm() {
  // Serialize clear/create so a late clear cannot erase recovery after an
  // immediate host failure. Do not move an existing alarm's due time on wake.
  reconnectAlarmChanges = reconnectAlarmChanges.then(async () => {
    if (nativeReady) {
      await chrome.alarms.clear(NATIVE_RECONNECT_ALARM);
    } else {
      const alarm = await chrome.alarms.get(NATIVE_RECONNECT_ALARM);
      if (alarm?.periodInMinutes !== 0.5) {
        await chrome.alarms.create(NATIVE_RECONNECT_ALARM, {
          delayInMinutes: 0.5,
          periodInMinutes: 0.5,
        });
      }
    }
  }).catch((error) => console.error("NativeAgent Chrome reconnect alarm failed:", error));
}

function retireNativePort(port, reason) {
  if (nativePort !== port) return;
  nativePort = null;
  nativeReady = false;
  console.warn("NativeAgent Chrome connection ended:", reason);
  port.disconnect();
  reconcileNativeReconnectAlarm();
}

function postNativeMessage(port, message) {
  if (nativePort !== port) return false;
  try {
    port.postMessage(message);
    return true;
  } catch (error) {
    recordNativeError(error.message ?? String(error));
    retireNativePort(port, error.message ?? String(error));
    return false;
  }
}

async function handleNativeMessage(rawRequest, port) {
  if (rawRequest?.type === "event" && rawRequest.event === "action.cancel") {
    const requestId = rawRequest.payload?.requestId;
    if (nativePort !== port || typeof requestId !== "string" || !/^[A-Za-z0-9._:-]{1,128}$/.test(requestId)) return;
    cancelledRequests.add(requestId);
    if (cancelledRequests.size > 128) cancelledRequests.delete(cancelledRequests.values().next().value);
    activeRequestWaits.get(requestId)?.(new ProtocolError("action_cancelled", "The Chrome action was cancelled."));
    for (const [id, tabId] of activePageActions) {
      if (id !== requestId) continue;
      try {
        await workspace.requireTab(tabId);
        await chrome.tabs.sendMessage(tabId, { type: "nativeagent.page.action.cancel", requestId });
      } catch { /* User takeover already stops every local action. */ }
    }
    return;
  }
  let request = rawRequest;
  let requestValidated = false;
  let reloadStarted = false;
  let mutationTabId;
  nativeRequestsInFlight += 1;
  try {
    request = validateRequest(rawRequest);
    requestValidated = true;
    if (reloadingExtension) throw new ProtocolError("extension_reloading", "The extension is reloading; wait for its accepted connection.");
    if (request.action === "extension.reload" && nativeRequestsInFlight > 1) {
      throw new ProtocolError("extension_busy", "A Chrome request is still progressing; reload was not started. Call chrome.reload_extension when it finishes.");
    }
    await tabsReady;
    if (request.action.startsWith("page.") && request.action !== "page.snapshot.read") {
      const ownedTab = await workspace.requireForPageAction(request.payload);
      mutationTabId = ownedTab.tabId;
      activePageActions.set(request.id, mutationTabId);
    }
    if (cancelledRequests.has(request.id)) throw new ProtocolError("action_cancelled", "The Chrome action was cancelled before dispatch.");
    reloadStarted = request.action === "extension.reload";
    if (reloadStarted) reloadingExtension = true;
    const result = await dispatch(request);
    if (postNativeMessage(port, successResponse(request, result))) {
      if (request.action === "attach") {
        nativeReady = true;
        reconcileNativeReconnectAlarm();
      } else if (request.action === "extension.reload") {
        // The acknowledgement is queued first. Reload changes no tab/window.
        chrome.runtime.reload();
      }
    } else if (request.action === "extension.reload") {
      reloadingExtension = false;

    }
  } catch (error) {
    if (requestValidated && request?.action === "extension.reload") {
      if (reloadStarted) {
        reloadingExtension = false;

      }
      recordNativeError(`Extension reload failed: ${error.message ?? String(error)}`);
      sendEvent("extension.reload_failed", { reloadId: request.payload?.reloadId,
        reason: error.message ?? String(error) });
    }
    postNativeMessage(port, errorResponse(request, error));
  } finally {
    if (mutationTabId !== undefined) activePageActions.delete(request?.id);
    cancelledRequests.delete(request?.id);
    nativeRequestsInFlight -= 1;
  }
}

async function dispatch(request) {
  await changesReady;
  switch (request.action) {
    case "attach":
      await nativeErrorWrites;
      await workspace.refresh();
      // Reload invalidates content contexts, so install the existing readers
      // in owned documents. Group membership, not saved handoffs, owns tabs.
      await readersReady;
      return {
        hostId: HOST_ID, protocolVersion: PROTOCOL_VERSION,
        extensionVersion: chrome.runtime.getManifest().version,
        extensionId: chrome.runtime.id, connected: true,
        tabs: [...workspace.tabs.values()].map(tab => ({ ...tab })),
        lastExtensionError, capabilities: ACTIONS,
      };
    case "extension.reload":
      return {
        reloadId: request.payload.reloadId, beforeVersion: chrome.runtime.getManifest().version,
        status: "acknowledged",
      };
    case "tab.close":
      return workspace.closeTab(request.payload);
    case "navigate":
      return navigateOwnedTab(request.payload, request.id);
    case "page.snapshot.read":
      return readStructuredSnapshot(request.payload);
    case "page.element.click":
      return clickSnapshotNode(request.payload, request.id);
    case "page.element.fill":
      return fillSnapshotNode(request.payload, request.id);
    case "page.element.type":
      return typeIntoSnapshotNode(request.payload, request.id);
    case "page.element.select":
      return selectSnapshotNode(request.payload, request.id);
    case "page.element.keypress":
      return keypressSnapshotNode(request.payload, request.id);
    case "page.element.set_checked":
      return setCheckedSnapshotNode(request.payload, request.id);
    case "page.element.double_click":
      return doubleClickSnapshotNode(request.payload, request.id);
    case "page.element.drag":
      return dragSnapshotNode(request.payload, request.id);
    case "page.wait":
      return waitForPage(request.payload, request.id);
    case "page.scroll":
      return scrollPage(request.payload, request.id);
    case "page.media": {
      const ownedTab = await workspace.requireForPageAction(request.payload);
      return performSnapshotMutation({ ownedTab, route: { frameId: 0 }, payload: request.payload,
        actionId: request.id, action: "media",
        pageMessage: { type: "nativeagent.page.media", operation: request.payload.operation, seconds: request.payload.seconds } });
    }
    default:
      throw new ProtocolError("unknown_action", `Unknown action '${request.action}'.`);
  }
}

async function navigateOwnedTab(payload, actionId) {
  let ownedTab;
  if (payload.tabId !== undefined) {
    try { ownedTab = await workspace.requireForPageAction(payload); }
    catch (error) { if (error.code !== "tab_not_owned") throw error; }
  }
  if (!ownedTab) {
    if (payload.url === "back" || payload.url === "forward") {
      throw new ProtocolError("tab_not_owned", "Back and forward require one of your NativeAgent tabs.");
    }
    ownedTab = await workspace.createTab();
    payload = { ...payload, tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence };
  }
  invalidateTabSnapshots(ownedTab.tabId);
  cancelTabWaits(ownedTab.tabId, new ProtocolError("navigation_superseded", "A newer navigation superseded the pending observation."));
  const navigation = {};
  activeNavigations.set(ownedTab.tabId, navigation);
  const startedAt = new Date().toISOString();
  let topDocument;
  async function requireCurrentNavigation() {
    await workspace.requireForPageAction(payload);
    if (activeNavigations.get(ownedTab.tabId) !== navigation) {
      throw new ProtocolError("navigation_superseded", "A newer navigation or user takeover superseded this request.");
    }
  }
  try {
    // "back" / "forward": the tab's own history, as a person's Back button.
    const history = payload.url === "back" ? (id) => chrome.tabs.goBack(id)
      : payload.url === "forward" ? (id) => chrome.tabs.goForward(id) : null;
    await requireCurrentNavigation();
    // Watch before dispatch, so a fast commit is not missed.
    topDocument = watchTopDocument(ownedTab.tabId);
    const updated = history
      ? await history(ownedTab.tabId).catch(async () => {
        await requireCurrentNavigation(); // a newer navigation owns the tab now: step nothing
        return pageHistoryStep(ownedTab.tabId, payload.url === "back" ? -1 : 1);
      })
        .then(() => chrome.tabs.get(ownedTab.tabId))
      : await chrome.tabs.update(ownedTab.tabId, { url: payload.url });
    await requireCurrentNavigation();
    if (updated?.active === true) {
      await workspace.yieldForTab(ownedTab.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "Navigation unexpectedly activated the NativeAgent tab.");
    }
    // 2026-09-22: under the app's 30s request timeout so the result arrives.
    // Done when the new document's content is parsed, not when every ad loads.
    await waitForTabComplete(ownedTab.tabId, 25_000, requireCurrentNavigation, topDocument);
    const tab = await chrome.tabs.get(ownedTab.tabId);
    await requireCurrentNavigation();
    if (tab.active === true) {
      await workspace.yieldForTab(ownedTab.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "The tab became active before navigation could be confirmed.");
    }
    if (tab.id !== ownedTab.tabId || tab.pendingUrl || typeof tab.url !== "string") {
      throw new ProtocolError("navigation_changed", "The exact tab no longer has an observed loaded page.");
    }
    return pageActionResult({
      actionId, action: "navigate", ownedTab, payload, startedAt,
      outcome: "succeeded", verification: "not_verified",
      detail: {
        tabId: ownedTab.tabId, requestedUrl: payload.url,
        url: tab.url, title: tab.title ?? "", status: tab.status, verified: false,
      },
    });
  } catch (error) {
    // tabs.update has already been dispatched. Lost ownership or observation
    // cannot prove that navigation did not happen, so never invite blind replay.
    return pageActionResult({
      actionId, action: "navigate", ownedTab, payload, startedAt,
      outcome: "outcome_unknown", verification: "outcome_unknown",
      detail: {
        tabId: ownedTab.tabId, requestedUrl: payload.url,
        status: "outcome_unknown", verified: false,
        error: { code: error.code ?? "navigation_reply_lost", message: error.message ?? "Chrome navigation could not be confirmed." },
      },
    });
  } finally {
    topDocument?.stop();
    if (activeNavigations.get(ownedTab.tabId) === navigation) activeNavigations.delete(ownedTab.tabId);
    void drainSiteChanges(ownedTab.tabId);
  }
}

async function readStructuredSnapshot(payload) {
  const ownedTab = await workspace.requireForPageAction(payload);
  payload = { ...pageSnapshotViews.get(ownedTab.tabId), ...payload };
  invalidateTabSnapshots(ownedTab.tabId);
  const capture = { localSnapshotKeys: new Set(), invalidatedSnapshotKeys: new Set(), invalidationOverflow: false };
  activeSnapshotReads.set(ownedTab.tabId, capture);
  try {
    const snapshot = await readStructuredSnapshotForCapture(payload, ownedTab, capture);
    pageSnapshotViews.set(ownedTab.tabId, {
      maxNodes: payload.maxNodes ?? 120, maxTextChars: payload.maxTextChars ?? 12_000,
      scope: payload.scope ?? "page",
      ...(payload.readCursor?.viewportObservationId ? { readCursor: payload.readCursor } : {}),
    });
    // Retain the successful reader's exact view durably before its reply,
    // without another page read. Writes serialize across tabs.
    await persistPageViews(ownedTab);
    return snapshot;
  } finally {
    if (activeSnapshotReads.get(ownedTab.tabId) === capture) activeSnapshotReads.delete(ownedTab.tabId);
    void drainSiteChanges(ownedTab.tabId);
  }
}

function persistPageViews(ownedTab) {
  viewWrites = viewWrites.catch(() => {}).then(() => chrome.storage.session.set({
    [PAGE_VIEW_STORAGE_KEY]: Object.fromEntries([...pageSnapshotViews]
      .filter(([id]) => workspace.tabs.has(id))),
  }));
  void viewWrites.catch((error) => sendEvent("page.change_unavailable", {
    tabId: ownedTab.tabId, userSequence: ownedTab.userSequence,
    error: { code: "page_view_persistence_failed", message: String(error.message ?? "The page change view could not be retained.").slice(0, 1_024) },
  }));
  return viewWrites;
}

async function requireCurrentSnapshotCapture(ownedTab, capture) {
  await workspace.requireForPageAction({ tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence });
  if (activeSnapshotReads.get(ownedTab.tabId) !== capture) {
    throw new ProtocolError("snapshot_superseded", "A newer read or navigation superseded this snapshot capture.");
  }
  if (capture.invalidationOverflow || [...capture.localSnapshotKeys].some((key) => capture.invalidatedSnapshotKeys.has(key))) {
    throw new ProtocolError("snapshot_stale", "A captured frame changed while the combined snapshot was being read.");
  }
}

async function readStructuredSnapshotForCapture(payload, ownedTab, capture) {
  // 2026-09-22: was 500 / 50,000; a quarter of snapshots overran the 48KB tool-result cap.
  const maxNodes = payload.maxNodes ?? 120;
  const maxTextChars = payload.maxTextChars ?? 12_000;
  const discovered = await chrome.webNavigation.getAllFrames({ tabId: ownedTab.tabId });
  await requireCurrentSnapshotCapture(ownedTab, capture);
  const ordered = [...(discovered ?? [])].sort((left, right) => {
    if (left.frameId === 0) return -1;
    if (right.frameId === 0) return 1;
    return left.frameId - right.frameId;
  });
  const cursorFrame = payload.readCursor?.frameId ?? 0;
  if (payload.readCursor && !ordered.some(frame => frame.frameId === cursorFrame)) throw new ProtocolError("read_address_missing", "The folded frame is no longer on this page.");
  const frames = [];
  const localSnapshots = [];
  let remainingNodes = maxNodes;
  let remainingText = maxTextChars;
  let topSnapshot = null;
  let readMore = null;
  let truncationReasonsForFrames = false;

  for (const frame of ordered) {
    if (payload.readCursor && frame.frameId !== 0 && ordered.findIndex(f => f.frameId === frame.frameId) < ordered.findIndex(f => f.frameId === cursorFrame)) continue;
    await requireCurrentSnapshotCapture(ownedTab, capture);
    if (remainingNodes <= 0) {
      frames.push({
        frameId: frame.frameId,
        parentFrameId: frame.parentFrameId,
        url: frame.url ?? "",
        name: "",
        accessible: false,
        nodeCount: 0,
        error: { code: "frame_budget_exhausted", message: "The global node budget was exhausted before this frame." },
      });
      continue;
    }
    if (capture.passive && /^https?:/.test(frame.url ?? "")) {
      const ready = readyPageFrames.get(ownedTab.tabId)?.get(frame.frameId);
      if (!ready || (frame.documentId && ready.documentId !== frame.documentId)) {
        throw new ProtocolError("page_agent_loading", "The HTTP(S) page agent is still loading or injecting. A read will work once the page is ready.", { frameId: frame.frameId });
      }
    }
    let local;
    try {
      local = await sendPageMessage(ownedTab.tabId, {
        type: "nativeagent.page.snapshot",
        tabId: ownedTab.tabId,
        userSequence: ownedTab.userSequence,
        passive: capture.passive === true,
        maxNodes: remainingNodes,
        maxTextChars: Math.max(1, remainingText),
        scope: payload.scope ?? "page",
        ...(payload.readCursor && frame.frameId === cursorFrame ? { readCursor: payload.readCursor } : {}),
      }, frame.documentId ? { documentId: frame.documentId } : { frameId: frame.frameId });
      if (payload.scope === "main_content" && local.reading?.scope !== "main_content") {
        throw new ProtocolError("snapshot_scope_unsupported", "This page has an older reader. Reload the page before requesting semantic main content.");
      }
      if (payload.readCursor?.viewportObservationId && frame.frameId === cursorFrame && local.reading?.fromViewport !== true) {
        throw new ProtocolError("snapshot_viewport_unsupported", "This page has an older reader. Reload the page before reading the scroll viewport.");
      }
    } catch (error) {
      if (frame.frameId === 0) {
        error.details = { ...error.details, frameId: frame.frameId };
        throw error;
      }
      if (payload.readCursor && frame.frameId === cursorFrame) throw error;
      await requireCurrentSnapshotCapture(ownedTab, capture);
      frames.push({
        frameId: frame.frameId,
        parentFrameId: frame.parentFrameId,
        url: frame.url ?? "",
        name: "",
        accessible: false,
        nodeCount: 0,
        error: { code: error.code ?? "frame_unavailable", message: error.message },
      });
      continue;
    }
    capture.localSnapshotKeys.add(JSON.stringify([frame.frameId, local.snapshotId]));
    await requireCurrentSnapshotCapture(ownedTab, capture);
    const nodes = Array.isArray(local.nodes) ? local.nodes : [];
    const text = String(local.summary?.text ?? "").slice(0, remainingText);
    remainingNodes -= nodes.length;
    remainingText -= text.length;
    if (frame.frameId === 0) topSnapshot = local;
    if (frame.frameId === 0 && payload.readCursor && payload.readCursor.url !== local.url) throw new ProtocolError("page_changed", "This continuation belongs to another page. Read the current page again.");
    if (payload.readCursor && cursorFrame !== 0 && frame.frameId === 0) {
      // Keep the top document's identity, without replaying its text window.
      remainingNodes += nodes.length; remainingText += text.length;
      continue;
    }
    localSnapshots.push({ frame, local, text });
    frames.push({
      frameId: frame.frameId,
      parentFrameId: frame.parentFrameId,
      url: local.frame?.url ?? frame.url ?? "",
      name: local.frame?.name ?? "",
      accessible: true,
      nodeCount: nodes.length,
    });
    // A control continuation reads only that control, including in an inner
    // frame. Its own folded content must not replay the rest of the document.
    if (payload.readCursor?.elementOnly === true && frame.frameId === cursorFrame) break;
    if (payload.readCursor?.viewportObservationId && frame.frameId === cursorFrame) {
      if (local.readMore) readMore = { ...local.readMore, addressFragment: frameAddressFragment(frame.frameId, local.readMore.addressFragment), url: topSnapshot.url, frameURL: local.url, frameId: frame.frameId };
      break;
    }
    if (local.readMore) {
      readMore = { ...local.readMore, addressFragment: frameAddressFragment(frame.frameId, local.readMore.addressFragment), url: topSnapshot?.url ?? local.url, frameURL: local.url, frameId: frame.frameId };
      break;
    }
    const nextFrame = ordered[ordered.findIndex(f => f.frameId === frame.frameId) + 1];
    if ((remainingNodes <= 0 || remainingText <= 0 || frames.length >= MAX_SNAPSHOT_FRAMES) && nextFrame) {
      if (frames.length >= MAX_SNAPSHOT_FRAMES) truncationReasonsForFrames = true;
      readMore = { url: topSnapshot?.url ?? local.url, frameURL: nextFrame.url, frameId: nextFrame.frameId, addressFragment: frameAddressFragment(nextFrame.frameId, "page"), name: "Embedded page" };
      break;
    }
  }

  if (!topSnapshot) {
    if (frames.some((frame) => frame.frameId === 0 && frame.error?.code === "snapshot_scope_unsupported")) {
      throw new ProtocolError("snapshot_scope_unsupported", "This page has an older reader. Reload the page before requesting semantic main content.");
    }
    throw new ProtocolError("top_frame_unavailable", "The structured page agent is unavailable in the top frame.");
  }
  const snapshotId = crypto.randomUUID();
  const nodes = [];
  const routes = new Map();
  const summaryParts = [];
  const truncationReasons = [];
  for (const { frame, local, text } of localSnapshots) {
    const localToGlobal = new Map();
    for (const localNode of local.nodes ?? []) {
      const globalNodeId = `n${routes.size + 1}`;
      localToGlobal.set(localNode.nodeId, globalNodeId);
      routes.set(globalNodeId, {
        frameId: frame.frameId,
        localSnapshotId: local.snapshotId,
        localNodeId: localNode.nodeId,
      });
    }
    for (const localNode of local.nodes ?? []) {
      const globalNodeId = localToGlobal.get(localNode.nodeId);
      nodes.push({
        ...localNode,
        nodeId: globalNodeId,
        addressFragment: frameAddressFragment(frame.frameId, localNode.addressFragment),
        ...(typeof localNode.elementPath === "string" && localNode.elementPath
          ? { elementPath: `frame/${frame.frameId}/${localNode.elementPath}` } : {}),
        inlineText: (localNode.inlineText ?? []).map(part => ({ ...part,
          ...(part.elementPath ? { elementPath: `frame/${frame.frameId}/${part.elementPath}` } : {}) })),
        ...(localNode.more ? { more: { ...localNode.more, url: topSnapshot.url,
          addressFragment: frameAddressFragment(frame.frameId, localNode.more.addressFragment),
          frameURL: local.url, frameId: frame.frameId } } : {}),
        parentNodeId: localToGlobal.get(localNode.parentNodeId) ?? null,
        frameId: frame.frameId,
      });
    }
    if (text) summaryParts.push(text);
    for (const reason of local.summary?.truncationReasons ?? []) truncationReasons.push(reason);
  }
  if (truncationReasonsForFrames) truncationReasons.push("frame_limit");
  if (frames.some((frame) => !frame.accessible)) truncationReasons.push("frame_unavailable");
  if (remainingNodes <= 0) truncationReasons.push("node_limit");
  if (remainingText <= 0) truncationReasons.push("text_limit");
  const joinedSummary = summaryParts.join("\n");
  if (joinedSummary.length > maxTextChars) truncationReasons.push("text_limit");
  const summaryText = joinedSummary.slice(0, maxTextChars);
  const { frame: _topFrameMetadata, ...topPage } = topSnapshot;
  const result = boundSnapshotForTransport({
    ...topPage,
    snapshotId,
    documentId: ordered.find(frame => frame.frameId === 0)?.documentId,
    reading: {
      scope: payload.scope ?? "page",
      mainContentAvailable: localSnapshots.some(({ local }) => local.reading?.mainContentAvailable === true),
      sections: [...new Set(localSnapshots.flatMap(({ local }) => local.reading?.sections ?? []))],
      maxNodes,
      maxTextChars,
      transportByteLimit: MAX_SNAPSHOT_RESULT_BYTES,
      cursor: payload.readCursor ?? null,
      ...(payload.readCursor?.viewportObservationId ? {
        fromViewport: true,
        viewportChanged: localSnapshots.find(({ frame }) => frame.frameId === cursorFrame)?.local.reading?.viewportChanged ?? null,
      } : {}),
    },
    nodes,
    readMore,
    frames,
    summary: {
      text: summaryText,
      nodeCount: nodes.length,
      truncated: truncationReasons.length > 0 || frames.some((frame) => !frame.accessible),
      truncationReasons: [...new Set(truncationReasons)],
    },
  }, routes, MAX_SNAPSHOT_RESULT_BYTES);
  await requireCurrentSnapshotCapture(ownedTab, capture);
  snapshotRoutes.set(snapshotId, {
    tabId: ownedTab.tabId,
    userSequence: ownedTab.userSequence,
    passive: capture.passive === true,
    routes,
  });
  return result;
}

function frameAddressFragment(frameId, fragment) {
  if (!fragment) return undefined;
  return frameId === 0 ? fragment : `frame/${frameId}/${fragment}`;
}

function boundSnapshotForTransport(snapshot, routes, byteLimit = MAX_SNAPSHOT_RESULT_BYTES) {
  const encodedBytes = (value) => utf8Encoder.encode(JSON.stringify(value)).byteLength;
  if (encodedBytes(snapshot) <= byteLimit) return snapshot;

  const candidates = snapshot.nodes;
  snapshot.nodes = [];
  snapshot.frames = snapshot.frames.map((frame) => ({ ...frame, nodeCount: 0 }));
  snapshot.summary = {
    ...snapshot.summary,
    nodeCount: 0,
    truncated: true,
    truncationReasons: [...new Set([...snapshot.summary.truncationReasons, "encoded_size_limit"])],
  };
  // Counts grow by at most three digits per frame/node total. Keep a small
  // accounting margin and measure each retained node only once (linear work).
  let remainingBytes = byteLimit - encodedBytes(snapshot) - 1_024;
  if (remainingBytes < 0) {
    throw new ProtocolError(
      "snapshot_metadata_too_large",
      "Snapshot metadata exceeds the transport budget; request a smaller text budget or a narrower page view.",
    );
  }
  const retainedIDs = new Set();
  const frameCounts = new Map();
  const retainedOrder = [];
  let sectionKey = null, paragraphKey = null, sectionStart = null, paragraphStart = null, contentCount = 0;
  const byPath = new Map(candidates.map(node => [node.elementPath, node]));
  for (const node of candidates) {
    if (node.inlineProof === true || retainedIDs.has(node.nodeId)) continue;
    const key = `${node.frameId}:${node.sectionPath ?? ""}`;
    if (key !== sectionKey) { sectionKey = key; sectionStart = { node, count: retainedOrder.length, contentCount }; }
    const block = `${node.frameId}:${node.paragraphPath ?? node.elementPath}`;
    if (block !== paragraphKey) { paragraphKey = block; paragraphStart = { node, count: retainedOrder.length }; }
    const group = new Map([[node.nodeId, node]]);
    for (const part of node.inlineText ?? []) {
      const target = byPath.get(part.elementPath);
      if (target && !retainedIDs.has(target.nodeId)) group.set(target.nodeId, target);
    }
    const cost = [...group.values()].reduce((sum, member) => sum + encodedBytes(member) + 1, 0);
    if (cost > remainingBytes) {
      if (!retainedIDs.size) throw new ProtocolError("snapshot_group_too_large", "This prose and its link proofs exceed the transport window. Read with a smaller max_text_chars budget.");
      const boundary = sectionStart?.contentCount > 0 ? sectionStart : paragraphStart?.count > 0 ? paragraphStart : null;
      const nextNode = boundary?.node ?? node;
      if (boundary) for (const id of retainedOrder.splice(boundary.count)) retainedIDs.delete(id);
      snapshot.readMore = { url: snapshot.url, frameId: nextNode.frameId,
        frameURL: snapshot.frames.find(frame => frame.frameId === nextNode.frameId)?.url,
        elementPath: nextNode.elementPath.replace(/^frame\/\d+\//, ""), addressFragment: nextNode.addressFragment, textOffset: nextNode.textOffset ?? 0,
        name: String(nextNode.sectionName || snapshot.title).slice(0, 160) };
      break;
    }
    remainingBytes -= cost;
    for (const member of group.values()) {
      retainedIDs.add(member.nodeId);
      retainedOrder.push(member.nodeId);
    }
    if (!["heading", "landmark", "article"].includes(node.kind) && (node.text || node.name)) contentCount += 1;
  }
  snapshot.nodes = candidates.filter(node => retainedIDs.has(node.nodeId));
  for (const nodeID of routes.keys()) {
    if (!retainedIDs.has(nodeID)) routes.delete(nodeID);
  }
  for (const node of snapshot.nodes) {
    frameCounts.set(node.frameId, (frameCounts.get(node.frameId) ?? 0) + 1);
    if (node.parentNodeId && !retainedIDs.has(node.parentNodeId)) node.parentNodeId = null;
  }
  for (const frame of snapshot.frames) frame.nodeCount = frameCounts.get(frame.frameId) ?? 0;
  snapshot.summary.nodeCount = snapshot.nodes.length;
  // A folded snapshot describes only its retained evidence. Keeping the old
  // whole-window summary made removed nodes contradict unchanged text lines.
  snapshot.summary.text = snapshot.nodes.filter(node => !node.inlineProof)
    .map(node => node.text || node.name).filter(Boolean).join("\n");
  snapshot.reading.sections = [...new Set(snapshot.nodes.map(node => node.sectionName).filter(Boolean))];
  return snapshot;
}

async function clickSnapshotNode(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  if (payload.button !== undefined && payload.button !== "left") {
    throw new ProtocolError("button_not_supported", "Structured page clicks currently support the left button only.");
  }
  const route = requireSnapshotRoute(ownedTab, payload);
  return performSnapshotMutation({
    ownedTab, route, payload, actionId, action: "click",
    pageMessage: {
      type: "nativeagent.page.click",
      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      button: payload.button ?? "left",
    },
  });
}

async function fillSnapshotNode(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const route = requireSnapshotRoute(ownedTab, payload);
  return performSnapshotMutation({
    ownedTab, route,
    payload,
    actionId,
    action: "fill",
    pageMessage: {
      type: "nativeagent.page.fill",
      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      value: payload.value,
    },
  });
}

async function typeIntoSnapshotNode(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const route = requireSnapshotRoute(ownedTab, payload);
  return performSnapshotMutation({
    ownedTab, route,
    payload,
    actionId,
    action: "type",
    pageMessage: {
      type: "nativeagent.page.type",
      tabId: ownedTab.tabId,

      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      text: payload.text,
      delayMs: payload.delayMs ?? 0,
    },
  });
}

async function selectSnapshotNode(payload, actionId) {
  return mutateRoutedNode(payload, actionId, "select", "nativeagent.page.select", { values: payload.values });
}

async function keypressSnapshotNode(payload, actionId) {
  return mutateRoutedNode(payload, actionId, "keypress", "nativeagent.page.keypress", { key: payload.key });
}

async function setCheckedSnapshotNode(payload, actionId) {
  return mutateRoutedNode(payload, actionId, "set_checked", "nativeagent.page.set_checked", { checked: payload.checked });
}

async function doubleClickSnapshotNode(payload, actionId) {
  return mutateRoutedNode(payload, actionId, "double_click", "nativeagent.page.double_click", {});
}

async function mutateRoutedNode(payload, actionId, action, type, extra) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const route = requireSnapshotRoute(ownedTab, payload);
  return performSnapshotMutation({
    ownedTab, route, payload, actionId, action,
    pageMessage: {
      type,
      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      ...extra,
    },
  });
}

async function dragSnapshotNode(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const route = requireSnapshotRoute(ownedTab, payload);
  const target = requireSnapshotRoute(ownedTab, { ...payload, nodeId: payload.targetNodeId });
  if (route.frameId !== target.frameId || route.localSnapshotId !== target.localSnapshotId) {
    throw new ProtocolError("cross_frame_drag_unsupported", "Drag source and target must be in the same observed frame.");
  }
  return performSnapshotMutation({
    ownedTab, route, payload, actionId, action: "drag",
    pageMessage: { type: "nativeagent.page.drag", snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId, targetNodeId: target.localNodeId },
  });
}

async function waitForPage(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const startedAt = new Date().toISOString();
  const timeoutMs = payload.timeoutMs ?? 5_000;
  if (payload.condition === "navigation_settled") {
    // 2026-09-06: ONE deadline for the whole action. The settle interval used
    // to open its own ceiling only after the completion wait had already spent
    // `timeoutMs`, so this could take twice the time the caller asked for.
    const deadlineAtMs = Date.now() + timeoutMs;
    try {
      await waitForTabComplete(ownedTab.tabId, timeoutMs, () => workspace.requireForPageAction(payload), null, actionId);
      const quiet = await awaitNavigationQuiet(ownedTab.tabId, payload.settleMs ?? 0, deadlineAtMs, actionId);
      const tab = await chrome.tabs.get(ownedTab.tabId);
      await workspace.requireForPageAction(payload);
      const complete = tab.id === ownedTab.tabId && tab.status === "complete";
      // A tab that never went quiet is NOT a settled navigation. Reporting it
      // as verified claimed evidence nobody had: the page was still moving when
      // the deadline arrived. `not_quiet` says exactly that, and the Mac reads
      // it as evidence still owed.
      const matched = complete && quiet;
      return pageActionResult({
        actionId,
        action: "wait",
        ownedTab,
        payload,
        startedAt,
        outcome: matched ? "succeeded" : (complete ? "not_quiet" : "not_settled"),
        verification: matched ? "verified" : "not_verified",
        detail: {
          condition: payload.condition,
          matched,
          quiet,
          url: tab.url ?? "",
          title: tab.title ?? "",
        },
      });
    } catch (error) {
      if (error instanceof ProtocolError && error.code === "navigation_timeout") {
        return pageActionResult({
          actionId, action: "wait", ownedTab, payload, startedAt,
          outcome: "timed_out", verification: "not_verified",
          detail: { condition: payload.condition, matched: false },
        });
      }
      throw error;
    }
  }

  let response;
  const route = requireSnapshotRoute(ownedTab, payload);
  try {
    response = await chrome.tabs.sendMessage(ownedTab.tabId, {
      type: "nativeagent.page.wait",
      tabId: ownedTab.tabId,
      actionId,
      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      state: payload.state,
      timeoutMs,
    }, { frameId: route.frameId });
  } catch {
    return pageActionResult({
      actionId, action: "wait", ownedTab, payload, startedAt,
      outcome: "refused", verification: "not_verified",
      detail: {
        condition: payload.condition,
        matched: false,
        error: { code: "page_agent_unavailable", message: "The structured page agent became unavailable." },
      },
    });
  }
  await workspace.requireForPageAction(payload);
  if (!response?.ok) {
    return pageActionResult({
      actionId, action: "wait", ownedTab, payload, startedAt,
      outcome: "refused", verification: "not_verified",
      detail: {
        condition: payload.condition,
        matched: false,
        error: normalizedPageError(response),
      },
    });
  }
  const matched = response.result?.matched === true;
  return pageActionResult({
    actionId, action: "wait", ownedTab, payload, startedAt,
    outcome: matched ? "succeeded" : "timed_out",
    verification: matched ? "verified" : "not_verified",
    detail: { ...response.result, snapshotId: payload.snapshotId, nodeId: payload.nodeId, frameId: route.frameId },
  });
}

async function performSnapshotMutation({ ownedTab, route, payload, actionId, action, pageMessage }) {
  const startedAt = new Date().toISOString();
  let response;
  await workspace.requireForPageAction(payload);
  try {
    response = await chrome.tabs.sendMessage(ownedTab.tabId, { ...pageMessage, tabId: ownedTab.tabId, userSequence: ownedTab.userSequence, actionId }, { frameId: route.frameId });
  } catch {
    return pageActionResult({
      actionId, action, ownedTab, payload, startedAt,
      outcome: "outcome_unknown", verification: "outcome_unknown",
      detail: {
        error: {
          code: "page_reply_lost",
          message: "The page reply was lost after dispatch; the action will not be retried automatically.",
        },
      },
    });
  }
  if (!response?.ok) {
    const error = normalizedPageError(response);
    const ambiguous = error.code === "action_outcome_unknown";
    return pageActionResult({
      actionId, action, ownedTab, payload, startedAt,
      outcome: ambiguous ? "outcome_unknown" : "refused",
      verification: ambiguous ? "outcome_unknown" : "not_verified",
      detail: { error },
    });
  }
  // 2026-09-06: judge a type by what the FIELD kept, not by how many characters
  // the page agent attempted. On a sanitising input every character can be
  // discarded, and counting attempts called that "partially_completed" with the
  // field empty. `enteredCharacterCount` is the readback; a page agent that
  // predates it has none, and the attempted count stands as before.
  //
  // 2026-09-06: a rewrite is not a partial success. When the page reformatted
  // what was already in the field, the readback is not the old value plus our
  // text, and none of it was entered by us — `valueRewritten` says so, and the
  // receipt carries both values so the caller can see what happened.
  const typeResult = action === "type" ? response.result : null;
  const dragUnconfirmed = action === "drag" && response.result?.dropAcknowledged !== true;
  const mediaUnconfirmed = action === "media" && response.result?.completed !== true;
  const typeLandedCount = !typeResult || typeResult.valueRewritten === true
    ? 0
    : (typeResult.enteredCharacterCount ?? typeResult.characterCount ?? 0);
  return pageActionResult({
    actionId, action, ownedTab, payload, startedAt,
    outcome: dragUnconfirmed || mediaUnconfirmed ? "outcome_unknown" : typeResult?.completed === false
      ? (typeLandedCount > 0 ? "partially_completed" : "refused")
      : "succeeded",
    verification: action === "media" ? (mediaUnconfirmed ? "not_verified" : "verified")
      : dragUnconfirmed || (typeResult?.completed === false && typeLandedCount === 0)
      ? "not_verified" : "page_acknowledged",
    detail: {
      ...response.result,
      snapshotId: payload.snapshotId ?? null,
      ...(payload.nodeId !== undefined ? { nodeId: payload.nodeId } : {}),
      ...(payload.targetNodeId !== undefined ? { targetNodeId: payload.targetNodeId } : {}),
      frameId: route.frameId,
    },
  });
}

function pageActionResult({ actionId, action, ownedTab, payload, startedAt, outcome, verification, detail }) {
  const receipt = {
    id: actionId,
    action,
    tabId: ownedTab.tabId,
    userSequence: ownedTab.userSequence,
    snapshotId: payload.snapshotId ?? null,
    nodeId: payload.nodeId ?? payload.targetNodeId ?? null,
    outcome,
    verification,
    retry: outcome === "outcome_unknown" ? "never_automatic"
      : outcome === "partially_completed" ? "fresh_snapshot_then_remaining_text_only" : "fresh_snapshot_required",
    startedAt,
    completedAt: new Date().toISOString(),
  };
  return { ...detail, tabId: ownedTab.tabId,
    ...(action === "media" ? { url: ownedTab.url, title: ownedTab.title } : {}),
    userSequence: ownedTab.userSequence, outcome, receipt };
}

function normalizedPageError(response) {
  return {
    code: response?.error?.code ?? "page_action_failed",
    message: response?.error?.message ?? "The structured page action failed.",
  };
}

async function scrollPage(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const route = payload.targetNodeId ? requireSnapshotRoute(ownedTab, {
    ...payload,
    nodeId: payload.targetNodeId,
  }) : { frameId: 0, localSnapshotId: payload.snapshotId, localNodeId: undefined };
  // Only when the host says the person is away (idle or locked): the
  // debugging bar must never appear while they are using the Mac.
  const stopRendering = payload.renderHidden === true ? await renderWhileHidden(ownedTab.tabId, payload) : async () => {};
  try {
    const result = await performSnapshotMutation({
      ownedTab, route, payload, actionId, action: "scroll",
      pageMessage: {
        type: "nativeagent.page.scroll",
        tabId: ownedTab.tabId,
        snapshotId: route.localSnapshotId,
        targetNodeId: route.localNodeId,
        deltaX: payload.deltaX,
        deltaY: payload.deltaY,
      },
    });
    if (result.readCursor) {
      const tab = await chrome.tabs.get(ownedTab.tabId);
      await workspace.requireForPageAction(payload);
      result.readCursor = { ...result.readCursor, url: tab.url,
        frameURL: result.readCursor.url, frameId: route.frameId };
    }
    return result;
  } finally {
    await stopRendering();
  }
}

// 2026-09-24: a background tab never renders, so an infinite feed (X) never
// sees its scroll, intersection or animation-frame callbacks and stops
// loading. For the length of one scroll, DevTools focus emulation makes the
// hidden tab render as if shown (Chrome counts it as captured) while it stays
// a background tab, off the person's screen. Chrome shows its "started
// debugging this browser" bar while attached; it goes when this detaches. A
// An unavailable debugger reports its failure to the caller.
async function renderWhileHidden(tabId, payload) {
  const none = async () => {};
  const tab = await chrome.tabs.get(tabId);
  await workspace.requireForPageAction(payload);
  if (tab.active) {
    const window = await chrome.windows.get(tab.windowId);
    await workspace.requireForPageAction(payload);
    if (window.state !== "minimized") return none;
  }
  const target = { tabId };
  await chrome.debugger.attach(target, "1.3");
  try {
    await workspace.requireForPageAction(payload);
    await chrome.debugger.sendCommand(target, "Emulation.setFocusEmulationEnabled", { enabled: true });
    await workspace.requireForPageAction(payload);
  } catch (error) {
    await chrome.debugger.detach(target).catch(() => {});
    throw error;
  }
  return async () => { await chrome.debugger.detach(target).catch(() => {}); };
}

async function sendPageMessage(tabId, message, options = undefined) {
  let response;
  try {
    const tab = await workspace.requireTab(tabId);
    response = await chrome.tabs.sendMessage(tabId, { ...message, tabId, userSequence: message.userSequence ?? tab.userSequence }, options);
  } catch (error) {
    if (error instanceof ProtocolError) throw error;
    const tab = await chrome.tabs.get(tabId);
    throw new ProtocolError(
      "page_agent_unavailable",
      !/^https?:/.test(tab.url ?? "")
        ? "The structured page agent cannot read this tab's address. Navigate to an HTTP(S) page and retry."
        : tab.status === "loading"
          ? "The HTTP(S) page agent is still loading or injecting. A read will work once the page is ready."
          : `The page agent in this tab could not be reached: ${error.message ?? String(error)}`,
    );
  }
  if (!response?.ok) {
    throw new ProtocolError(
      response?.error?.code ?? "page_action_failed",
      response?.error?.message ?? "The structured page action failed.",
    );
  }
  return response.result;
}

function requireSnapshotRoute(ownedTab, payload) {
  const snapshot = snapshotRoutes.get(payload.snapshotId);
  if (!snapshot || snapshot.tabId !== ownedTab.tabId
      || snapshot.userSequence !== ownedTab.userSequence) {
    throw new ProtocolError("snapshot_stale", "The page changed after this snapshot was captured.");
  }
  const route = snapshot.routes.get(payload.nodeId);
  if (!route) throw new ProtocolError("node_stale", "The snapshot node is no longer available.");
  return route;
}

function invalidateTabSnapshots(tabId) {
  activeSnapshotReads.delete(tabId);
  for (const [snapshotId, snapshot] of snapshotRoutes) {
    if (snapshot.tabId === tabId) snapshotRoutes.delete(snapshotId);
  }
}

function invalidateSubframeSnapshots(tabId, frameId) {
  // A read in flight that already captured this frame read its old document.
  const capture = activeSnapshotReads.get(tabId);
  for (const key of capture?.localSnapshotKeys ?? []) {
    if (JSON.parse(key)[0] === frameId) capture.invalidatedSnapshotKeys.add(key);
  }
  for (const snapshot of snapshotRoutes.values()) {
    if (snapshot.tabId !== tabId) continue;
    for (const [nodeId, route] of snapshot.routes) {
      if (route.frameId === frameId) snapshot.routes.delete(nodeId);
    }
  }
}

function invalidateFrameSnapshots(tabId, frameId, localSnapshotIds, retainedNavigationNodes) {
  const invalidated = new Set(Array.isArray(localSnapshotIds) ? localSnapshotIds : []);
  const capture = activeSnapshotReads.get(tabId);
  if (capture) {
    for (const id of invalidated) {
      if (capture.invalidatedSnapshotKeys.size >= MAX_SNAPSHOT_FRAMES * 2) {
        capture.invalidationOverflow = true;
        break;
      }
      capture.invalidatedSnapshotKeys.add(JSON.stringify([frameId, id]));
    }
  }
  for (const snapshot of snapshotRoutes.values()) {
    if (snapshot.tabId !== tabId) continue;
    // Only the mutated frame's rows go; other frames' rows stay valid.
    for (const [nodeId, route] of snapshot.routes) {
      if (route.frameId !== frameId || !invalidated.has(route.localSnapshotId)) continue;
      const allowed = retainedNavigationNodes?.[route.localSnapshotId];
      if (!Array.isArray(allowed) || !allowed.includes(route.localNodeId)) snapshot.routes.delete(nodeId);
    }
  }
}

// Walk 3 (09-25): her clicks are script clicks with no user activation, so
// Chrome marks the page she clicked away from "skippable" and tabs.goBack finds
// nothing ("Cannot find a next page in history." — Chrome's text for both
// directions). The page's own history.go is not subject to that skip, so it
// steps instead; resolves once the top frame has moved, rejects if it never does.
async function pageHistoryStep(tabId, delta) {
  const events = [chrome.webNavigation.onCommitted, chrome.webNavigation.onHistoryStateUpdated,
    chrome.webNavigation.onReferenceFragmentUpdated];
  let done;
  const moved = new Promise((resolve) => {
    const timer = setTimeout(() => done(false), 3_000);
    const listener = (details) => { if (details.tabId === tabId && details.frameId === 0) done(true); };
    done = (result) => {
      clearTimeout(timer);
      for (const event of events) event.removeListener(listener);
      resolve(result);
    };
    for (const event of events) event.addListener(listener);
  });
  try {
    await sendPageMessage(tabId, { type: "nativeagent.page.history", delta }, { frameId: 0 });
  } catch (error) { done(false); throw error; }
  if (!(await moved)) {
    throw new ProtocolError("no_history", `This tab has no page to go ${delta < 0 ? "back" : "forward"} to.`);
  }
}

// The top document committed after this watch began, and whether its content
// is parsed: an older document's late DOMContentLoaded is not this navigation's.
function watchTopDocument(tabId) {
  const watch = { committedDocumentId: null, parsed: false, onParsed: null };
  const committed = (details) => {
    if (details.tabId === tabId && details.frameId === 0) {
      watch.committedDocumentId = details.documentId;
      watch.parsed = false;
    }
  };
  const loaded = (details) => {
    if (details.tabId !== tabId || details.frameId !== 0 || details.documentId !== watch.committedDocumentId) return;
    watch.parsed = true;
    watch.onParsed?.();
  };
  chrome.webNavigation.onCommitted.addListener(committed);
  chrome.webNavigation.onDOMContentLoaded.addListener(loaded);
  watch.stop = () => {
    chrome.webNavigation.onCommitted.removeListener(committed);
    chrome.webNavigation.onDOMContentLoaded.removeListener(loaded);
  };
  return watch;
}

async function waitForTabComplete(tabId, timeoutMs, requireCurrent = () => {}, topDocument = null, actionId = undefined) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const waits = activeTabWaits.get(tabId) ?? new Set();
    activeTabWaits.set(tabId, waits);
    function finish(error, tab) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      chrome.tabs.onUpdated.removeListener(listener);
      if (topDocument) topDocument.onParsed = null;
      waits.delete(cancel);
      if (waits.size === 0 && activeTabWaits.get(tabId) === waits) activeTabWaits.delete(tabId);
      if (activeRequestWaits.get(actionId) === cancel) activeRequestWaits.delete(actionId);
      if (error) reject(error); else resolve(tab);
    }
    const cancel = (error) => finish(error);
    const timeout = setTimeout(() => {
      finish(new ProtocolError("navigation_timeout", "Chrome navigation did not finish before the deadline."));
    }, timeoutMs);
    async function observe(tab) {
      if (settled) return;
      try {
        await requireCurrent();
        if (tab.id !== tabId) throw new ProtocolError("tab_identity_changed", "Chrome returned a different tab identity.");
        // A pending URL means the old page (a new tab's about:blank) still
        // reads complete before the new one commits: not this navigation's end.
        if (tab.status === "complete" && !tab.pendingUrl) finish(null, tab);
      } catch (error) { finish(error); }
    }
    function listener(updatedTabId, changeInfo, tab) {
      if (updatedTabId !== tabId || changeInfo.status !== "complete") return;
      observe(tab);
    }
    function parsed() {
      void chrome.tabs.get(tabId).then(async (tab) => {
        if (settled) return;
        await requireCurrent();
        if (tab.id !== tabId) throw new ProtocolError("tab_identity_changed", "Chrome returned a different tab identity.");
        if (!tab.pendingUrl) finish(null, tab);
      }).catch((error) => finish(error));
    }
    waits.add(cancel);
    chrome.tabs.onUpdated.addListener(listener);
    if (topDocument) {
      topDocument.onParsed = parsed;
      if (topDocument.parsed) parsed();
    }
    void chrome.tabs.get(tabId).then(observe).catch((error) => finish(error));
    registerRequestWait(actionId, cancel);
  });
}

// 2026-09-06: the settle interval has to be QUIET, not merely elapsed. The old
// code waited for one `complete`, dropped its listener and slept once, so a
// redirect chain (complete -> loading -> complete) was sampled mid-flight and
// reported as settled. Any update for the tab restarts the interval — an update
// carrying neither `status` nor `url` is still the tab moving, and filtering
// those out let a page that was plainly busy read as quiet.
//
// `deadlineAtMs` is the ONE deadline for the whole wait action, passed in by the
// caller: this used to start its own ceiling AFTER the completion wait had
// already spent the caller's timeout, so a wait could run for twice as long as
// asked. Returns true when the tab actually went quiet, false when the deadline
// arrived first — a page that never goes quiet must not report as settled.
async function awaitNavigationQuiet(tabId, quietMs, deadlineAtMs, actionId = undefined) {
  if (!(quietMs > 0)) return true;
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer = null;
    const cancel = (error) => finish(false, error);
    function finish(quiet, error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      if (activeRequestWaits.get(actionId) === cancel) activeRequestWaits.delete(actionId);
      if (error) reject(error); else resolve(quiet);
    }
    function arm() {
      clearTimeout(timer);
      const remainingMs = deadlineAtMs - Date.now();
      if (remainingMs <= 0) { finish(false); return; }
      timer = quietMs <= remainingMs
        ? setTimeout(() => finish(true), quietMs)
        : setTimeout(() => finish(false), remainingMs);
    }
    function listener(updatedTabId) {
      if (updatedTabId !== tabId) return;
      arm();
    }
    chrome.tabs.onUpdated.addListener(listener);
    arm();
    registerRequestWait(actionId, cancel);
  });
}

// A cancel that arrived before the wait began still ends it.
function registerRequestWait(actionId, cancel) {
  if (actionId === undefined) return;
  activeRequestWaits.set(actionId, cancel);
  if (cancelledRequests.has(actionId)) cancel(new ProtocolError("action_cancelled", "The Chrome action was cancelled."));
}

function cancelTabWaits(tabId, error) {
  for (const cancel of [...(activeTabWaits.get(tabId) ?? [])]) cancel(error);
}

async function installPageReaders() {
  for (const tab of [...workspace.tabs.values()]) {
    try {
      for (const script of chrome.runtime.getManifest().content_scripts) {
        await workspace.requireTab(tab.tabId);
        await chrome.scripting.executeScript({ target: { tabId: tab.tabId, allFrames: script.all_frames === true }, files: script.js });
      }
      await observeOwnedPage(tab);
    } catch (error) { reportPageObservationFailure(tab.tabId, error); }
  }
}

async function observeOwnedPage(ownedTab, frameId, { documentId, propagateFailure = false } = {}) {
  try {
    await workspace.requireForPageAction({ tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence });
    if (frameId === undefined) {
      const frames = await chrome.webNavigation.getAllFrames({ tabId: ownedTab.tabId });
      for (const frame of frames ?? []) {
        await observeOwnedPage(ownedTab, frame.frameId, { documentId: frame.documentId, propagateFailure });
      }
      return;
    }
    if (!propagateFailure && !readyPageFrames.get(ownedTab.tabId)?.has(frameId ?? 0)) {
      // Registration-race read for an already completed tab (including a
      // worker restart). A loading tab waits for ready/onCompleted.
      const tab = await chrome.tabs.get(ownedTab.tabId);
      if (tab.status !== "complete" || tab.pendingUrl) return;
    }
    const frame = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: frameId ?? 0 });
    if (!frame || (documentId && frame.documentId !== documentId)) {
      if (propagateFailure) throw new ProtocolError("page_changed", "The Chrome document changed before its reader was confirmed.");
      return;
    }
    documentId = frame.documentId;
    const result = await sendPageMessage(ownedTab.tabId, {
      type: "nativeagent.page.observe", tabId: ownedTab.tabId,
      userSequence: ownedTab.userSequence,
    }, documentId ? { documentId } : frameId === undefined ? undefined : { frameId });
    await workspace.requireForPageAction({ tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence });
    if (result?.observing !== true) {
      throw new ProtocolError("page_observer_unavailable", "The Chrome page reader did not confirm live observation of this tab.");
    }
    if (result.ready === false) {
      if (propagateFailure) throw new ProtocolError("page_agent_loading", "The HTTP(S) page agent is still loading or injecting. A read will work once the page is ready.");
      return;
    }
    if (await acceptPageReady(ownedTab.tabId, frameId ?? 0, documentId, frame.url)) {
      // Resume a queued edge if attachment won its registration race. Attachment
      // alone does not request another capture of an idle document.
      void drainSiteChanges(ownedTab.tabId);
    }
    return result;
  } catch (error) {
    // Restricted/new documents have no content agent. Its page.ready message
    // arms observation when available; no tab is opened or navigated here.
    if (propagateFailure) throw error;
    sendEvent("page.change_unavailable", {
      tabId: ownedTab.tabId, userSequence: ownedTab.userSequence,
      error: error.code === "unknown_page_action" ? {
          code: "page_observer_reload_required",
          message: "This page has an older Chrome reader. Reload the extension and this page to enable live site changes.",
      } : { code: error.code ?? "page_observation_failed", message: String(error.message ?? error).slice(0, 1024) },
    });
  }
}

function markPageReady(tabId, frameId, documentId, url) {
  let frames = readyPageFrames.get(tabId);
  if (!frames) { frames = new Map(); readyPageFrames.set(tabId, frames); }
  frames.set(frameId, { documentId, url });
}

async function acceptPageReady(tabId, frameId, documentId, url) {
  const current = await chrome.webNavigation.getFrame({ tabId, frameId });
  if (!current || (documentId && current.documentId !== documentId) || (url && current.url !== url)) return false;
  markPageReady(tabId, frameId, current.documentId, current.url);
  return true;
}

function reportPageObservationFailure(tabId, error) {
  const ownedTab = workspace.tabForId(tabId);
  if (ownedTab) sendEvent("page.change_unavailable", { tabId,
    userSequence: ownedTab.userSequence, error: { code: error.code ?? "navigation_observation_failed",
      message: String(error.message ?? error).slice(0, 1024) } });
}

async function queueSiteChange(message, sender) {
  let ownedTab;
  try {
    ownedTab = await workspace.requireForPageAction({
      tabId: message.tabId, expectedUserSequence: message.userSequence,
    });
  } catch { return; }
  if (ownedTab.tabId !== sender.tab.id) return;
  let stream = pageChangeStreams.get(ownedTab.tabId);
  if (!stream || stream.tabId !== ownedTab.tabId) {
    stream = { tabId: ownedTab.tabId, pending: false, draining: false, frameId: sender.frameId };
    pageChangeStreams.set(ownedTab.tabId, stream);
  }
  stream.frameId = sender.frameId;
  // The newest change notice defines what to capture; a frame that was
  // loading before may since have been removed, so its wait ends here.
  stream.waitingFrameId = undefined;
  stream.pending = true;
  void drainSiteChanges(ownedTab.tabId);
}

async function drainSiteChanges(tabId) {
  const stream = pageChangeStreams.get(tabId);
  if (!stream?.pending || stream.draining || activeSnapshotReads.has(tabId) || activeNavigations.has(tabId)
    || !readyPageFrames.get(tabId)?.has(0) || !readyPageFrames.get(tabId)?.has(stream.frameId)
    || (stream.waitingFrameId !== undefined && !readyPageFrames.get(tabId)?.has(stream.waitingFrameId))) return;
  stream.waitingFrameId = undefined;
  stream.draining = true;
  try {
    while (stream.pending && pageChangeStreams.get(tabId) === stream && !activeSnapshotReads.has(tabId) && !activeNavigations.has(tabId)
      && readyPageFrames.get(tabId)?.has(0) && readyPageFrames.get(tabId)?.has(stream.frameId)) {
      stream.pending = false;
      let ownedTab;
      try { ownedTab = await workspace.requireTab(stream.tabId); } catch { break; }
      const view = pageSnapshotViews.get(ownedTab.tabId) ?? { maxNodes: 120, maxTextChars: 12_000, scope: "page" };
      const payload = { tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence, ...view };
      const capture = { passive: true, localSnapshotKeys: new Set(), invalidatedSnapshotKeys: new Set(), invalidationOverflow: false };
      // Replace only prior news routes. A page event must preserve the explicit
      // reader's still-valid navigation proofs and never changes ownership.
      for (const [id, route] of snapshotRoutes) {
        if (route.tabId === tabId && route.passive === true) snapshotRoutes.delete(id);
      }
      activeSnapshotReads.set(tabId, capture);
      try {
        const snapshot = await readStructuredSnapshotForCapture(payload, ownedTab, capture);
        await requireCurrentSnapshotCapture(ownedTab, capture);
        const changeGeneration = (pageChangeGenerations.get(ownedTab.tabId) ?? 0) + 1;
        pageChangeGenerations.set(ownedTab.tabId, changeGeneration);
        generationWrites = generationWrites.catch(() => {}).then(() => chrome.storage.session.set({
          [PAGE_CHANGE_STORAGE_KEY]: Object.fromEntries([...pageChangeGenerations]
            .filter(([id]) => workspace.tabs.has(id))),
        }));
        await generationWrites;
        await requireCurrentSnapshotCapture(ownedTab, capture);
        sendEvent("page.changed", {
          tabId, userSequence: ownedTab.userSequence,
          changeGeneration, changedFrameId: stream.frameId, snapshot,
        });
      } catch (error) {
        // Captures are superseded by explicit reads or real mutations. The
        // pending mutation notice (or explicit read's completion) owns the
        // next capture; never retry on a timer or poll a changing page.
        if (error.code === "snapshot_superseded") stream.pending = true;
        else if (error.code !== "snapshot_stale" && error.code !== "tab_not_owned") {
          if (error.code === "page_agent_unavailable" || error.code === "page_agent_loading") {
            stream.waitingFrameId = error.details?.frameId ?? stream.frameId;
            if (error.code === "page_agent_unavailable") readyPageFrames.get(tabId)?.delete(stream.waitingFrameId);
            stream.pending = true;
          }
          sendEvent("page.change_unavailable", {
            tabId, userSequence: ownedTab.userSequence,
            error: {
              code: String(error.code ?? "page_change_read_failed").slice(0, 128),
              message: String(error.message ?? "The changed page could not be read.").slice(0, 1_024),
            },
          });
          if (error.code === "page_agent_unavailable" || error.code === "page_agent_loading") break;
        }
      } finally {
        if (activeSnapshotReads.get(tabId) === capture) activeSnapshotReads.delete(tabId);
      }
    }
  } finally {
    stream.draining = false;
  }
}

function tabOwnershipEnded(tab, reason) {
  pageChangeStreams.delete(tab.tabId);
  pageChangeGenerations.delete(tab.tabId);
  pageSnapshotViews.delete(tab.tabId);
  invalidateTabSnapshots(tab.tabId);
  activeNavigations.delete(tab.tabId);
  cancelTabWaits(tab.tabId, new ProtocolError("tab_not_owned", "This tab is the person's own now; use another NativeAgent tab."));
  void chrome.tabs.sendMessage(tab.tabId, { type: "nativeagent.page.tab.invalidated", tabId: tab.tabId }).catch(() => {});
  sendEvent("tab.yielded", { tabId: tab.tabId, userSequence: tab.userSequence, reason });
}

function recordOwnershipFailure(error) { recordNativeError(error.message ?? String(error)); }

function sendEvent(event, payload) {
  if (nativePort) postNativeMessage(nativePort, eventEnvelope(event, payload));
}
