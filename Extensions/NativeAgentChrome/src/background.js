import { MAX_SNAPSHOT_RESULT_BYTES, utf8Encoder, frameAddressFragment, boundSnapshotForTransport, pageActionResult, normalizedPageError } from "./page-evidence.js";
import { BrowserWorkspace, tabNotOwnedError } from "./browser-workspace.js";
import { PageLoads } from "./page-load.js";
import { captureScreenPreview, readPicturePreviewGeometry } from "./screen-preview.js";
import {
  ACTIONS,
  HOST_ID,
  PROTOCOL_VERSION,
  DEFAULT_SNAPSHOT_NODES,
  DEFAULT_SNAPSHOT_TEXT_CHARS,
  ProtocolError,
  errorResponse,
  eventEnvelope,
  successResponse,
  tabStripLockError,
  validateRequest,
  trustedKeyEvents,
} from "./protocol.js";

let nativePort = null;
let nativeReady = false;
let reloadingExtension = null; // "requested" or "retry", owned by the drain below.
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
const RELOAD_STORAGE_KEY = "nativeAgentReloadRecovery";
let reloadRecovery = null;
let reloadRetryTimer = null;
// Session storage is cleared by extension reload; this record must reach the new worker.
const reloadRecoveryReady = chrome.storage.local.get(RELOAD_STORAGE_KEY).then(stored => {
  reloadRecovery = stored[RELOAD_STORAGE_KEY] ?? null;
  if (!reloadRecovery) return;
  if (typeof reloadRecovery.id !== "string" || !/^[A-Za-z0-9._:-]{1,128}$/.test(reloadRecovery.id)
    || ![1, 2].includes(reloadRecovery.attempts) || !Number.isFinite(reloadRecovery.deadline)) {
    throw new Error("The retained reload id, count or deadline is unreadable; no reload retry was admitted.");
  }
  const remaining = reloadRecovery.deadline - Date.now();
  if (remaining <= 0) return recordNativeError(`Reload ${reloadRecovery.id} exhausted its reconnect bound; last running version ${chrome.runtime.getManifest().version}, attempts ${reloadRecovery.attempts}, no accepted app connection.`);
  if (reloadRecovery.attempts === 1) {
    // One reload retry within the app's existing 30-second reconnect bound.
    reloadRetryTimer = setTimeout(() => void retryUnacceptedReload(), Math.min(remaining, 10_000));
  }
});
void reloadRecoveryReady.catch(error => recordNativeError(`Reload recovery could not be read: ${error.message}`));

