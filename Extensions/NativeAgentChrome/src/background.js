import { MAX_SNAPSHOT_RESULT_BYTES, utf8Encoder, frameAddressFragment, boundSnapshotForTransport, pageActionResult, normalizedPageError } from "./page-evidence.js";
import { BrowserWorkspace, tabNotOwnedError } from "./browser-workspace.js";
import {
  ACTIONS,
  HOST_ID,
  PROTOCOL_VERSION,
  ProtocolError,
  errorResponse,
  eventEnvelope,
  successResponse,
  tabStripLockError,
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
// The code digest: SHA-256 over this extension's manifest and every file it
// runs (the manifest's service worker and content scripts, plus their static
// imports), each as "<path>\n<bytes>\n" in path order, first 8 bytes as hex.
// The app computes the same digest over Chrome's registered folder, so a
// reload receipt can say whether the running code is the folder's code even
// when the version did not change.
const CODE_IMPORT_PATTERN = /from\s*["'](\.{1,2}\/[^"']+\.js)["']|import\s*["'](\.{1,2}\/[^"']+\.js)["']/g;
const codeDigest = (async () => {
  const manifest = chrome.runtime.getManifest();
  const queue = ["manifest.json", manifest.background?.service_worker,
    ...(manifest.content_scripts ?? []).flatMap((script) => script.js ?? [])].filter(Boolean);
  const files = new Map();
  while (queue.length > 0) {
    const path = queue.shift();
    if (files.has(path)) continue;
    const response = await fetch(chrome.runtime.getURL(path));
    if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    files.set(path, bytes);
    if (!path.endsWith(".js")) continue;
    const base = "http://x/" + path.slice(0, path.lastIndexOf("/") + 1);
    for (const match of new TextDecoder().decode(bytes).matchAll(CODE_IMPORT_PATTERN)) {
      queue.push(new URL(match[1] ?? match[2], base).pathname.slice(1));
    }
  }
  const encoder = new TextEncoder();
  const parts = [...files.keys()].sort().flatMap((path) => [encoder.encode(path + "\n"), files.get(path), encoder.encode("\n")]);
  const whole = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) { whole.set(part, offset); offset += part.length; }
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", whole));
  return [...hash.slice(0, 8)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
})().catch((error) => {
  console.error("NativeAgent Chrome code digest unavailable:", error);
  return null;
});
const MAX_SNAPSHOT_FRAMES = 64;
const MAX_NATIVE_MESSAGE_BYTES = 1_048_576;
// A look's bounds: the image slot shows at most 2048 px on the long side and
// admits at most 8 MiB of JPEG (LocalToolImage.maximumBytes). Delivery also
// requires the complete UTF-8/base64 response to fit the relay's 1 MiB frame.
const LOOK_MAX_PIXELS = 2048;
const LOOK_MAX_JPEG_BYTES = 8 * 1024 * 1024;
// Keep explicit navigation's load deadline below the app's request timeout.
const PAGE_LOAD_DEADLINE_MS = 25_000;
const PAGE_CHANGE_STORAGE_KEY = "nativeAgentPageChangeGenerationsV1";
const PAGE_VIEW_STORAGE_KEY = "nativeAgentPageSnapshotViewsV1";
const snapshotRoutes = new Map();
const activeSnapshotReads = new Map();
const activeNavigations = new Map();
const activePageActions = new Map();
const cancelledRequests = new Set();
const activeNativeRequests = new Set();
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
  for (const requestId of activeNativeRequests) cancelNativeRequest(requestId);
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

function requireActiveRequest(requestId) {
  if (requestId !== undefined && cancelledRequests.has(requestId)) {
    throw new ProtocolError("action_cancelled", "The Chrome action was cancelled before its next effect.");
  }
}

function cancelNativeRequest(requestId) {
  if (!activeNativeRequests.has(requestId)) return;
  cancelledRequests.add(requestId);
  activeRequestWaits.get(requestId)?.(new ProtocolError("action_cancelled", "The Chrome action was cancelled."));
  const tabId = activePageActions.get(requestId);
  // Cancellation is settlement: it must reach the old page even after it
  // ceased to be owned, rather than waiting for another ownership acquisition.
  if (tabId !== undefined) void chrome.tabs.sendMessage(tabId,
    { type: "nativeagent.page.action.cancel", requestId }).catch(() => {});
}

async function handleNativeMessage(rawRequest, port) {
  if (rawRequest?.type === "event" && rawRequest.event === "action.cancel") {
    const requestId = rawRequest.payload?.requestId;
    if (nativePort !== port || typeof requestId !== "string" || !/^[A-Za-z0-9._:-]{1,128}$/.test(requestId)) return;
    cancelNativeRequest(requestId);
    return;
  }
  let request = rawRequest;
  let requestValidated = false;
  let reloadStarted = false;
  nativeRequestsInFlight += 1;
  try {
    request = validateRequest(rawRequest);
    requestValidated = true;
    activeNativeRequests.add(request.id);
    if (reloadingExtension) throw new ProtocolError("extension_reloading", "The extension is reloading; wait for its accepted connection.");
    await tabsReady;
    if (request.action.startsWith("page.") && request.action !== "page.snapshot.read") {
      const ownedTab = await workspace.requireForPageAction(request.payload);
      activePageActions.set(request.id, ownedTab.tabId);
    }
    requireActiveRequest(request.id);
    reloadStarted = request.action === "extension.reload";
    if (reloadStarted) reloadingExtension = true;
    const result = await dispatch(request);
    const response = successResponse(request, result);
    if (result?.format === "jpeg" && utf8Encoder.encode(JSON.stringify(response)).byteLength > MAX_NATIVE_MESSAGE_BYTES) {
      throw new ProtocolError("picture_too_large", "Chrome's encoded picture and response metadata exceed the relay's 1 MiB frame limit; the picture was not delivered.");
    }
    if (postNativeMessage(port, response)) {
      if (request.action === "attach") {
        nativeReady = true;
        reconcileNativeReconnectAlarm();
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
    activePageActions.delete(request?.id);
    activeNativeRequests.delete(request?.id);
    cancelledRequests.delete(request?.id);
    nativeRequestsInFlight -= 1;
    // Finish accepted work and queue its replies before replacing the worker.
    if (reloadingExtension && nativeRequestsInFlight === 0) chrome.runtime.reload();
  }
}

async function dispatch(request) {
  await changesReady;
  requireActiveRequest(request.id);
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
        codeDigest: await codeDigest,
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
      return workspace.closeTab(request.payload, () => requireActiveRequest(request.id));
    case "navigate":
      return navigateOwnedTab(request.payload, request.id);
    case "page.snapshot.read":
      return readStructuredSnapshot(request.payload, request.id);
    case "page.look":
      return lookAtTab(request.payload, request.id);
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
    ownedTab = await workspace.createTab(() => requireActiveRequest(actionId));
    payload = { ...payload, tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence };
  }
  invalidateTabSnapshots(ownedTab.tabId);
  activePageActions.set(actionId, ownedTab.tabId);
  cancelTabWaits(ownedTab.tabId, new ProtocolError("navigation_superseded", "A newer navigation superseded the pending observation."));
  const navigation = {};
  activeNavigations.set(ownedTab.tabId, navigation);
  const startedAt = new Date().toISOString();
  let topDocument;
  let navigationDispatched = false;
  async function requireCurrentNavigation() {
    await workspace.requireForPageAction(payload);
    requireActiveRequest(actionId);
    if (activeNavigations.get(ownedTab.tabId) !== navigation) {
      throw new ProtocolError("navigation_superseded", "A newer navigation or user takeover superseded this request.");
    }
  }
  try {
    // Chrome owns tab history, including documents such as PDFs that cannot
    // host a page agent. Step to the exact neighbouring entry through the
    // debugger: tabs.goBack skips entries added without user activation (her
    // link clicks), so it would land one page too far. Only when the debugger
    // cannot attach (DevTools already on the tab) does Chrome's own Back run.
    const history = payload.url === "back" || payload.url === "forward"
      ? (id) => stepTabHistory(id, payload.url) : null;
    await requireCurrentNavigation();
    // Watch before dispatch, so a fast commit is not missed.
    topDocument = watchTopDocument(ownedTab.tabId);
    navigationDispatched = true;
    const updated = history
      ? await history(ownedTab.tabId)
        .then(() => chrome.tabs.get(ownedTab.tabId))
      : await chrome.tabs.update(ownedTab.tabId, { url: payload.url });
    await requireCurrentNavigation();
    if (updated?.active === true) {
      await workspace.yieldForTab(ownedTab.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "Navigation unexpectedly activated the NativeAgent tab.");
    }
    // Done when Chrome finishes loading the tab. A deadline that passes after
    // the new document committed still returns that page, marked as loading.
    const loaded = await waitForTabComplete(ownedTab.tabId, PAGE_LOAD_DEADLINE_MS, requireCurrentNavigation, actionId, topDocument)
      .then(() => true, (error) => {
        if (error.code !== "navigation_timeout" || !topDocument.committedDocumentId) throw error;
        return false;
      });
    const tab = await chrome.tabs.get(ownedTab.tabId);
    await requireCurrentNavigation();
    if (tab.active === true) {
      await workspace.yieldForTab(ownedTab.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "The tab became active before navigation could be confirmed.");
    }
    if (tab.id !== ownedTab.tabId || tab.pendingUrl || typeof tab.url !== "string"
        || (loaded && (tab.status !== "complete" || tab.url !== topDocument.completedUrl))) {
      throw new ProtocolError("navigation_changed", "The exact tab no longer has an observed loaded page.");
    }
    // Chrome reporting completion and the landed URL on the exact tab IS the
    // navigation's verification; the receipt carries both the requested and
    // the landed URL, so a redirect is a verified arrival where the site sent
    // us. A page still loading at the deadline is the one unverified case.
    return pageActionResult({
      actionId, action: "navigate", ownedTab, payload, startedAt,
      outcome: "succeeded", verification: loaded ? "verified" : "not_verified",
      detail: {
        tabId: ownedTab.tabId, requestedUrl: payload.url,
        url: tab.url, title: tab.title ?? "", status: tab.status, verified: loaded,
        ...(loaded ? {} : { loading: "Chrome had not finished loading this page when the deadline passed." }),
      },
    });
  } catch (error) {
    // After dispatch, lost ownership or observation cannot prove navigation
    // did not happen. A cancellation before dispatch remains an honest refusal.
    const locked = tabStripLockError(error);
    if (locked || error.code === "tab_strip_locked") throw locked ?? error;
    return pageActionResult({
      actionId, action: "navigate", ownedTab, payload, startedAt,
      outcome: navigationDispatched ? "outcome_unknown" : "refused",
      verification: navigationDispatched ? "outcome_unknown" : "not_verified",
      detail: {
        tabId: ownedTab.tabId, requestedUrl: payload.url,
        status: navigationDispatched ? "outcome_unknown" : "not_performed", verified: false,
        error: { code: error.code ?? "navigation_reply_lost", message: error.message ?? "Chrome navigation could not be confirmed." },
      },
    });
  } finally {
    topDocument?.stop();
    if (activeNavigations.get(ownedTab.tabId) === navigation) activeNavigations.delete(ownedTab.tabId);
    void drainSiteChanges(ownedTab.tabId);
  }
}

function internalPageRead(tab) {
  if (!/^(chrome|about):/.test(tab.url ?? "")) return null;
  return { tabId: tab.tabId, url: tab.url, title: tab.title, userSequence: tab.userSequence,
    reading: { mode: "none", domAccessible: false, reason: "Chrome allows no reader on its internal pages" } };
}

async function readStructuredSnapshot(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  requireActiveRequest(actionId);
  const internal = internalPageRead(ownedTab);
  if (internal) return internal;
  if (!/^https?:/.test(ownedTab.url ?? "")) {
    return lookAtTab(payload, actionId, { pictureReason: "This Chrome page has no DOM reader; reading the picture Chrome renders." });
  }
  let snapshot;
  try { snapshot = await readDOMSnapshot(payload, actionId); }
  catch (error) {
    if (!["page_agent_loading", "page_agent_unavailable"].includes(error.code)) throw error;
    // Chrome's PDF viewer can retain an HTTP URL but cannot host our reader.
    // Prove its MIME type in Chrome before choosing pixels. An ordinary web
    // page's missing reader remains its own failure, never a disguised image.
    return lookAtTab(payload, actionId, { domUnavailableError: error,
      pictureReason: "Chrome's PDF viewer has no accessible DOM reader; reading its displayed picture." });
  }
  if (snapshot.document?.kind === "pdf") {
    return lookAtTab(payload, actionId, { documentKind: "pdf",
      pictureReason: "Reading Chrome's displayed PDF as a picture; no DOM text is available." });
  }
  return snapshot;
}

async function readDOMSnapshot(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  // DOM readiness belongs to the exact document, independently of images or
  // ads still loading. Full-load waiting belongs to explicit navigation only.
  const frame = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: 0 });
  const ready = readyPageFrames.get(ownedTab.tabId)?.get(0);
  if (!frame || !ready || ready.documentId !== frame.documentId) {
    throw new ProtocolError("page_agent_loading", "The current Chrome document has not reported DOM readiness yet.");
  }
  const tab = await chrome.tabs.get(ownedTab.tabId);
  await workspace.requireForPageAction(payload);
  const loaded = tab.status === "complete" && !tab.pendingUrl;
  payload = { ...pageSnapshotViews.get(ownedTab.tabId), ...payload };
  invalidateTabSnapshots(ownedTab.tabId);
  requireActiveRequest(actionId);
  const capture = { actionId, localSnapshotKeys: new Set(), invalidatedSnapshotKeys: new Set(), invalidationOverflow: false };
  activeSnapshotReads.set(ownedTab.tabId, capture);
  try {
    const snapshot = await readStructuredSnapshotForCapture(payload, ownedTab, capture);
    const cursor = payload.readCursor;
    pageSnapshotViews.set(ownedTab.tabId, {
      maxNodes: payload.maxNodes ?? 120, maxTextChars: payload.maxTextChars ?? 12_000,
      scope: payload.scope ?? "page",
      // Keep the scroller, never the point reached by a one-off read-more.
      ...(cursor?.viewportObservationId && snapshot.reading.viewportObservationId === cursor.viewportObservationId ? { readCursor: {
        url: cursor.url, frameURL: cursor.frameURL, frameId: cursor.frameId,
        viewportObservationId: cursor.viewportObservationId,
      } } : {}),
    });
    // Retain the successful reader's exact view durably before its reply,
    // without another page read. Writes serialize across tabs.
    await persistPageViews(ownedTab);
    await requireCurrentSnapshotCapture(ownedTab, capture);
    snapshot.reading.pageMoved ||= snapshotCaptureMoved(capture);
    return { ...snapshot, rendering: { ...snapshot.rendering, loaded } };
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
  requireActiveRequest(capture.actionId);
  if (activeSnapshotReads.get(ownedTab.tabId) !== capture) {
    throw new ProtocolError("snapshot_superseded", "A newer read or navigation superseded this snapshot capture.");
  }
}

function snapshotCaptureMoved(capture) {
  return capture.invalidationOverflow || [...capture.localSnapshotKeys].some((key) => capture.invalidatedSnapshotKeys.has(key));
}

async function readStructuredSnapshotForCapture(payload, ownedTab, capture) {
  const maxNodes = payload.maxNodes ?? 120;
  const maxTextChars = payload.maxTextChars ?? 12_000;
  const discovered = await chrome.webNavigation.getAllFrames({ tabId: ownedTab.tabId });
  await requireCurrentSnapshotCapture(ownedTab, capture);
  const ordered = [...(discovered ?? [])].sort((left, right) => {
    if (left.frameId === 0) return -1;
    if (right.frameId === 0) return 1;
    return left.frameId - right.frameId;
  });
  let pageMoved = false;
  let cursorFrame = payload.readCursor?.frameId ?? 0;
  if (payload.readCursor && !ordered.some(frame => frame.frameId === cursorFrame)) {
    pageMoved = true;
    payload = { ...payload, readCursor: undefined };
    cursorFrame = 0;
  }
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
    if ((capture.passive || frame.frameId === 0) && /^https?:/.test(frame.url ?? "")) {
      const ready = readyPageFrames.get(ownedTab.tabId)?.get(frame.frameId);
      if (!ready || (frame.documentId && ready.documentId !== frame.documentId)) {
        throw new ProtocolError("page_agent_loading", "The HTTP(S) page agent is still loading or injecting. A read will work once the page is ready.", { frameId: frame.frameId });
      }
    }
    let local;
    try {
      local = await sendPageMessage(ownedTab.tabId, {
        type: "nativeagent.page.snapshot",
        actionId: capture.actionId,
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
      if (local.reading?.fromViewport !== true) {
        throw new ProtocolError("snapshot_viewport_unsupported", "This page has an older reader. Reload the extension before reading from the current viewport.");
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
    if (frame.frameId === 0 && payload.readCursor && payload.readCursor.url !== local.url) {
      pageMoved = true;
      payload = { ...payload, readCursor: undefined };
      cursorFrame = 0;
    }
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
    if (local.readMore) {
      readMore = { ...local.readMore, url: topSnapshot?.url ?? local.url, frameURL: local.url, frameId: frame.frameId };
      break;
    }
    const nextFrame = ordered[ordered.findIndex(f => f.frameId === frame.frameId) + 1];
    if ((remainingNodes <= 0 || remainingText <= 0 || frames.length >= MAX_SNAPSHOT_FRAMES) && nextFrame) {
      if (frames.length >= MAX_SNAPSHOT_FRAMES) truncationReasonsForFrames = true;
      readMore = { url: topSnapshot?.url ?? local.url, frameURL: nextFrame.url, frameId: nextFrame.frameId, name: "Embedded page" };
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
      fromViewport: true,
      pageMoved: pageMoved || localSnapshots.some(({ local }) => local.reading?.pageMoved === true),
      viewportObservationId: localSnapshots.find(({ frame }) => frame.frameId === cursorFrame)?.local.reading?.viewportObservationId ?? null,
      ...(payload.readCursor?.viewportObservationId ? {
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
  result.reading.pageMoved ||= snapshotCaptureMoved(capture);
  // A moved page is readable evidence, but an invalidated node is still no
  // authority to act. Mutation notices before route publication count too.
  for (const [id, route] of routes) {
    const key = JSON.stringify([route.frameId, route.localSnapshotId]);
    if (capture.invalidationOverflow || (capture.invalidatedSnapshotKeys.has(key)
      && !capture.retainedNavigationNodes?.get(key)?.includes(route.localNodeId))) routes.delete(id);
  }
  snapshotRoutes.set(snapshotId, {
    tabId: ownedTab.tabId,
    userSequence: ownedTab.userSequence,
    passive: capture.passive === true,
    routes,
  });
  return result;
}


async function clickSnapshotNode(payload, actionId) {
  if (payload.button !== undefined && payload.button !== "left") {
    throw new ProtocolError("button_not_supported", "Structured page clicks currently support the left button only.");
  }
  return mutateRoutedNode(payload, actionId, "click", "nativeagent.page.click", { button: payload.button ?? "left" });
}

async function fillSnapshotNode(payload, actionId) {
  return mutateRoutedNode(payload, actionId, "fill", "nativeagent.page.fill", { value: payload.value });
}

async function typeIntoSnapshotNode(payload, actionId) {
  return mutateRoutedNode(payload, actionId, "type", "nativeagent.page.type", { text: payload.text, delayMs: payload.delayMs ?? 0 });
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
    try {
      const quiet = await waitForTabComplete(ownedTab.tabId, timeoutMs,
        () => workspace.requireForPageAction(payload), actionId, undefined, payload.settleMs ?? 0);
      const tab = await chrome.tabs.get(ownedTab.tabId);
      await workspace.requireForPageAction(payload);
      const complete = tab.id === ownedTab.tabId && tab.status === "complete" && !tab.pendingUrl;
      // Completion without quiet still owes settlement evidence.
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
  requireActiveRequest(actionId);
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
  requireActiveRequest(actionId);
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
  return pageActionResult({
    actionId, action, ownedTab, payload, startedAt,
    outcome: response.result.outcome,
    verification: response.result.verification,
    detail: {
      ...response.result,
      snapshotId: payload.snapshotId ?? null,
      ...(payload.nodeId !== undefined ? { nodeId: payload.nodeId } : {}),
      ...(payload.targetNodeId !== undefined ? { targetNodeId: payload.targetNodeId } : {}),
      frameId: route.frameId,
    },
  });
}

// The entry beside the current one in this tab's own history, by id, so a
// page reached by a scripted click is not skipped (Chrome's history
// manipulation intervention marks such entries skippable for tabs.goBack).
async function stepTabHistory(tabId, direction) {
  const target = { tabId };
  try {
    await chrome.debugger.attach(target, "1.3");
  } catch (error) {
    return direction === "back" ? chrome.tabs.goBack(tabId) : chrome.tabs.goForward(tabId);
  }
  try {
    const { currentIndex, entries } = await chrome.debugger.sendCommand(target, "Page.getNavigationHistory");
    const entry = entries?.[currentIndex + (direction === "back" ? -1 : 1)];
    if (!entry) {
      throw new ProtocolError("history_unavailable", `This tab has no ${direction} entry to go to.`);
    }
    await chrome.debugger.sendCommand(target, "Page.navigateToHistoryEntry", { entryId: entry.id });
  } finally {
    await chrome.debugger.detach(target).catch(() => {});
  }
}

async function lookAtTab(payload, actionId, { domUnavailableError, pictureReason, documentKind } = {}) {
  const ownedTab = await workspace.requireForPageAction(payload);
  requireActiveRequest(actionId);
  const internal = internalPageRead(ownedTab);
  if (internal) return internal;
  const target = { tabId: ownedTab.tabId };
  // Capture the existing surface only. Unlike hidden scrolling, looking
  // needs neither focus emulation nor the person to be away.
  requireActiveRequest(actionId);
  await chrome.debugger.attach(target, "1.3");
  let capture;
  try {
    if (domUnavailableError) {
      requireActiveRequest(actionId);
      const { frameTree } = await chrome.debugger.sendCommand(target, "Page.getFrameTree");
      if (frameTree?.frame?.mimeType !== "application/pdf") throw domUnavailableError;
      documentKind = "pdf";
    }
    try {
      // The picture is bounded where it is taken: the visible viewport, scaled so
      // its long side is at most LOOK_MAX_PIXELS device pixels (what the image
      // slot shows anyway), so a Retina tab is not refused for its size.
      requireActiveRequest(actionId);
      const { cssVisualViewport: viewport } = await chrome.debugger.sendCommand(target, "Page.getLayoutMetrics");
      requireActiveRequest(actionId);
      const { result: ratio } = await chrome.debugger.sendCommand(target, "Runtime.evaluate",
        { expression: "window.devicePixelRatio", returnByValue: true });
      const dpr = Number(ratio?.value) > 0 ? Number(ratio.value) : 1;
      const width = Math.max(1, Math.round(viewport?.clientWidth ?? 0));
      const height = Math.max(1, Math.round(viewport?.clientHeight ?? 0));
      const scale = Math.min(1, LOOK_MAX_PIXELS / (Math.max(width, height) * dpr));
      requireActiveRequest(actionId);
      capture = await chrome.debugger.sendCommand(target, "Page.captureScreenshot", {
        format: "jpeg", quality: 85, fromSurface: true,
        clip: { x: viewport?.pageX ?? 0, y: viewport?.pageY ?? 0, width, height, scale },
      });
      if (typeof capture?.data !== "string" || !capture.data.length) throw new Error("No picture data.");
    } catch (error) {
      if (error.code === "action_cancelled") throw error;
      throw new ProtocolError("tab_not_painted", "Chrome did not render this hidden tab for a picture. Nothing was changed; the tab was not activated.");
    }
  } finally {
    // No decoding or ownership work keeps the debugger infobar on screen. A tab
    // gone mid-capture has nothing to detach; the capture's own error stands.
    await chrome.debugger.detach(target).catch(() => {});
  }
  if (capture.data.length * 3 / 4 > LOOK_MAX_JPEG_BYTES) {
    throw new ProtocolError("picture_too_large", "Chrome's picture exceeds the image slot's 8 MiB; it was not delivered. Nothing was changed; the tab was not activated.");
  }
  const bitmap = await createImageBitmap(new Blob([
    Uint8Array.from(atob(capture.data), character => character.charCodeAt(0)),
  ], { type: "image/jpeg" }));
  const { width, height } = bitmap;
  bitmap.close();
  // A picture captured while the person took this tab is never delivered.
  const tab = await workspace.requireForPageAction(payload);
  return { tabId: tab.tabId, url: tab.url, title: tab.title,
    userSequence: tab.userSequence, width, height, format: "jpeg", data: capture.data,
    ...(documentKind ? { document: { kind: documentKind, status: "unread" } } : {}),
    ...(pictureReason ? { reading: { mode: "picture", reason: pictureReason, domAccessible: false } } : {}) };
}

async function scrollPage(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const route = payload.targetNodeId ? requireSnapshotRoute(ownedTab, {
    ...payload,
    nodeId: payload.targetNodeId,
  }) : { frameId: 0, localSnapshotId: payload.snapshotId, localNodeId: undefined };
  // Only when the host says the person is away (idle or locked): the
  // debugging bar must never appear while they are using the Mac.
  requireActiveRequest(actionId);
  const stopRendering = payload.renderHidden === true ? await renderWhileHidden(ownedTab.tabId, payload, actionId) : async () => {};
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

// Hidden scrolling temporarily owns debugger focus emulation so background tabs render.
// Cleanup detaches the debugger; admission failures reach the caller.
async function renderWhileHidden(tabId, payload, actionId) {
  const none = async () => {};
  const tab = await chrome.tabs.get(tabId);
  await workspace.requireForPageAction(payload);
  if (tab.active) {
    const window = await chrome.windows.get(tab.windowId);
    await workspace.requireForPageAction(payload);
    if (window.state !== "minimized") return none;
  }
  const target = { tabId };
  requireActiveRequest(actionId);
  await chrome.debugger.attach(target, "1.3");
  try {
    await workspace.requireForPageAction(payload);
    requireActiveRequest(actionId);
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
    requireActiveRequest(message.actionId);
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
      capture.retainedNavigationNodes ??= new Map();
      capture.retainedNavigationNodes.set(JSON.stringify([frameId, id]), retainedNavigationNodes?.[id] ?? []);
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

// Arm both observations before dispatch. A commit proves a partial arrival;
// tab completion works even for Chrome pages without webNavigation/DOM access.
function watchTopDocument(tabId) {
  const watch = { committedDocumentId: null, completedUrl: null };
  const committed = (details) => {
    if (details.tabId === tabId && details.frameId === 0) watch.committedDocumentId = details.documentId;
  };
  const updated = (id, change, tab) => {
    if (id !== tabId) return;
    if (change.status === "loading") watch.completedUrl = null;
    // A same-document fragment change can update the URL without a load.
    if ((change.status === "complete" || change.url) && tab.status === "complete" && !tab.pendingUrl) {
      watch.completedUrl = tab.url;
    }
  };
  chrome.webNavigation.onCommitted.addListener(committed);
  chrome.tabs.onUpdated.addListener(updated);
  watch.stop = () => {
    chrome.webNavigation.onCommitted.removeListener(committed);
    chrome.tabs.onUpdated.removeListener(updated);
  };
  return watch;
}

// Completion and quiet share one deadline; every tab update restarts quiet.
async function waitForTabComplete(tabId, timeoutMs, requireCurrent = () => {}, actionId = undefined, navigationWatch = undefined, quietMs = 0) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let completed = false;
    let quietTimer;
    let observedTab;
    const waits = activeTabWaits.get(tabId) ?? new Set();
    activeTabWaits.set(tabId, waits);
    function finish(error, quiet = false) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      clearTimeout(quietTimer);
      chrome.tabs.onUpdated.removeListener(listener);
      waits.delete(cancel);
      if (waits.size === 0 && activeTabWaits.get(tabId) === waits) activeTabWaits.delete(tabId);
      if (activeRequestWaits.get(actionId) === cancel) activeRequestWaits.delete(actionId);
      if (error) reject(error); else resolve(quiet);
    }
    const cancel = (error) => finish(error);
    const timeout = setTimeout(() => {
      finish(completed ? null : new ProtocolError("navigation_timeout", "Chrome navigation did not finish before the deadline."));
    }, timeoutMs);
    async function observe(tab) {
      if (settled) return;
      observedTab = tab;
      clearTimeout(quietTimer);
      try {
        await requireCurrent();
        if (settled || observedTab !== tab) return;
        if (tab.id !== tabId) throw new ProtocolError("tab_identity_changed", "Chrome returned a different tab identity.");
        // A pending URL means the old page (a new tab's about:blank) still
        // reads complete before the new one commits: not this navigation's end.
        if (tab.status === "complete" && !tab.pendingUrl && (!navigationWatch || navigationWatch.completedUrl === tab.url)) {
          completed = true;
          if (quietMs > 0) quietTimer = setTimeout(() => finish(null, true), quietMs);
          else finish(null, true);
        }
      } catch (error) { finish(error); }
    }
    function listener(updatedTabId, changeInfo, tab) {
      if (updatedTabId !== tabId) return;
      observe(tab);
    }
    waits.add(cancel);
    chrome.tabs.onUpdated.addListener(listener);
    void chrome.tabs.get(tabId).then(observe).catch((error) => finish(error));
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
        snapshot.reading.pageMoved ||= snapshotCaptureMoved(capture);
        sendEvent("page.changed", {
          tabId, userSequence: ownedTab.userSequence,
          changeGeneration, changedFrameId: stream.frameId, snapshot,
        });
      } catch (error) {
        // A newer explicit read owns publication. Mutations are returned as
        // moved-page evidence, with no retry of the read.
        if (error.code === "snapshot_superseded") stream.pending = true;
        else if (error.code !== "tab_not_owned") {
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
  cancelTabWaits(tab.tabId, tabNotOwnedError(tab.tabId, reason));
  void chrome.tabs.sendMessage(tab.tabId, { type: "nativeagent.page.tab.invalidated", tabId: tab.tabId }).catch(() => {});
  sendEvent("tab.yielded", { tabId: tab.tabId, userSequence: tab.userSequence, reason, url: tab.url });
}

function recordOwnershipFailure(error) { recordNativeError(error.message ?? String(error)); }

function sendEvent(event, payload) {
  if (nativePort) postNativeMessage(nativePort, eventEnvelope(event, payload));
}