async function retryUnacceptedReload() {
  reloadRetryTimer = null;
  if (nativeReady || !reloadRecovery || reloadRecovery.attempts !== 1 || Date.now() >= reloadRecovery.deadline) return;
  reloadRecovery = { ...reloadRecovery, attempts: 2 };
  try {
    await chrome.storage.local.set({ [RELOAD_STORAGE_KEY]: reloadRecovery });
    recordNativeError(`Reload ${reloadRecovery.id} had no accepted reconnect from version ${chrome.runtime.getManifest().version}; retrying the reload once.`);
    await nativeErrorWrites;
    if (nativeReady || !reloadRecovery) return;
    // Do not interrupt other accepted work. The normal drain performs reload.
    reloadingExtension = "retry";
    if (nativeRequestsInFlight === 0) chrome.runtime.reload();
  } catch (error) { recordNativeError(`Reload retry could not be retained: ${error.message}`); }
}
// The code digest: SHA-256 over this extension's manifest and every file it
// runs (the manifest's service worker and content scripts, plus their static
// imports), each as "<path>\n<bytes>\n" in path order, first 8 bytes as hex.
// The app computes the same digest over Chrome's registered folder, so a
// reload receipt can say whether the running code is the folder's code even
// when the version did not change.
const CODE_IMPORT_PATTERN = /from\s*["'](\.{1,2}\/[^"']+\.js)["']|import\s*["'](\.{1,2}\/[^"']+\.js)["']/g;
// Her reader lives only in her tabs; nothing of ours runs in any other tab.
const PAGE_READER = "src/page-agent.js";
const codeDigest = (async () => {
  const manifest = chrome.runtime.getManifest();
  const queue = ["manifest.json", manifest.background?.service_worker, PAGE_READER].filter(Boolean);
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
const PAGE_CHANGE_STORAGE_KEY = "nativeAgentPageChangeGenerationsV1";
const PAGE_VIEW_STORAGE_KEY = "nativeAgentPageSnapshotViewsV1";
const snapshotRoutes = new Map();
const trustedInputs = new Map();
const activeSnapshotReads = new Map();
// Only a top-document replacement advances the aggregate document generation.
// A subframe commit invalidates that frame's routes and retains its siblings.
// Tokens are worker-local; no in-flight capture survives a worker restart.
const pageDocumentGenerations = new Map();
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
const pageReadinessObservers = new Map();
const READABLE_DOCUMENT = /^https?:/;
// Chrome injects into web documents and the about: frames they make. Blob and
// data frames carry no reader, so nothing answers a frame embedded under them.
const READER_FRAME = /^(?:https?|about):/;
// Tabs whose current ownership has its reader, or is getting it.
const installingReaders = new Map();
const pageLoads = new PageLoads(chrome, tabId => {
  for (const observe of pageReadinessObservers.get(tabId) ?? []) void observe();
  const error = pageLoads.documents.get(tabId)?.error;
  if (error) reportPageObservationFailure(tabId, new ProtocolError("navigation_failed", error));
  else void drainSiteChanges(tabId);
});
let generationWrites = Promise.resolve();
let viewWrites = Promise.resolve();
const workspace = new BrowserWorkspace(chrome, tabOwnershipEnded, tabs => {
  sendEvent("tabs.changed", { tabs });
  for (const tab of tabs) void installPageReader(tab);
});
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
      const previous = readyPageFrames.get(sender.tab.id)?.get(sender.frameId);
      if (!await acceptPageReady(sender.tab.id, sender.frameId, sender.documentId, message.url)) return;
      if (sender.frameId === 0) pageLoads.reader(sender.tab.id, sender.documentId, message);
      const ownedTab = workspace.tabForId(sender.tab.id);
      if (ownedTab) {
        const view = pageSnapshotViews.get(ownedTab.tabId);
        if (view?.readCursor && previous?.documentId !== sender.documentId
          && (sender.frameId === 0 || sender.frameId === view.readCursor.frameId)) {
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

chrome.webNavigation.onCommitted.addListener(({ tabId, frameId, documentId, url, transitionQualifiers }) => {
  if (frameId === 0) {
    // Chrome supplies actual omnibox navigation evidence. It is user
    // custody even if the already-active tab emitted no activation event.
    const userNavigation = transitionQualifiers?.includes("from_address_bar") === true;
    if (userNavigation) void workspace.yieldForTab(tabId, "user_navigation").catch(recordOwnershipFailure);
    readyPageFrames.delete(tabId);
    // A new document: waits on the old document's frames no longer apply.
    const stream = pageChangeStreams.get(tabId);
    if (stream) { stream.waitingFrameId = undefined; stream.restUntil = 0; }
    invalidateTabSnapshots(tabId, true);
  } else {
    // An ad or tracker iframe loading replaces only that frame's rows.
    readyPageFrames.get(tabId)?.delete(frameId);
    invalidateSubframeSnapshots(tabId, frameId);
  }
  const ownedTab = workspace.tabForId(tabId);
  if (!ownedTab) return;
  void readDocument(tabId, frameId, documentId, url);
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

const pageRouteChanged = ({ tabId, frameId, documentId }) => {
  void changesReady.then(async () => {
    const ownedTab = workspace.tabForId(tabId);
    if (ownedTab) {
      await observeOwnedPage(ownedTab, frameId, { documentId });
      queueSiteChange({ tabId: ownedTab.tabId, userSequence: ownedTab.userSequence }, { tab: { id: tabId }, frameId });
    }
  }).catch((error) => reportPageObservationFailure(tabId, error));
};
chrome.webNavigation.onHistoryStateUpdated.addListener(pageRouteChanged);
chrome.webNavigation.onReferenceFragmentUpdated.addListener(pageRouteChanged);

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
    if (request.action.startsWith("page.")) {
      const ownedTab = await workspace.requireForPageAction(request.payload);
      activePageActions.set(request.id, ownedTab.tabId);
    }
    requireActiveRequest(request.id);
    reloadStarted = request.action === "extension.reload";
    if (reloadStarted) reloadingExtension = "requested";
    const result = await dispatch(request);
    let response = successResponse(request, result);
    if (result?.format === "jpeg" && Object.hasOwn(result, "geometry")
        && utf8Encoder.encode(JSON.stringify(response)).byteLength > MAX_NATIVE_MESSAGE_BYTES) {
      // Optional local geometry cannot invalidate the original picture's transport budget.
      const { geometry, ...picture } = result;
      response = successResponse(request, picture);
    }
    if (result?.format === "jpeg" && utf8Encoder.encode(JSON.stringify(response)).byteLength > MAX_NATIVE_MESSAGE_BYTES) {
      throw retainCleanup(new ProtocolError("picture_too_large", "Chrome's encoded picture and response metadata exceed the relay's 1 MiB frame limit; the picture was not delivered."), result.cleanupError);
    }
    if (postNativeMessage(port, response)) {
      if (request.action === "attach") {
        nativeReady = true;
        clearTimeout(reloadRetryTimer);
        reloadRetryTimer = null;
        if (reloadRecovery) {
          reloadRecovery = null;
          void chrome.storage.local.remove(RELOAD_STORAGE_KEY).catch(error => recordNativeError(`Reload confirmation cleanup failed: ${error.message}`));
        }
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
    if (reloadingExtension && nativeRequestsInFlight === 0) {
      if (reloadingExtension === "retry" && nativeReady) reloadingExtension = null;
      else chrome.runtime.reload();
    }
  }
}

async function dispatch(request) {
  await changesReady;
  requireActiveRequest(request.id);
  // Reads await their own document; unrelated tabs cannot hold their arrival.
  if (!["attach", "extension.reload", "navigate", "page.snapshot.read", "page.look"].includes(request.action)) await Promise.all(installingReaders.values());
  switch (request.action) {
    case "attach":
      await reloadRecoveryReady;
      await nativeErrorWrites;
      await workspace.refresh();
      return {
        hostId: HOST_ID, protocolVersion: PROTOCOL_VERSION,
        extensionVersion: chrome.runtime.getManifest().version,
        codeDigest: await codeDigest,
        extensionId: chrome.runtime.id, connected: true,
        tabs: [...workspace.tabs.values()].map(tab => ({ ...tab })),
        lastExtensionError, capabilities: ACTIONS,
        ...(reloadRecovery ? { reloadEvidence: { reloadId: reloadRecovery.id, attempts: reloadRecovery.attempts,
          runningVersion: chrome.runtime.getManifest().version } } : {}),
      };
    case "extension.reload":
      await reloadRecoveryReady;
      reloadRecovery = { id: request.payload.reloadId, attempts: 1, deadline: Date.now() + 30_000 };
      await chrome.storage.local.set({ [RELOAD_STORAGE_KEY]: reloadRecovery });
      return {
        reloadId: request.payload.reloadId, beforeVersion: chrome.runtime.getManifest().version,
        status: "acknowledged",
      };
    case "tab.close":
      return workspace.closeTab(request.payload, () => requireActiveRequest(request.id));
    case "navigate":
      return navigateOwnedTab(request.payload, request.id);
    case "page.snapshot.read": {
      await keepOwnedTabRendering(request.payload);
      const result = await readStructuredSnapshot(request.payload, request.id);
      if (request.payload.navigationStartedAtMs !== undefined) {
        result.navigationReadReturnedMs = pageLoads.now() - request.payload.navigationStartedAtMs;
      }
      return result;
    }
    case "page.look":
      return lookAtTab(request.payload, request.id);
    case "page.preview":
      return captureScreenPreview(request.payload, workspace, async () => {
        requireActiveRequest(request.id);
        await workspace.requireForPageAction(request.payload);
      });
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
      await keepOwnedTabRendering(request.payload);
      return waitForPage(request.payload, request.id);
    case "page.scroll":
      await keepOwnedTabRendering(request.payload);
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
  const timingOrigin = pageLoads.now();
  let ownedTab;
  if (payload.tabId !== undefined) {
    ownedTab = await workspace.requireForPageAction(payload);
  }
  if (!ownedTab) {
    if (payload.url === "back" || payload.url === "forward") {
      throw new ProtocolError("tab_not_owned", "Back and forward require one of your NativeAgent tabs.");
    }
    ownedTab = await workspace.createTab(() => requireActiveRequest(actionId));
    payload = { ...payload, tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence };
  }
  await keepRendering(ownedTab.tabId);
  invalidateTabSnapshots(ownedTab.tabId, true);
  activePageActions.set(actionId, ownedTab.tabId);
  cancelTabWaits(ownedTab.tabId, new ProtocolError("navigation_superseded", "A newer navigation superseded the pending observation."));
  const navigation = {};
  activeNavigations.set(ownedTab.tabId, navigation);
  const startedAt = new Date().toISOString();
  const timings = { startedAtMs: timingOrigin, dispatchedMs: null, committedMs: null,
    contentPresentMs: null, documentLoadedMs: null, readReturnedMs: null };
  let topDocument;
  let navigationDispatched = false;
  let cleanupError;
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
    // link clicks), so it would land one page too far. Attach failure refuses
    // the exact operation; no different history implementation runs.
    const history = payload.url === "back" || payload.url === "forward"
      ? (id) => stepTabHistory(id, payload.url, requireCurrentNavigation, () => {
        navigationDispatched = true; timings.dispatchedMs = pageLoads.now() - timingOrigin;
      }) : null;
    await requireCurrentNavigation();
    // Watch before dispatch, so a fast commit is not missed.
    topDocument = watchTopDocument(ownedTab.tabId, { requiresSite: /^https?:/.test(payload.url), timings });
    let updated;
    if (history) {
      const settlement = await history(ownedTab.tabId);
      cleanupError = settlement.cleanupError;
      updated = await chrome.tabs.get(ownedTab.tabId);
    } else {
      navigationDispatched = true;
      timings.dispatchedMs = pageLoads.now() - timingOrigin;
      updated = await chrome.tabs.update(ownedTab.tabId, { url: payload.url });
    }
    await requireCurrentNavigation();
    if (updated?.active === true) {
      await workspace.yieldForTab(ownedTab.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "Navigation unexpectedly activated the NativeAgent tab.");
    }
    const arrival = await waitForTabArrival(ownedTab.tabId, requireCurrentNavigation, actionId, topDocument);
    const tab = await chrome.tabs.get(ownedTab.tabId);
    const frame = topDocument.committedDocumentId
      ? await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: 0 }) : null;
    await requireCurrentNavigation();
    if (tab.active === true) {
      await workspace.yieldForTab(ownedTab.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "The tab became active before navigation could be confirmed.");
    }
    const loaded = tab.status === "complete" && tab.url === topDocument.completedUrl;
    const arrived = frame?.documentId && frame.documentId === topDocument.committedDocumentId && frame.url === tab.url
      && (arrival.by === "non_dom_committed" || pageLoads.arrival(ownedTab.tabId, frame.documentId));
    if (tab.id !== ownedTab.tabId || tab.pendingUrl || typeof tab.url !== "string" || (!loaded && !arrived)) {
      throw new ProtocolError("navigation_changed", "The exact tab no longer has an observed ready document.");
    }
    const result = pageActionResult({
      actionId, action: "navigate", ownedTab, payload, startedAt,
      outcome: "succeeded", verification: loaded ? "verified" : "not_verified",
      detail: {
        tabId: ownedTab.tabId, requestedUrl: payload.url,
        arrival: arrival.by,
        ...(topDocument.committedDocumentId ? { documentId: topDocument.committedDocumentId } : {}),
        ...(cleanupError ? { cleanupError } : {}),
        url: tab.url, title: tab.title ?? "", status: tab.status, verified: loaded,
        ...(loaded ? {} : { loading: "The document is ready; Chrome is still loading resources." }),
      },
    });
    result.receipt.timings = timings;
    return result;
  } catch (error) {
    // After dispatch, lost ownership or observation cannot prove navigation
    // did not happen. A cancellation before dispatch remains an honest refusal.
    const locked = tabStripLockError(error);
    if (locked || error.code === "tab_strip_locked") throw locked ?? error;
    const result = pageActionResult({
      actionId, action: "navigate", ownedTab, payload, startedAt,
      outcome: navigationDispatched ? "outcome_unknown" : "refused",
      verification: navigationDispatched ? "outcome_unknown" : "not_verified",
      detail: {
        tabId: ownedTab.tabId, requestedUrl: payload.url,
        status: navigationDispatched ? "outcome_unknown" : "not_performed", verified: false,
        error: { code: error.code ?? "navigation_reply_lost", message: error.message ?? "Chrome navigation could not be confirmed." },
        ...((cleanupError ?? error.details?.cleanupError) ? { cleanupError: cleanupError ?? error.details.cleanupError } : {}),
      },
    });
    result.receipt.timings = timings;
    return result;
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
  payload = { ...payload, scope: payload.scope ?? pageSnapshotViews.get(payload.tabId)?.scope ?? "page" };
  let ownedTab = await workspace.requireForPageAction(payload);
  requireActiveRequest(actionId);
  await waitForTabArrival(ownedTab.tabId, () => workspace.requireForPageAction(payload), actionId);
  ownedTab = await workspace.requireForPageAction(payload);
  if (payload.expectedURL && !readIdentityMatches({ expectedURL: payload.expectedURL }, ownedTab)) {
    throw new ProtocolError("page_agent_loading", "The navigation has not reached its current readable document yet.");
  }
  const internal = internalPageRead(ownedTab);
  if (internal) return internal;
  if (!/^https?:/.test(ownedTab.url ?? "")) {
    const picture = await lookAtTab(payload, actionId, { pictureReason: "This Chrome page has no DOM reader; reading the picture Chrome renders." });
    return picture;
  }
  const { document: evidence, documentId } = await readTopDocumentEvidence(ownedTab.tabId, actionId, payload.scope, payload);
  const kind = evidence.kind;
  await workspace.requireForPageAction(payload);
  requireActiveRequest(actionId);
  if (kind === "pdf" || kind === "image") {
    const picture = await lookAtTab(payload, actionId, {
      documentKind: kind, expectedDocumentId: documentId,
      pictureReason: "Reading Chrome's displayed " + kind + " document as a picture." });
    return picture;
  }
  return readDOMSnapshot(payload, actionId);
}

// Reader selection uses the current document evidence.
// A missing DOM reader is not evidence of an idle page; a positively identified
// PDF/image still selects its picture reader without needing a content agent.
async function readTopDocumentEvidence(tabId, actionId, scope = "page", expected = {}) {
  const frame = await chrome.webNavigation.getFrame({ tabId, frameId: 0 });
  if (!frame?.documentId) throw new ProtocolError("page_agent_loading", "Chrome has not identified the current document yet.");
  if (!readIdentityMatches(expected, frame)) {
    throw new ProtocolError("page_agent_loading", "The navigation's document identity and site have not reached the reader yet.");
  }
  const ready = readyPageFrames.get(tabId)?.get(0);
  let document;
  try {
    if (ready?.documentId !== frame.documentId) {
      // Chromium's webNavigation filters chrome-extension:// viewer URLs
      // (FrameNavigationState::IsValidUrl). Read the exact top document's
      // contentType instead: Blink's Document::contentType reads its loader MIME
      // even when MimeHandlerView renders a PDF inside an HTML wrapper.
      const contentType = await readDocumentContentType(tabId, frame.documentId);
      if (contentType === "application/pdf") document = { kind: "pdf", status: "unread" };
      else if (contentType.startsWith("image/")) document = { kind: "image" };
      else await waitForTabArrival(tabId, () => workspace.requireTab(tabId), actionId, undefined, frame.documentId);
    }
    if (!document) {
      document = await sendPageMessage(tabId,
        { type: "nativeagent.page.document", actionId, scope }, { documentId: frame.documentId });
      if (!["dom", "image", "pdf"].includes(document?.kind)
        || (document.kind === "dom" && (typeof document.busy !== "boolean"
          || (document.busy && (typeof document.busyReason !== "string" || !document.busyReason))))) {
        throw new ProtocolError("page_document_unavailable", "The current page reader did not return document and busy evidence.");
      }
    }
  } catch (error) {
    // Either exact-document read can lose its document before replying.
    // Preserve cancellation/authority and malformed evidence; a transport
    // failure becomes a replacement signal only when Chrome proves the change.
    if (error instanceof ProtocolError && error.code !== "page_agent_unavailable") throw error;
    const current = await chrome.webNavigation.getFrame({ tabId, frameId: 0 });
    if (current?.documentId !== frame.documentId) {
      throw new ProtocolError("page_changed", `The document changed during reader selection: ${error.message}`);
    }
    throw error;
  }
  const current = await chrome.webNavigation.getFrame({ tabId, frameId: 0 });
  if (current?.documentId !== frame.documentId) throw new ProtocolError("page_changed", "The document changed before its reader was selected.");
  return { document, documentId: frame.documentId, url: frame.url };
}

async function readDocumentContentType(tabId, documentId) {
  const evidence = await chrome.scripting.executeScript({
    target: { tabId, documentIds: [documentId] },
    injectImmediately: true,
    func: () => document.contentType,
  });
  const mime = evidence.find(result => result.frameId === 0 && result.documentId === documentId);
  if (typeof mime?.result !== "string" || !mime.result) {
    throw new ProtocolError("page_document_unavailable", "Chrome did not return the admitted top document's content type; no reader was selected.");
  }
  return mime.result;
}

async function readDOMSnapshot(payload, actionId) {
  const ownedTab = await workspace.requireForPageAction(payload);
  // Read the current ready document once, with no content quiet interval.
  const frame = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: 0 });
  const ready = readyPageFrames.get(ownedTab.tabId)?.get(0);
  if (!frame || !ready || ready.documentId !== frame.documentId) {
    throw new ProtocolError("page_agent_loading", "The current Chrome document has not reported DOM readiness yet.");
  }
  if (!readIdentityMatches(payload, frame)) {
    throw new ProtocolError("page_agent_loading", "The navigation's current document has not reached the reader yet.");
  }
  const tab = await chrome.tabs.get(ownedTab.tabId);
  await workspace.requireForPageAction(payload);
  const loaded = tab.status === "complete" && !tab.pendingUrl;
  const previousView = pageSnapshotViews.get(ownedTab.tabId);
  payload = { ...(!payload.find && previousView?.readCursor ? { readCursor: previousView.readCursor } : {}), ...payload };
  invalidateTabSnapshots(ownedTab.tabId, false);
  requireActiveRequest(actionId);
  const capture = beginSnapshotCapture(ownedTab.tabId, { actionId });
  try {
    const snapshot = await readStructuredSnapshotForCapture(payload, ownedTab, capture);
    if (!readIdentityMatches(payload, snapshot)) {
      throw new ProtocolError("page_changed", "The navigation's document changed during capture; no different page was served.");
    }
    await requireCurrentSnapshotCapture(ownedTab, capture);
    const cursor = payload.readCursor;
    publishCurrentSnapshotCapture(ownedTab, capture, () => pageSnapshotViews.set(ownedTab.tabId, {
      maxNodes: payload.maxNodes ?? DEFAULT_SNAPSHOT_NODES, maxTextChars: payload.maxTextChars ?? DEFAULT_SNAPSHOT_TEXT_CHARS,
      scope: payload.scope ?? "page",
      // Keep the scroller, never the point reached by a one-off read-more.
      ...(cursor?.viewportObservationId && snapshot.reading.viewportObservationId === cursor.viewportObservationId ? { readCursor: {
        url: cursor.url, frameURL: cursor.frameURL, frameId: cursor.frameId,
        tabId: ownedTab.tabId, documentId: snapshot.documentId, readLayer: "content",
        frameDocumentId: cursor.frameDocumentId,
        viewportObservationId: cursor.viewportObservationId,
      } } : {}),
    }));
    // Retain the successful reader's exact view durably before its reply,
    // without another page read. Writes serialize across tabs.
    await persistPageViews(ownedTab);
    await requireCurrentSnapshotCapture(ownedTab, capture);
    return publishCurrentSnapshotCapture(ownedTab, capture, () => {
      snapshot.reading.pageMoved ||= snapshotCaptureMoved(capture);
      return { ...snapshot, rendering: { ...snapshot.rendering, loaded } };
    });
  } finally {
    if (activeSnapshotReads.get(ownedTab.tabId) === capture) activeSnapshotReads.delete(ownedTab.tabId);
    void drainSiteChanges(ownedTab.tabId);
  }
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return "[" + value.map(canonicalJSON).join(",") + "]";
  if (value && typeof value === "object") {
    return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonicalJSON(value[key])).join(",") + "}";
  }
  return JSON.stringify(value) ?? "null";
}

function persistPageViews(ownedTab) {
  viewWrites = viewWrites.catch(() => {}).then(async () => {
    const views = Object.fromEntries([...pageSnapshotViews].filter(([id]) => workspace.tabs.has(id)));
    const stored = await chrome.storage.session.get(PAGE_VIEW_STORAGE_KEY);
    // Chrome returns stored objects with sorted keys; compare by value, not by key order.
    if (canonicalJSON(stored[PAGE_VIEW_STORAGE_KEY]) === canonicalJSON(views)) return;
    await chrome.storage.session.set({ [PAGE_VIEW_STORAGE_KEY]: views });
  });
  void viewWrites.catch((error) => sendEvent("page.change_unavailable", {
    tabId: ownedTab.tabId, userSequence: ownedTab.userSequence,
    error: { code: "page_view_persistence_failed", message: String(error.message ?? "The page change view could not be retained.").slice(0, 1_024) },
  }));
  return viewWrites;
}

function beginSnapshotCapture(tabId, properties) {
  cancelSnapshotCapture(tabId);
  if (!pageDocumentGenerations.has(tabId)) pageDocumentGenerations.set(tabId, Symbol());
  const capture = { ...properties, id: crypto.randomUUID(), documentGeneration: pageDocumentGenerations.get(tabId),
    invalidatedFrameIds: new Set(), localSnapshotKeys: new Set(), invalidatedSnapshotKeys: new Set(), invalidationOverflow: false };
  activeSnapshotReads.set(tabId, capture);
  return capture;
}

// The check and publication share one continuation: no commit can run between
// them. Every caller finishes its asynchronous ownership check before entering.
function publishCurrentSnapshotCapture(ownedTab, capture, publish) {
  requireActiveRequest(capture.actionId);
  capture.requireOpen?.();
  const current = activeSnapshotReads.get(ownedTab.tabId);
  // Replacement owns the interruption even if its passive read already began.
  // Only a newer capture of this same document makes the interrupted read yield.
  if (pageDocumentGenerations.get(ownedTab.tabId) !== capture.documentGeneration) {
    throw new ProtocolError("snapshot_superseded", "A document change superseded this snapshot capture.", { reason: "document_changed" });
  }
  if (current !== capture) {
    throw new ProtocolError("snapshot_superseded", "A newer read superseded this snapshot capture.", { reason: "newer_read" });
  }
  return publish();
}

async function requireCurrentSnapshotCapture(ownedTab, capture) {
  await workspace.requireForPageAction({ tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence });
  publishCurrentSnapshotCapture(ownedTab, capture, () => {});
}

function snapshotCaptureMoved(capture) {
  return capture.invalidatedFrameIds.size > 0 || capture.invalidationOverflow
    || [...capture.localSnapshotKeys].some((key) => capture.invalidatedSnapshotKeys.has(key));
}

async function readStructuredSnapshotForCapture(payload, ownedTab, capture) {
  const maxNodes = payload.maxNodes ?? DEFAULT_SNAPSHOT_NODES;
  const maxTextChars = payload.maxTextChars ?? DEFAULT_SNAPSHOT_TEXT_CHARS;
  const discovered = await chrome.webNavigation.getAllFrames({ tabId: ownedTab.tabId });
  await requireCurrentSnapshotCapture(ownedTab, capture);
  const ordered = [...(discovered ?? [])].sort((left, right) => {
    if (left.frameId === 0) return -1;
    if (right.frameId === 0) return 1;
    return left.frameId - right.frameId;
  });
  const documentReplaced = payload.readCursor && payload.readCursor.documentId !== ordered.find(frame => frame.frameId === 0)?.documentId;
  if (documentReplaced) payload = { ...payload, readCursor: undefined };
  let pageMoved = Boolean(documentReplaced);
  const find = payload.find ?? payload.readCursor?.find;
  let cursorFrame = payload.readCursor?.frameId ?? 0;
  if (payload.readCursor && !ordered.some(frame => frame.frameId === cursorFrame)) {
    pageMoved = true;
    payload = { ...payload, readCursor: undefined };
    cursorFrame = 0;
  }
  if (payload.readCursor && payload.readCursor.frameDocumentId !== ordered.find(frame => frame.frameId === cursorFrame)?.documentId) {
    pageMoved = true;
    payload = { ...payload, readCursor: { url: payload.readCursor.url,
      tabId: ownedTab.tabId, documentId: payload.readCursor.documentId,
      frameId: cursorFrame, frameDocumentId: ordered.find(frame => frame.frameId === cursorFrame)?.documentId,
      readLayer: "content", ...(find ? { find } : {}) } };
  }
  const frames = [];
  const localSnapshots = [];
  let remainingNodes = maxNodes;
  let remainingText = maxTextChars;
  let topSnapshot = null;
  let finding = find;
  let readMore = null;
  let truncationReasonsForFrames = false;

  const cursorLayer = payload.readCursor?.readLayer ?? "content";
  // Content from every admitted frame spends the budget before any dialog.
  // The phase travels in the cursor, so a folded iframe never strands a cover.
  const jobs = ["content", "overlay"].flatMap(readLayer => ordered.map(frame => ({ frame, readLayer })));
  function recordFrame(value) {
    const previous = frames.find(frame => frame.frameId === value.frameId);
    if (previous) Object.assign(previous, value, { nodeCount: previous.nodeCount + value.nodeCount,
      accessible: previous.accessible || value.accessible });
    else frames.push(value);
  }
  for (const { frame, readLayer } of jobs) {
    const identityOnly = frame.frameId === 0 && readLayer === "content" && payload.readCursor
      && (cursorFrame !== 0 || cursorLayer !== "content");
    if (payload.readCursor && !identityOnly && ((cursorLayer === "overlay" && readLayer === "content")
      || (readLayer === cursorLayer && ordered.findIndex(f => f.frameId === frame.frameId) < ordered.findIndex(f => f.frameId === cursorFrame)))) continue;
    await requireCurrentSnapshotCapture(ownedTab, capture);
    if (!frame.documentId) {
      const error = { code: "frame_document_unavailable", message: "Chrome supplied no identity for this frame's document." };
      if (frame.frameId === 0 || payload.readCursor?.frameId === frame.frameId) throw new ProtocolError(error.code, error.message);
      recordFrame({ frameId: frame.frameId, parentFrameId: frame.parentFrameId, url: frame.url ?? "", name: "",
        accessible: false, nodeCount: 0, error });
      continue;
    }
    if (remainingNodes <= 0) {
      recordFrame({
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
    let local;
    try {
      if (capture.invalidatedFrameIds.has(frame.frameId)) {
        throw new ProtocolError("frame_document_changed", "This embedded document changed during capture; its siblings were retained.");
      }
      for (let parent = ordered.find(other => other.frameId === frame.parentFrameId); parent;
        parent = ordered.find(other => other.frameId === parent.parentFrameId)) {
        if (!READER_FRAME.test(parent.url ?? "")) throw new ProtocolError("frame_unreadable", "This embedded document sits inside a frame Chrome gives no reader; its siblings were retained.");
      }
      if ((capture.passive || frame.frameId === 0) && /^https?:/.test(frame.url ?? "")) {
        const ready = readyPageFrames.get(ownedTab.tabId)?.get(frame.frameId);
        if (!ready || ready.documentId !== frame.documentId) {
          throw new ProtocolError("page_agent_loading", "This frame has not reported readiness for its current document.", { frameId: frame.frameId });
        }
      }
      local = await sendPageMessage(ownedTab.tabId, {
        type: "nativeagent.page.snapshot",
        actionId: capture.actionId ?? capture.id,
        tabId: ownedTab.tabId,
        userSequence: ownedTab.userSequence,
        passive: capture.passive === true,
        captureId: capture.id, readLayer, identityOnly: Boolean(identityOnly),
        maxNodes: remainingNodes,
        maxTextChars: Math.max(1, remainingText),
        scope: payload.scope ?? "page",
        ...(finding ? { find: finding } : {}),
        ...(payload.readCursor && frame.frameId === cursorFrame && readLayer === cursorLayer ? { readCursor: payload.readCursor } : {}),
      }, { documentId: frame.documentId });
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
      recordFrame({
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
    if (frame.frameId === 0 && readLayer === "content") topSnapshot = local;
    if (frame.frameId === 0 && payload.readCursor && payload.readCursor.url !== local.url) {
      pageMoved = true;
      payload = { ...payload, readCursor: undefined };
      cursorFrame = 0;
    }
    if (identityOnly) {
      // Keep the top document's identity, without replaying its text window.
      remainingNodes += nodes.length; remainingText += text.length;
      continue;
    }
    // An identity-only top capture above cannot consume the pending search.
    if (local.reading?.find?.matched === true) finding = undefined;
    localSnapshots.push({ frame, local, readLayer });
    recordFrame({
      frameId: frame.frameId,
      parentFrameId: frame.parentFrameId,
      url: local.frame?.url ?? frame.url ?? "",
      name: local.frame?.name ?? "",
      accessible: true,
      nodeCount: nodes.length,
    });
    // A control continuation reads only that control, including in an inner
    // frame. Its own folded content must not replay the rest of the document.
    if (payload.readCursor?.elementOnly === true && frame.frameId === cursorFrame && readLayer === cursorLayer) break;
    if (local.readMore) {
      readMore = { ...local.readMore, readLayer, url: topSnapshot?.url ?? local.url, frameURL: local.url,
        frameId: frame.frameId, frameDocumentId: frame.documentId };
      break;
    }
    const nextJob = jobs[jobs.findIndex(job => job.frame === frame && job.readLayer === readLayer) + 1];
    const nextFrame = nextJob?.frame;
    if ((remainingNodes <= 0 || remainingText <= 0 || frames.length >= MAX_SNAPSHOT_FRAMES) && nextFrame) {
      if (frames.length >= MAX_SNAPSHOT_FRAMES) truncationReasonsForFrames = true;
      readMore = { url: topSnapshot?.url ?? local.url, frameURL: nextFrame.url, frameId: nextFrame.frameId, readLayer: nextJob.readLayer,
        frameDocumentId: nextFrame.documentId,
        ...(finding ? { find: finding } : {}), name: "Embedded page" };
      break;
    }
  }

  if (!topSnapshot) {
    throw new ProtocolError("top_frame_unavailable", "The structured page agent is unavailable in the top frame.");
  }
  const snapshotId = crypto.randomUUID();
  const nodes = [];
  const routes = new Map();
  const truncationReasons = [];
  const documentId = ordered.find(frame => frame.frameId === 0)?.documentId;
  for (const { frame, local, readLayer } of localSnapshots) {
    const localToGlobal = new Map();
    for (const localNode of local.nodes ?? []) {
      const globalNodeId = `n${routes.size + 1}`;
      localToGlobal.set(localNode.nodeId, globalNodeId);
      routes.set(globalNodeId, {
        frameId: frame.frameId,
        documentId: frame.documentId,
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
        ...(localNode.more ? { more: { ...localNode.more, tabId: ownedTab.tabId, documentId, readLayer, url: topSnapshot.url,
          frameURL: local.url, frameId: frame.frameId, frameDocumentId: frame.documentId } } : {}),
        parentNodeId: localToGlobal.get(localNode.parentNodeId) ?? null,
        frameId: frame.frameId,
        frameDocumentId: frame.documentId,
      });
    }
    for (const reason of local.summary?.truncationReasons ?? []) truncationReasons.push(reason);
  }
  if (truncationReasonsForFrames) truncationReasons.push("frame_limit");
  if (frames.some((frame) => frame.error)) truncationReasons.push("frame_unavailable");
  if (remainingNodes <= 0) truncationReasons.push("node_limit");
  if (remainingText <= 0) truncationReasons.push("text_limit");
  const presentationNodes = nodes;
  const joinedSummary = presentationNodes.filter(node => !node.inlineProof).map(node => node.text || node.name).filter(Boolean).join("\n");
  if (joinedSummary.length > maxTextChars) truncationReasons.push("text_limit");
  const summaryText = joinedSummary.slice(0, maxTextChars);
  const { frame: _topFrameMetadata, ...topPage } = topSnapshot;
  const result = boundSnapshotForTransport({
    ...topPage,
    snapshotId,
    documentId,
    reading: {
      scope: payload.scope ?? "page",
      mainContentAvailable: localSnapshots.some(({ local }) => local.reading?.mainContentAvailable === true),
      sections: [...new Set(localSnapshots.flatMap(({ local }) => local.reading?.sections ?? []))],
      maxNodes,
      maxTextChars,
      transportByteLimit: MAX_SNAPSHOT_RESULT_BYTES,
      cursor: payload.readCursor ?? null,
      ...(find ? { find: {
        text: find,
        matched: localSnapshots.some(({ local }) => local.reading?.find?.matched === true),
        walkLimited: localSnapshots.some(({ local }) => local.reading?.find?.walkLimited === true),
      } } : {}),
      fromViewport: true,
      pageMoved: pageMoved || localSnapshots.some(({ local }) => local.reading?.pageMoved === true),
      viewportObservationId: localSnapshots.find(({ frame }) => frame.frameId === cursorFrame)?.local.reading?.viewportObservationId ?? null,
      ...(payload.readCursor?.viewportObservationId ? {
        viewportChanged: localSnapshots.find(({ frame }) => frame.frameId === cursorFrame)?.local.reading?.viewportChanged ?? null,
      } : {}),
    },
    nodes,
    readMore: readMore ? { ...readMore, tabId: ownedTab.tabId, documentId } : null,
    frames,
    summary: {
      text: summaryText,
      nodeCount: nodes.length,
      truncated: truncationReasons.length > 0 || frames.some((frame) => !frame.accessible),
      truncationReasons: [...new Set(truncationReasons)],
      gaps: [...frames.filter(frame => frame.error).map(frame => ({ frameId: frame.frameId, url: frame.url, ...frame.error })),
        ...localSnapshots.flatMap(({ frame, local }) => {
          const gaps = local.summary?.gaps;
          const unidentified = evidence => ({ frameId: frame.frameId, url: frame.url, evidence });
          if (!Array.isArray(gaps)) return [unidentified(gaps)];
          return gaps.map(gap => gap && typeof gap === "object" && !Array.isArray(gap)
            ? { ...gap, frameId: frame.frameId, url: frame.url } : unidentified(gap));
        })],
    },
  }, routes, MAX_SNAPSHOT_RESULT_BYTES);
  // Capture order is delivery order, including the cross-frame overlay phase.
  await requireCurrentSnapshotCapture(ownedTab, capture);
  return publishCurrentSnapshotCapture(ownedTab, capture, () => {
    result.reading.pageMoved ||= snapshotCaptureMoved(capture);
    // A moved page is readable evidence, but an invalidated node is still no
    // authority to act. Mutation notices before route publication count too.
    for (const [id, route] of [...routes]) {
      const key = JSON.stringify([route.frameId, route.localSnapshotId]);
      if (capture.invalidatedFrameIds.has(route.frameId) || capture.invalidationOverflow || (capture.invalidatedSnapshotKeys.has(key)
        && !capture.retainedNavigationNodes?.get(key)?.includes(route.localNodeId))) routes.delete(id);
    }
    snapshotRoutes.set(snapshotId, {
      tabId: ownedTab.tabId,
      userSequence: ownedTab.userSequence,
      passive: capture.passive === true,
      routes,
    });
    return result;
  });
}


async function clickSnapshotNode(payload, actionId) {
  if (payload.button !== undefined && payload.button !== "left") {
    throw new ProtocolError("button_not_supported", "Structured page clicks currently support the left button only.");
  }
  return mutateRoutedNode(payload, actionId, "click", "nativeagent.page.click", { button: payload.button ?? "left" });
}

async function fillSnapshotNode(payload, actionId) {
  return trustedInput(payload, actionId, "fill");
}

async function typeIntoSnapshotNode(payload, actionId) {
  return trustedInput(payload, actionId, "type");
}

async function selectSnapshotNode(payload, actionId) {
  return mutateRoutedNode(payload, actionId, "select", "nativeagent.page.select", { values: payload.values });
}

async function keypressSnapshotNode(payload, actionId) {
  return trustedInput(payload, actionId, "keypress");
}

async function trustedInput(payload, actionId, action) {
  const ownedTab = await workspace.requireForPageAction(payload);
  const route = requireSnapshotRoute(ownedTab, payload);
  if (!route.documentId) throw new ProtocolError("snapshot_stale", "Read the exact document before sending input.");
  if (trustedInputs.has(ownedTab.tabId)) throw new ProtocolError("input_busy", "Another input action is still settling on this tab.");
  trustedInputs.set(ownedTab.tabId, actionId);
  activePageActions.set(actionId, ownedTab.tabId);
  const startedAt = new Date().toISOString(), deadline = Date.now() + 20_000;
  const requested = action === "fill" ? payload.value : action === "type" ? payload.text : "";
  let sentText = "", inputMode = "chrome_trusted", effectDispatched = false, inputInFlight = false, prepared = false, detail = {}, failure, cleanupError, keyReleaseError;
  const page = async (operation, extra = {}) => {
    const response = await chrome.tabs.sendMessage(ownedTab.tabId, {
      type: "nativeagent.page.input." + operation, actionId, action,
      tabId: ownedTab.tabId, userSequence: ownedTab.userSequence,
      snapshotId: route.localSnapshotId, nodeId: route.localNodeId, ...extra,
    }, { documentId: route.documentId });
    if (!response?.ok) throw new ProtocolError(response?.error?.code ?? "input_reply_lost",
      response?.error?.message ?? "The exact input document did not acknowledge the operation.");
    return response.result;
  };
  const admit = async (settling = false, dispatch = () => {}) => {
    await workspace.requireForPageAction(payload);
    // Finish custody/attach/focus waits before the final identity read. An
    // input dispatch runs in this continuation: no await may follow this read.
    const frame = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: route.frameId });
    // Revocation events can run during getFrame; read the workspace owner's
    // current sequence synchronously rather than starting another custody wait.
    if (workspace.tabForId(ownedTab.tabId)?.userSequence !== ownedTab.userSequence) {
      throw new ProtocolError("tab_not_owned", "The tab's custody ended during input admission; no further input was sent.");
    }
    if (!settling) requireActiveRequest(actionId);
    if (frame?.documentId !== route.documentId) throw new ProtocolError("page_changed", "The admitted input document changed; no further input was sent.");
    if (!settling && Date.now() >= deadline) throw new ProtocolError("execution_deadline", "The input deadline ended; inspect the retained text before continuing.");
    return dispatch();
  };
  try {
    await admit();
    prepared = true;
    const target = await page("prepare", { value: payload.value });
    if (target.mode === "atomic") {
      inputMode = "native_value";
      await admit();
      effectDispatched = true;
      detail = await page("atomic", { value: payload.value });
      sentText = requested;
    }
    else {
      const settlement = await withDebuggerSession(ownedTab.tabId, admit, async debuggerTarget => {
        // Every Input.* command, including key-up settlement, goes through this
        // owner. Nothing suspends between final admission and dispatch.
        const sendInput = (method, event, { settling = false, onDispatch = () => {} } = {}) => admit(settling, () => {
          effectDispatched = true;
          onDispatch();
          return chrome.debugger.sendCommand(debuggerTarget, method, event);
        });
        await admit();
        const focused = await page("focus");
        const press = async key => {
          const spec = trustedKeyEvents(key);
          let downDispatched = false, pressFailure;
          try {
            await page("check", { expectedKeydown: spec.expectedKeydown });
            await sendInput("Input.dispatchKeyEvent", spec.events[0], { onDispatch: () => { downDispatched = true; } });
          } catch (error) { pressFailure = error; }
          finally {
            // Stop ends text/default work, never the release of a key already
            // sent. Release only in the same document under current custody.
            if (downDispatched) try {
              await page("keyup");
              await sendInput("Input.dispatchKeyEvent", spec.events.at(-1), { settling: true });
            } catch (error) {
              keyReleaseError = { code: error.code ?? "key_release_failed", message: String(error.message ?? error) };
              if (!pressFailure) pressFailure = error;
            }
          }
          if (pressFailure) throw pressFailure;
        };
        if (action === "keypress") await press(payload.key);
        else {
          if (focused.selection === "native_selection") await press(action === "fill" ? "Meta+A" : "Meta+ArrowRight");
          if (action === "fill" && requested === "") await press("Backspace");
          else {
            const chunks = action === "type" && payload.delayMs > 0 ? Array.from(requested) : [requested];
            for (let index = 0; index < chunks.length; index++) {
              if (!chunks[index]) continue;
              await page("check");
              await sendInput("Input.insertText", { text: chunks[index] }, { onDispatch: () => { inputInFlight = true; } });
              sentText += chunks[index];
              inputInFlight = false;
              if (index + 1 < chunks.length && payload.delayMs > 0) await waitInputDelay(payload.delayMs, actionId);
            }
          }
        }
      }, { focus: true });
      cleanupError = settlement.cleanupError;
    }
  } catch (error) {
    failure = { code: error.code ?? "trusted_input_failed", message: String(error.message ?? error) };
    cleanupError = error.details?.cleanupError;
  } finally {
    // Read and release the retained target even after Stop. No new effect or
    // substitute node is used for settlement.
    if (prepared && detail.mode !== "atomic") {
      try { detail = await page("readback", { sentText: inputMode === "native_value" ? requested : sentText }); }
      catch (error) { detail = { outcome: "outcome_unknown", verification: "outcome_unknown",
        readbackError: { code: error.code ?? "input_readback_unavailable", message: String(error.message ?? error) } }; }
    }
    if (prepared) {
      try { await page("release"); }
      catch (error) { detail.targetReleaseError = { code: "input_target_release_failed", message: String(error.message ?? error) }; }
    }
    trustedInputs.delete(ownedTab.tabId);
  }
  const completed = !failure && detail.outcome === "succeeded"
    && (action === "keypress" || detail.mode === "atomic" || sentText === requested);
  const partial = failure && action === "type" && !inputInFlight && sentText.length > 0 && sentText !== requested && detail.landed === "landed";
  const outcome = partial ? "partially_completed" : failure ? (effectDispatched ? "outcome_unknown" : "refused") : detail.outcome;
  return pageActionResult({ actionId, action, ownedTab, payload, startedAt,
    outcome, verification: partial ? "page_acknowledged" : failure ? (effectDispatched ? "outcome_unknown" : "not_verified") : detail.verification,
    detail: { ...detail, snapshotId: payload.snapshotId, nodeId: payload.nodeId, frameId: route.frameId,
      input: inputMode, completed, dispatched: effectDispatched,
      ...(action === "keypress" ? { key: payload.key } : { characterCount: Array.from(sentText).length,
        requestedCharacterCount: Array.from(requested).length, nextUTF16Offset: sentText.length,
        characterUnit: "unicode_code_point" }),
      ...(failure ? { error: failure } : {}), ...(keyReleaseError ? { keyReleaseError } : {}),
      ...(cleanupError ? { cleanupError } : {}) } });
}

function waitInputDelay(milliseconds, actionId) {
  return new Promise((resolve, reject) => {
    const finish = error => {
      clearTimeout(timer);
      activeRequestWaits.delete(actionId);
      if (error) reject(error); else resolve();
    };
    const timer = setTimeout(() => finish(), milliseconds);
    activeRequestWaits.set(actionId, finish);
    try { requireActiveRequest(actionId); } catch (error) { finish(error); }
  });
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
    const settlement = await waitForReadablePage(ownedTab.tabId, timeoutMs,
      () => workspace.requireForPageAction(payload), actionId,
      { settleMs: payload.settleMs ?? 0, scope: payload.scope ?? "page",
        expectedDocumentId: payload.expectedDocumentId, expectedURL: payload.expectedURL });
    const tab = await chrome.tabs.get(ownedTab.tabId);
    await workspace.requireForPageAction(payload);
    const complete = tab.id === ownedTab.tabId && tab.status === "complete" && !tab.pendingUrl;
    const matched = !tab.pendingUrl && settlement.matched;
    return pageActionResult({
      actionId,
      action: "wait",
      ownedTab,
      payload,
      startedAt,
      outcome: matched ? "succeeded" : "not_settled",
      verification: matched ? "verified" : "not_verified",
      detail: {
        condition: payload.condition,
        matched,
        documentId: settlement.documentId,
        reason: tab.pendingUrl ? "Chrome still has a pending URL." : settlement.reason,
        loaded: complete,
        url: tab.url ?? "",
        title: tab.title ?? "",
      },
    });
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

function cleanupFailure(error) {
  return { code: "debugger_release_failed", message: String(error.message ?? error) };
}

function retainCleanup(error, cleanupError) {
  if (!cleanupError) return error;
  const failure = error instanceof ProtocolError ? error
    : new ProtocolError("debugger_operation_failed", String(error.message ?? error));
  failure.details = { ...failure.details, cleanupError };
  failure.message += " Debugger release also failed: " + cleanupError.message;
  return failure;
}

// Her tab renders while she works on it, as a shown tab does: a hidden tab runs no animation frames, scroll or intersection
// callbacks, so a feed never loads more. One debugger session holds focus emulation until she has left the tab alone for
// RENDER_HOLD_MS, her ownership ends, or the person cancels it from Chrome's bar, which stands until the extension restarts.
const RENDER_HOLD_MS = 60_000;
const renderHolds = new Map();
let renderCanceled = false;

function keepRendering(tabId) {
  if (renderCanceled) return Promise.resolve();
  let hold = renderHolds.get(tabId);
  if (!hold) {
    const target = { tabId };
    hold = { timer: null, ready: chrome.debugger.attach(target, "1.3")
      .then(() => chrome.debugger.sendCommand(target, "Emulation.setFocusEmulationEnabled", { enabled: true })) };
    renderHolds.set(tabId, hold);
    const held = hold;
    held.ready.catch(error => {
      if (renderHolds.get(tabId) === held) { clearTimeout(held.timer); renderHolds.delete(tabId); }
      recordNativeError(error.message ?? String(error));
    });
  }
  clearTimeout(hold.timer);
  hold.timer = setTimeout(() => endRendering(tabId), RENDER_HOLD_MS);
  // A tab that cannot be held still loads and reads as a hidden one.
  return hold.ready.catch(() => {});
}

function endRendering(tabId) {
  const hold = renderHolds.get(tabId);
  if (!hold) return;
  clearTimeout(hold.timer);
  renderHolds.delete(tabId);
  void hold.ready.then(() => chrome.debugger.detach({ tabId })).catch(() => {});
}

chrome.debugger.onDetach.addListener(({ tabId }, reason) => {
  if (reason === "canceled_by_user") renderCanceled = true;
  const hold = renderHolds.get(tabId);
  if (hold) { clearTimeout(hold.timer); renderHolds.delete(tabId); }
});

async function keepOwnedTabRendering(payload) {
  try { await keepRendering((await workspace.requireForPageAction(payload)).tabId); }
  catch { /* The action itself reports a tab that is not hers. */ }
}

// One debugger lease per operation, on her tab's held session when it has one. Settlement never replaces the effect.
async function withDebuggerSession(tabId, admit, body, { focus = false } = {}) {
  await admit();
  const target = { tabId };
  await renderHolds.get(tabId)?.ready.catch(() => {});
  const held = renderHolds.has(tabId);
  if (!held) await chrome.debugger.attach(target, "1.3");
  let value, error, cleanupError;
  try {
    await admit();
    if (focus && !held) await renderWhileHidden(target, admit);
    value = await body(target);
  } catch (failure) { error = failure; }
  finally {
    if (!held) {
      try { await chrome.debugger.detach(target); }
      catch (failure) { cleanupError = cleanupFailure(failure); }
    }
  }
  if (error) {
    throw retainCleanup(error, cleanupError);
  }
  return { value, cleanupError };
}

// The entry beside the current one in this tab's own history, by id, so a
// page reached by a scripted click is not skipped (Chrome's history
// manipulation intervention marks such entries skippable for tabs.goBack).
async function stepTabHistory(tabId, direction, admit, dispatched) {
  return withDebuggerSession(tabId, admit, async target => {
    await admit();
    const { currentIndex, entries } = await chrome.debugger.sendCommand(target, "Page.getNavigationHistory");
    const entry = entries?.[currentIndex + (direction === "back" ? -1 : 1)];
    if (!entry) throw new ProtocolError("history_unavailable", "This tab has no " + direction + " entry to go to.");
    await admit();
    dispatched();
    await chrome.debugger.sendCommand(target, "Page.navigateToHistoryEntry", { entryId: entry.id });
  });
}

async function lookAtTab(payload, actionId, { pictureReason, documentKind, expectedDocumentId } = {}) {
  const ownedTab = await workspace.requireForPageAction(payload);
  requireActiveRequest(actionId);
  const internal = internalPageRead(ownedTab);
  if (internal) return internal;
  const frame = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: 0 });
  const documentId = expectedDocumentId ?? frame?.documentId;
  const admit = async () => {
    await workspace.requireForPageAction(payload);
    const current = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: 0 });
    requireActiveRequest(actionId);
    if (!documentId || current?.documentId !== documentId) throw new ProtocolError("page_changed", "The exact picture document changed.");
  };
  let geometry = null;
  const settlement = await withDebuggerSession(ownedTab.tabId, admit, async target => {
    let capture;
    try {
      // The picture is bounded where it is taken: the visible viewport, scaled so
      // its long side is at most LOOK_MAX_PIXELS device pixels (what the image
      // slot shows anyway), so a Retina tab is not refused for its size.
      await admit();
      const { cssVisualViewport: viewport } = await chrome.debugger.sendCommand(target, "Page.getLayoutMetrics");
      await admit();
      const { result: ratio } = await chrome.debugger.sendCommand(target, "Runtime.evaluate",
        { expression: "window.devicePixelRatio", returnByValue: true });
      const dpr = Number(ratio?.value) > 0 ? Number(ratio.value) : 1;
      const width = Math.max(1, Math.round(viewport?.clientWidth ?? 0));
      const height = Math.max(1, Math.round(viewport?.clientHeight ?? 0));
      const scale = Math.min(1, LOOK_MAX_PIXELS / (Math.max(width, height) * dpr));
      await admit();
      if (payload.screenPreviewMaxWidth !== undefined) {
        geometry = await readPicturePreviewGeometry(target, { ...viewport, clientWidth: width, clientHeight: height });
      }
      capture = await chrome.debugger.sendCommand(target, "Page.captureScreenshot", {
        format: "jpeg", quality: 85, fromSurface: true,
        clip: { x: viewport?.pageX ?? 0, y: viewport?.pageY ?? 0, width, height, scale },
      });
      if (typeof capture?.data !== "string" || !capture.data.length) throw new Error("No picture data.");
    } catch (error) {
      if (error instanceof ProtocolError) throw error;
      throw new ProtocolError("tab_not_painted", "Chrome did not render this hidden tab for a picture. Nothing was changed; the tab was not activated.");
    }
    return capture;
  });
  const { value: capture, cleanupError } = settlement;
  try {
    if (capture.data.length * 3 / 4 > LOOK_MAX_JPEG_BYTES) {
      throw new ProtocolError("picture_too_large", "Chrome's picture exceeds the image slot's 8 MiB; it was not delivered. Nothing was changed; the tab was not activated.");
    }
    const bitmap = await createImageBitmap(new Blob([
      Uint8Array.from(atob(capture.data), character => character.charCodeAt(0)),
    ], { type: "image/jpeg" }));
    const { width, height } = bitmap;
    bitmap.close();
    // A picture captured while the person took this tab is never delivered.
    await admit();
    const tab = await workspace.requireForPageAction(payload);
    return { tabId: tab.tabId, url: tab.url, title: tab.title,
      userSequence: tab.userSequence, width, height, format: "jpeg", data: capture.data,
      ...(payload.screenPreviewMaxWidth === undefined ? {} : { geometry }),
      ...(cleanupError ? { cleanupError } : {}),
      ...(documentKind ? { document: { kind: documentKind, status: "unread" } } : {}),
      ...(pictureReason ? { reading: { mode: "picture", reason: pictureReason, domAccessible: false } } : {}) };
  } catch (error) { throw retainCleanup(error, cleanupError); }
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
  const perform = async () => {
    const topDocument = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: 0 });
    if (!topDocument?.documentId) throw new ProtocolError("page_changed", "Chrome has not identified the document for this scroll.");
    const frameDocumentId = route.frameId === 0 ? topDocument.documentId : route.documentId;
    if (!frameDocumentId) throw new ProtocolError("frame_document_unavailable", "The scroll target has no admitted frame document.");
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
      result.readCursor = { ...result.readCursor, url: tab.url, tabId: ownedTab.tabId,
        documentId: topDocument.documentId, readLayer: "content",
        frameDocumentId,
        frameURL: result.readCursor.url, frameId: route.frameId };
    }
    return result;
  };
  return perform();
}

// Trusted input and hidden scrolling share Chrome's focus-emulation owner.
async function renderWhileHidden(target, admit) {
  await admit();
  await chrome.debugger.sendCommand(target, "Emulation.setFocusEmulationEnabled", { enabled: true });
  await admit();
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

function invalidatePageBaseline(tabId) {
  // Advancing an existing generation also fences a frame whose reply has not
  // arrived yet (and therefore has no local snapshot key to invalidate).
  if (pageDocumentGenerations.has(tabId)) pageDocumentGenerations.set(tabId, Symbol());
  sendEvent("page.invalidated", { tabId });
}

function invalidateTabSnapshots(tabId, invalidateBaseline) {
  // The app owns subscription baselines too, including same-URL reloads.
  // An explicit read replaces routes but publishes its own fresh baseline.
  if (invalidateBaseline) invalidatePageBaseline(tabId);
  cancelSnapshotCapture(tabId);
  activeSnapshotReads.delete(tabId);
  for (const [snapshotId, snapshot] of snapshotRoutes) {
    if (snapshot.tabId === tabId) snapshotRoutes.delete(snapshotId);
  }
}

function cancelSnapshotCapture(tabId) {
  const capture = activeSnapshotReads.get(tabId);
  if (capture) void chrome.tabs.sendMessage(tabId, { type: "nativeagent.page.action.cancel",
    requestId: capture.actionId ?? capture.id }).catch(error => reportPageObservationFailure(tabId, error));
}

function invalidateSubframeSnapshots(tabId, frameId) {
  sendEvent("page.frame_invalidated", { tabId, frameId });
  const capture = activeSnapshotReads.get(tabId);
  if (capture) capture.invalidatedFrameIds.add(frameId);
  for (const snapshot of snapshotRoutes.values()) {
    if (snapshot.tabId !== tabId) continue;
    for (const [nodeId, route] of [...snapshot.routes]) {
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

// Arm both observations before dispatch. A commit identifies the arrival;
// tab completion works even for Chrome pages without webNavigation/DOM access.
function watchTopDocument(tabId, { requiresSite, timings }) {
  const previous = pageLoads.documents.get(tabId);
  const watch = { completedUrl: null,
    get committedDocumentId() {
      const state = pageLoads.documents.get(tabId);
      return state && state !== previous && state.committedAt !== null && admits(state.url) ? state.documentId : null;
    },
    get error() {
      const state = pageLoads.documents.get(tabId);
      return state && state !== previous ? state.error : null;
    } };
  const admits = url => {
    if (!requiresSite) return true;
    if (typeof url !== "string" || !/^https?:/.test(url)) return false;
    return Boolean(new URL(url).host);
  };
  const observed = () => {
    const state = pageLoads.documents.get(tabId);
    if (!state || state === previous || !admits(state.url)) return;
    for (const [field, at] of [["committedMs", state.committedAt],
      ["contentPresentMs", state.contentAt], ["documentLoadedMs", state.loadedAt]]) {
      if (at !== null && at >= timings.startedAtMs && timings[field] === null) timings[field] = at - timings.startedAtMs;
    }
  };
  const observers = pageReadinessObservers.get(tabId) ?? new Set();
  pageReadinessObservers.set(tabId, observers);
  observers.add(observed);
  const updated = (id, change, tab) => {
    if (id !== tabId) return;
    if (change.status === "loading") watch.completedUrl = null;
    // A same-document fragment change can update the URL without a load.
    if ((change.status === "complete" || change.url) && tab.status === "complete" && !tab.pendingUrl && admits(tab.url)) {
      watch.completedUrl = tab.url;
    }
  };
  chrome.tabs.onUpdated.addListener(updated);
  watch.stop = () => {
    chrome.tabs.onUpdated.removeListener(updated);
    observers.delete(observed);
    if (!observers.size && pageReadinessObservers.get(tabId) === observers) pageReadinessObservers.delete(tabId);
  };
  return watch;
}

function readIdentityMatches(expected, current) {
  if (expected.expectedURL) {
    // Follow the current owned document, including cross-site redirects. The
    // arrival URL excludes a fresh HTTP(S) tab's hostless blank document; it
    // does not freeze the site or document after navigation returned.
    if (typeof current.url !== "string" || !current.url) return false;
    const site = new URL(expected.expectedURL);
    let observed;
    try { observed = new URL(current.url); } catch { return false; }
    if (/^https?:$/.test(site.protocol)) return /^https?:$/.test(observed.protocol) && Boolean(observed.host);
    if (observed.href !== site.href) return false;
  }
  return true;
}

// Only an explicit wait request observes content; snapshots read the DOM once.
function waitForReadablePage(tabId, timeoutMs, requireCurrent, actionId, { settleMs, scope, expectedDocumentId, expectedURL }) {
  return new Promise((resolve, reject) => {
    const quietMs = Math.max(0, settleMs);
    let ended = false, observing = false, pending = false, quietTimer = null;
    let stamp = null, stableSince = 0, documentId = null;
    let reason = "The current document's readable content has not arrived.";
    const waits = activeTabWaits.get(tabId) ?? new Set();
    activeTabWaits.set(tabId, waits);
    const readyObservers = pageReadinessObservers.get(tabId) ?? new Set();
    pageReadinessObservers.set(tabId, readyObservers);
    const cancel = error => finish(error);
    function finish(error, matched = false) {
      if (ended) return;
      ended = true;
      clearTimeout(deadline); clearTimeout(quietTimer);
      chrome.tabs.onUpdated.removeListener(updated);
      chrome.runtime.onMessage.removeListener(changed);
      readyObservers.delete(observe);
      if (!readyObservers.size && pageReadinessObservers.get(tabId) === readyObservers) pageReadinessObservers.delete(tabId);
      waits.delete(cancel);
      if (!waits.size && activeTabWaits.get(tabId) === waits) activeTabWaits.delete(tabId);
      if (activeRequestWaits.get(actionId) === cancel) activeRequestWaits.delete(actionId);
      if (error) reject(error); else resolve({ matched, reason, quietMs, documentId });
    }
    const deadline = setTimeout(() => finish(null), timeoutMs);
    async function observe() {
      if (ended) return;
      if (observing) { pending = true; return; }
      observing = true;
      try {
        do {
          pending = false;
          await requireCurrent();
          requireActiveRequest(actionId);
          if (ended) return;
          const tab = await chrome.tabs.get(tabId);
          if (ended) return;
          if (tab.id !== tabId) throw new ProtocolError("tab_identity_changed", "Chrome returned a different tab identity.");
          if (tab.pendingUrl) { stamp = null; reason = "Chrome still has a pending URL."; continue; }
          if (expectedURL && !readIdentityMatches({ expectedURL }, tab)) {
            stamp = null; reason = "The navigation has not reached its readable document yet."; continue;
          }
          let current;
          if (/^https?:/.test(tab.url ?? "")) {
            try { current = await readTopDocumentEvidence(tabId, actionId, scope, { expectedDocumentId, expectedURL }); }
            catch (error) {
              if (!["page_agent_loading", "page_changed", "page_agent_unavailable"].includes(error.code)) throw error;
              stamp = null; reason = error.message;
              if (error.code === "page_changed") pending = true;
              continue;
            }
          }
          if (ended) return;
          if (current?.document.kind === "dom" && current.document.busy) {
            stamp = null; reason = current.document.busyReason; continue;
          }
          const rendered = current?.document.kind === "dom";
          documentId = current?.documentId ?? null;
          if (!rendered && tab.status !== "complete") { stamp = null; reason = "Chrome has not completed loading the non-DOM page."; continue; }
          if (rendered && typeof current.document.contentStamp !== "string") {
            throw new ProtocolError("page_document_unavailable", "The page reader supplied no readable-content identity.");
          }
          const nextStamp = JSON.stringify([current?.documentId ?? tab.url, current?.document.contentStamp ?? "non-DOM"]);
          if (nextStamp !== stamp) { stamp = nextStamp; stableSince = performance.now(); }
          const remaining = quietMs - (performance.now() - stableSince);
          if (remaining <= 0) {
            reason = rendered ? `Readable rendered content was stable for ${quietMs} ms${tab.status === "complete" ? "." : "; Chrome still reports the tab loading."}`
              : "Chrome completed loading the non-DOM page.";
            finish(null, true); return;
          }
          reason = `Readable content has not yet stayed stable for ${quietMs} ms.`;
          clearTimeout(quietTimer);
          quietTimer = setTimeout(() => { quietTimer = null; void observe(); }, remaining);
        } while (pending && !ended);
      } catch (error) { finish(error); }
      finally { observing = false; }
    }
    function updated(id, change) {
      if (id === tabId && (change.status || change.url)) void observe();
    }
    function changed(message, sender) {
      if (sender.tab?.id !== tabId || sender.frameId !== 0
        || !["nativeagent.page.changed", "nativeagent.page.ready", "nativeagent.page.mutated"].includes(message?.type)) return;
      // Sample at the quiet boundary, rather than restarting on ad churn.
      if (quietTimer === null) void observe();
    }
    waits.add(cancel);
    chrome.tabs.onUpdated.addListener(updated);
    chrome.runtime.onMessage.addListener(changed);
    readyObservers.add(observe);
    registerRequestWait(actionId, cancel);
    void observe();
  });
}

// Content arrival or the observed network's last terminal event admits one read.
async function waitForTabArrival(tabId, requireCurrent, actionId, navigationWatch, readerDocumentId) {
  return new Promise((resolve, reject) => {
    let ended = false;
    let nextTab;
    let observing = false;
    let documentMime;
    const waits = activeTabWaits.get(tabId) ?? new Set();
    activeTabWaits.set(tabId, waits);
    const readyObservers = pageReadinessObservers.get(tabId) ?? new Set();
    pageReadinessObservers.set(tabId, readyObservers);
    function finish(error, arrival) {
      if (ended) return;
      ended = true;
      chrome.tabs.onUpdated.removeListener(listener);
      chrome.webNavigation.onCommitted.removeListener(committed);
      readyObservers.delete(ready);
      if (!readyObservers.size && pageReadinessObservers.get(tabId) === readyObservers) pageReadinessObservers.delete(tabId);
      waits.delete(cancel);
      if (waits.size === 0 && activeTabWaits.get(tabId) === waits) activeTabWaits.delete(tabId);
      if (activeRequestWaits.get(actionId) === cancel) activeRequestWaits.delete(actionId);
      if (error) reject(error); else resolve(arrival);
    }
    const cancel = (error) => finish(error);
    async function observe(tab) {
      if (ended) return;
      nextTab = tab;
      if (observing) return;
      observing = true;
      try {
        while (nextTab && !ended) {
          const tab = nextTab;
          nextTab = null;
          await requireCurrent();
          requireActiveRequest(actionId);
          if (ended) return;
          if (nextTab) continue;
          if (tab.id !== tabId) throw new ProtocolError("tab_identity_changed", "Chrome returned a different tab identity.");
          const error = navigationWatch ? navigationWatch.error : pageLoads.documents.get(tabId)?.error;
          if (error) throw new ProtocolError("navigation_failed", error);
          if (tab.pendingUrl) continue;
          const complete = tab.status === "complete" && (!navigationWatch || navigationWatch.completedUrl === tab.url);
          if (complete && !/^https?:/.test(tab.url ?? "")) {
            finish(null, { by: "non_dom_complete" }); continue;
          }
          if (navigationWatch && !navigationWatch.committedDocumentId && !complete) continue;
          const frame = await chrome.webNavigation.getFrame({ tabId, frameId: 0 });
          await requireCurrent();
          if (ended || nextTab) continue;
          if (!frame?.documentId || frame.url !== tab.url
            || (navigationWatch && frame.documentId !== navigationWatch.committedDocumentId && !complete)) continue;
          if (readerDocumentId) {
            if (frame.documentId !== readerDocumentId) throw new ProtocolError("page_changed", "The document changed before its reader arrived.");
            if (readyPageFrames.get(tabId)?.get(0)?.documentId !== readerDocumentId) continue;
          }
          const arrival = pageLoads.arrival(tabId, frame.documentId);
          if (arrival?.error) throw new ProtocolError("navigation_failed", arrival.error);
          if (arrival) { finish(null, arrival); continue; }
          if (!readerDocumentId && /^https?:/.test(frame.url)) {
            if (documentMime?.documentId !== frame.documentId) {
              const contentType = await readDocumentContentType(tabId, frame.documentId);
              documentMime = { documentId: frame.documentId, contentType };
            }
            await requireCurrent();
            requireActiveRequest(actionId);
            const current = await chrome.webNavigation.getFrame({ tabId, frameId: 0 });
            if (ended || nextTab) continue;
            if (current?.documentId !== frame.documentId || current.url !== frame.url) {
              throw new ProtocolError("page_changed", "The document changed while observing its content type.");
            }
            if (documentMime.contentType === "application/pdf" || documentMime.contentType.startsWith("image/")) {
              finish(null, { by: "non_dom_committed" });
            }
          }
        }
      } catch (error) { finish(error); }
      finally { observing = false; }
    }
    function listener(updatedTabId, changeInfo, tab) {
      if (updatedTabId !== tabId) return;
      void observe(tab);
    }
    function committed(details) {
      if (details.tabId === tabId && details.frameId === 0) {
        void chrome.tabs.get(tabId).then(observe).catch(error => finish(error));
      }
    }
    function ready() {
      void chrome.tabs.get(tabId).then(observe).catch(error => finish(error));
    }
    readyObservers.add(ready);
    waits.add(cancel);
    chrome.tabs.onUpdated.addListener(listener);
    chrome.webNavigation.onCommitted.addListener(committed);
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

// A tab becomes hers with the document it already holds: every frame gets the
// reader once. Tabs install independently: one slow page delays only itself.
function installPageReader(tab) {
  const installing = installingReaders.get(tab.tabId);
  if (installing) return installing;
  const installed = (async () => {
    try {
      await changesReady;
      const current = await workspace.requireTab(tab.tabId);
      // A blank tab has nothing to read: its next document's commit brings the reader.
      if (!READABLE_DOCUMENT.test(current.url)) { installingReaders.delete(tab.tabId); return; }
      await chrome.scripting.executeScript({ target: { tabId: tab.tabId, allFrames: true }, files: [PAGE_READER], injectImmediately: true });
      if (retireReaderIfNotHers(tab.tabId)) return;
      await observeOwnedPage(tab);
    } catch (error) {
      // The tab's next change tries again.
      if (installingReaders.get(tab.tabId) === installed) installingReaders.delete(tab.tabId);
      reportPageObservationFailure(tab.tabId, error);
    }
  })();
  installingReaders.set(tab.tabId, installed);
  return installed;
}

// Ownership can end while an injection is in flight.
function retireReaderIfNotHers(tabId) {
  if (workspace.tabForId(tabId)) return false;
  void chrome.tabs.sendMessage(tabId, { type: "nativeagent.page.tab.invalidated", tabId }).catch(() => {});
  return true;
}

// Each document committed in her tab gets the reader as it starts. Chrome's own
// pages allow none, and a frame can be gone before the reader reaches it.
async function readDocument(tabId, frameId, documentId, url) {
  if (!READABLE_DOCUMENT.test(url) && frameId === 0) return;
  try {
    await chrome.scripting.executeScript({ target: { tabId, documentIds: [documentId] }, files: [PAGE_READER], injectImmediately: true });
    retireReaderIfNotHers(tabId);
  } catch (error) {
    if (frameId === 0 && workspace.tabForId(tabId)) reportPageObservationFailure(tabId, error);
  }
}

async function observeOwnedPage(ownedTab, frameId, { documentId } = {}) {
  try {
    await workspace.requireForPageAction({ tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence });
    if (frameId === undefined) {
      const frames = await chrome.webNavigation.getAllFrames({ tabId: ownedTab.tabId });
      for (const frame of frames ?? []) {
        await observeOwnedPage(ownedTab, frame.frameId, { documentId: frame.documentId });
      }
      return;
    }
    const frame = await chrome.webNavigation.getFrame({ tabId: ownedTab.tabId, frameId: frameId ?? 0 });
    if (!frame || (documentId && frame.documentId !== documentId)) {
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
    if (await acceptPageReady(ownedTab.tabId, frameId ?? 0, documentId, result.url)) {
      if (frameId === 0) pageLoads.reader(ownedTab.tabId, documentId, result);
      // Resume a queued edge if attachment won its registration race. Attachment
      // alone does not request another capture of an idle document.
      void drainSiteChanges(ownedTab.tabId);
    }
    return result;
  } catch (error) {
    // Restricted/new documents have no content agent. Its page.ready message
    // arms observation when available; no tab is opened or navigated here.
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
  // Wake after the owner accepts the identity, not only when the raw ready
  // message arrives before its asynchronous frame check has finished.
  if (frameId === 0) for (const observe of pageReadinessObservers.get(tabId) ?? []) void observe();
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

// A passive capture walks the whole page. Captures are spaced by their own cost,
// so a page that never stops changing gives up at most a twentieth of its time.
const PASSIVE_CAPTURE_SHARE = 20;

function siteChangesResting(tabId, stream) {
  const rest = (stream.restUntil ?? 0) - performance.now();
  if (rest <= 0) return false;
  if (!stream.restTimer) stream.restTimer = setTimeout(() => {
    stream.restTimer = null;
    void drainSiteChanges(tabId);
  }, rest);
  return true;
}

async function drainSiteChanges(tabId) {
  const stream = pageChangeStreams.get(tabId);
  if (stream?.pending && !stream.draining && siteChangesResting(tabId, stream)) return;
  if (!stream?.pending || stream.draining || activeSnapshotReads.has(tabId) || activeNavigations.has(tabId)
    || !pageHasArrived(tabId) || !readyPageFrames.get(tabId)?.has(stream.frameId)
    || (stream.waitingFrameId !== undefined && !readyPageFrames.get(tabId)?.has(stream.waitingFrameId))) return;
  stream.waitingFrameId = undefined;
  stream.draining = true;
  try {
    while (stream.pending && pageChangeStreams.get(tabId) === stream && !activeSnapshotReads.has(tabId) && !activeNavigations.has(tabId)
      && pageHasArrived(tabId) && readyPageFrames.get(tabId)?.has(stream.frameId)) {
      if (siteChangesResting(tabId, stream)) break;
      stream.pending = false;
      let ownedTab;
      try { ownedTab = await workspace.requireTab(stream.tabId); } catch { break; }
      const captureStarted = performance.now();
      const view = pageSnapshotViews.get(ownedTab.tabId) ?? { scope: "page" };
      const payload = { tabId: ownedTab.tabId, expectedUserSequence: ownedTab.userSequence, ...view };
      const capture = beginSnapshotCapture(tabId, { passive: true });
      // Replace only prior news routes. A page event must preserve the explicit
      // reader's still-valid navigation proofs and never changes ownership.
      for (const [id, route] of snapshotRoutes) {
        if (route.tabId === tabId && route.passive === true) snapshotRoutes.delete(id);
      }
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
        publishCurrentSnapshotCapture(ownedTab, capture, () => {
          snapshot.reading.pageMoved ||= snapshotCaptureMoved(capture);
          sendEvent("page.changed", {
            tabId, userSequence: ownedTab.userSequence,
            changeGeneration, changedFrameId: stream.frameId, snapshot,
          });
        });
      } catch (error) {
        // A newer read or document generation owns publication. A pending
        // document edge waits for readiness; mutations remain moved-page evidence.
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
        stream.restUntil = performance.now() + (performance.now() - captureStarted) * PASSIVE_CAPTURE_SHARE;
      }
    }
  } finally {
    stream.draining = false;
  }
}

function pageHasArrived(tabId) {
  const documentId = readyPageFrames.get(tabId)?.get(0)?.documentId;
  if (!documentId) return false;
  const arrival = pageLoads.arrival(tabId, documentId);
  return Boolean(arrival && !arrival.error);
}

function tabOwnershipEnded(tab, reason) {
  endRendering(tab.tabId);
  installingReaders.delete(tab.tabId);
  pageChangeStreams.delete(tab.tabId);
  pageChangeGenerations.delete(tab.tabId);
  pageSnapshotViews.delete(tab.tabId);
  invalidateTabSnapshots(tab.tabId, true);
  pageDocumentGenerations.delete(tab.tabId);
  activeNavigations.delete(tab.tabId);
  cancelTabWaits(tab.tabId, tabNotOwnedError(tab.tabId, reason));
  void chrome.tabs.sendMessage(tab.tabId, { type: "nativeagent.page.tab.invalidated", tabId: tab.tabId }).catch(() => {});
  sendEvent("tab.yielded", { tabId: tab.tabId, userSequence: tab.userSequence, reason, url: tab.url });
}

function recordOwnershipFailure(error) { recordNativeError(error.message ?? String(error)); }

function sendEvent(event, payload) {
  if (nativePort) postNativeMessage(nativePort, eventEnvelope(event, payload));
}
