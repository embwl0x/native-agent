import { TabLeaseManager } from "./lease-manager.js";
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
const NATIVE_RECONNECT_ALARM = "nativeagent.native-reconnect";
const MAX_SNAPSHOT_FRAMES = 64;
// The relay admits at most 1,048,576 UTF-8 bytes including the response
// envelope. Reserve headroom rather than relying on character/node counts.
const MAX_SNAPSHOT_RESULT_BYTES = 1_000_000;
const utf8Encoder = new TextEncoder();
const snapshotRoutes = new Map();
const activeSnapshotReads = new Map();
const activeNavigations = new Map();
const activeTabWaits = new Map();
const leaseManager = new TabLeaseManager({
  chromeApi: chrome,
  emitEvent: sendEvent,
});
const leasesReady = leaseManager.restore().catch(() => {
  // Storage/Chrome recovery errors must not poison every later native request.
  leaseManager.leases.clear();
});

connectNativeHost();
chrome.runtime.onStartup.addListener(connectNativeHost);
chrome.runtime.onInstalled.addListener(connectNativeHost);

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type === "nativeagent.page.mutated" && Number.isInteger(sender.frameId)) {
    invalidateFrameSnapshots(sender.tab?.id, sender.frameId, message.snapshotIds);
    return;
  }
  if (message?.type !== "nativeagent.user-touch" || !Number.isInteger(sender.tab?.id)) return;
  void leasesReady.then(() => leaseManager.yieldForTab(
    sender.tab.id,
    `user_${message.kind ?? "input"}`,
  ));
});

chrome.tabs.onActivated.addListener(({ tabId }) => {
  void leaseManager.yieldForTab(tabId, "tab_activated").catch(() => {});
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void leasesReady.then(() => leaseManager.tabRemoved(tabId));
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === NATIVE_RECONNECT_ALARM) {
    connectNativeHost();
    return;
  }
  void leasesReady.then(() => leaseManager.alarmFired(alarm.name));
});

function connectNativeHost() {
  if (nativePort) return;
  try {
    const port = chrome.runtime.connectNative(HOST_ID);
    nativePort = port;
    void chrome.alarms.clear(NATIVE_RECONNECT_ALARM);
    port.onMessage.addListener((message) => void handleNativeMessage(message, port));
    port.onDisconnect.addListener(() => {
      void chrome.runtime.lastError;
      if (nativePort === port) nativePort = null;
      scheduleNativeReconnect();
    });
  } catch {
    nativePort = null;
    scheduleNativeReconnect();
  }
}

function scheduleNativeReconnect() {
  void chrome.alarms.create(NATIVE_RECONNECT_ALARM, { delayInMinutes: 0.5 });
}

async function handleNativeMessage(rawRequest, port) {
  let request = rawRequest;
  try {
    await leasesReady;
    request = validateRequest(rawRequest);
    const result = await dispatch(request);
    port.postMessage(successResponse(request, result));
  } catch (error) {
    port.postMessage(errorResponse(request, error));
  }
}

async function dispatch(request) {
  switch (request.action) {
    case "attach":
      return {
        hostId: HOST_ID,
        protocolVersion: PROTOCOL_VERSION,
        extensionVersion: chrome.runtime.getManifest().version,
        capabilities: ACTIONS,
      };
    case "lease.acquire":
      return leaseManager.acquire(request.payload);
    case "lease.renew":
      return leaseManager.renew(request.payload);
    case "lease.resume":
      throw new ProtocolError(
        "lease_resume_not_supported",
        "Yield is terminal in protocol v1; acquire a new exact-tab lease instead.",
      );
    case "lease.release":
      return leaseManager.release(request.payload);
    case "navigate":
      return navigateLeasedTab(request.payload, request.id);
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
    case "page.wait":
      return waitForPage(request.payload, request.id);
    case "page.scroll":
      return scrollPage(request.payload, request.id);
    default:
      throw new ProtocolError("unknown_action", `Unknown action '${request.action}'.`);
  }
}

async function navigateLeasedTab(payload, actionId) {
  const lease = leaseManager.requireForPageAction(payload);
  invalidateTabSnapshots(lease.tabId);
  cancelTabWaits(lease.tabId, new ProtocolError("navigation_superseded", "A newer navigation superseded the pending observation."));
  const navigation = {};
  activeNavigations.set(lease.tabId, navigation);
  const startedAt = new Date().toISOString();
  function requireCurrentNavigation() {
    leaseManager.requireForPageAction(payload);
    if (activeNavigations.get(lease.tabId) !== navigation) {
      throw new ProtocolError("navigation_superseded", "A newer navigation or user takeover superseded this request.");
    }
  }
  try {
    const updated = await chrome.tabs.update(lease.tabId, { url: payload.url });
    requireCurrentNavigation();
    if (updated?.active === true && lease.originalTab.active !== true) {
      await leaseManager.yieldForTab(lease.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "Navigation unexpectedly activated the leased tab.");
    }
    await waitForTabComplete(lease.tabId, 30_000, requireCurrentNavigation);
    const tab = await chrome.tabs.get(lease.tabId);
    requireCurrentNavigation();
    if (tab.active === true && lease.originalTab.active !== true) {
      await leaseManager.yieldForTab(lease.tabId, "tab_activated_during_navigation");
      throw new ProtocolError("focus_invariant_failed", "The tab became active before navigation could be confirmed.");
    }
    if (tab.id !== lease.tabId || tab.status !== "complete" || typeof tab.url !== "string") {
      throw new ProtocolError("navigation_changed", "The exact tab no longer has an observed complete page.");
    }
    return pageActionResult({
      actionId, action: "navigate", lease, payload, startedAt,
      outcome: "succeeded", verification: "not_verified",
      detail: {
        leaseId: lease.leaseId, tabId: lease.tabId, requestedUrl: payload.url,
        url: tab.url, title: tab.title ?? "", status: "complete", verified: false,
      },
    });
  } catch (error) {
    // tabs.update has already been dispatched. Lost ownership or observation
    // cannot prove that navigation did not happen, so never invite blind replay.
    return pageActionResult({
      actionId, action: "navigate", lease, payload, startedAt,
      outcome: "outcome_unknown", verification: "outcome_unknown",
      detail: {
        leaseId: lease.leaseId, tabId: lease.tabId, requestedUrl: payload.url,
        status: "outcome_unknown", verified: false,
        error: { code: error.code ?? "navigation_reply_lost", message: error.message ?? "Chrome navigation could not be confirmed." },
      },
    });
  } finally {
    if (activeNavigations.get(lease.tabId) === navigation) activeNavigations.delete(lease.tabId);
  }
}

async function readStructuredSnapshot(payload) {
  const lease = leaseManager.requireForPageAction(payload);
  invalidateTabSnapshots(lease.tabId);
  const capture = { localSnapshotKeys: new Set(), invalidatedSnapshotKeys: new Set(), invalidationOverflow: false };
  activeSnapshotReads.set(lease.tabId, capture);
  try {
    return await readStructuredSnapshotForCapture(payload, lease, capture);
  } finally {
    if (activeSnapshotReads.get(lease.tabId) === capture) activeSnapshotReads.delete(lease.tabId);
  }
}

function requireCurrentSnapshotCapture(lease, capture) {
  leaseManager.requireForPageAction({ leaseId: lease.leaseId, expectedUserSequence: lease.userSequence });
  if (activeSnapshotReads.get(lease.tabId) !== capture) {
    throw new ProtocolError("snapshot_superseded", "A newer read or navigation superseded this snapshot capture.");
  }
  if (capture.invalidationOverflow || [...capture.localSnapshotKeys].some((key) => capture.invalidatedSnapshotKeys.has(key))) {
    throw new ProtocolError("snapshot_stale", "A captured frame changed while the combined snapshot was being read.");
  }
}

async function readStructuredSnapshotForCapture(payload, lease, capture) {
  const maxNodes = payload.maxNodes ?? 500;
  const maxTextChars = payload.maxTextChars ?? 50_000;
  const discovered = await chrome.webNavigation.getAllFrames({ tabId: lease.tabId });
  requireCurrentSnapshotCapture(lease, capture);
  const ordered = [...(discovered ?? [])].sort((left, right) => {
    if (left.frameId === 0) return -1;
    if (right.frameId === 0) return 1;
    return left.frameId - right.frameId;
  });
  const frames = [];
  const localSnapshots = [];
  let remainingNodes = maxNodes;
  let remainingText = maxTextChars;
  let topSnapshot = null;

  for (const frame of ordered.slice(0, MAX_SNAPSHOT_FRAMES)) {
    requireCurrentSnapshotCapture(lease, capture);
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
    let local;
    try {
      local = await sendPageMessage(lease.tabId, {
        type: "nativeagent.page.snapshot",
        leaseId: lease.leaseId,
        tabId: lease.tabId,
        userSequence: lease.userSequence,
        maxNodes: remainingNodes,
        maxTextChars: Math.max(1, remainingText),
      }, { frameId: frame.frameId });
    } catch (error) {
      requireCurrentSnapshotCapture(lease, capture);
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
    requireCurrentSnapshotCapture(lease, capture);
    const nodes = Array.isArray(local.nodes) ? local.nodes : [];
    const text = String(local.summary?.text ?? "").slice(0, remainingText);
    remainingNodes -= nodes.length;
    remainingText -= text.length;
    if (frame.frameId === 0) topSnapshot = local;
    localSnapshots.push({ frame, local, text });
    frames.push({
      frameId: frame.frameId,
      parentFrameId: frame.parentFrameId,
      url: local.frame?.url ?? frame.url ?? "",
      name: local.frame?.name ?? "",
      accessible: true,
      nodeCount: nodes.length,
    });
  }

  if (!topSnapshot) {
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
        parentNodeId: localToGlobal.get(localNode.parentNodeId) ?? null,
        frameId: frame.frameId,
      });
    }
    if (text) summaryParts.push(text);
    for (const reason of local.summary?.truncationReasons ?? []) truncationReasons.push(reason);
  }
  if (ordered.length > MAX_SNAPSHOT_FRAMES) truncationReasons.push("frame_limit");
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
    nodes,
    frames,
    summary: {
      text: summaryText,
      nodeCount: nodes.length,
      truncated: truncationReasons.length > 0 || frames.some((frame) => !frame.accessible),
      truncationReasons: [...new Set(truncationReasons)],
    },
  }, routes);
  requireCurrentSnapshotCapture(lease, capture);
  snapshotRoutes.set(snapshotId, {
    leaseId: lease.leaseId,
    tabId: lease.tabId,
    userSequence: lease.userSequence,
    routes,
  });
  return result;
}

function boundSnapshotForTransport(snapshot, routes) {
  const encodedBytes = (value) => utf8Encoder.encode(JSON.stringify(value)).byteLength;
  if (encodedBytes(snapshot) <= MAX_SNAPSHOT_RESULT_BYTES) return snapshot;

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
  let remainingBytes = MAX_SNAPSHOT_RESULT_BYTES - encodedBytes(snapshot) - 1_024;
  if (remainingBytes < 0) {
    throw new ProtocolError(
      "snapshot_metadata_too_large",
      "Snapshot metadata exceeds the transport budget; request a smaller text budget or a narrower page view.",
    );
  }
  const retainedIDs = new Set();
  const frameCounts = new Map();
  for (const node of candidates) {
    const cost = encodedBytes(node) + 1;
    if (cost > remainingBytes) break;
    remainingBytes -= cost;
    snapshot.nodes.push(node);
    retainedIDs.add(node.nodeId);
    frameCounts.set(node.frameId, (frameCounts.get(node.frameId) ?? 0) + 1);
  }
  for (const nodeID of routes.keys()) {
    if (!retainedIDs.has(nodeID)) routes.delete(nodeID);
  }
  for (const node of snapshot.nodes) {
    if (node.parentNodeId && !retainedIDs.has(node.parentNodeId)) node.parentNodeId = null;
  }
  for (const frame of snapshot.frames) frame.nodeCount = frameCounts.get(frame.frameId) ?? 0;
  snapshot.summary.nodeCount = snapshot.nodes.length;
  return snapshot;
}

async function clickSnapshotNode(payload, actionId) {
  const lease = leaseManager.requireForPageAction(payload);
  if (payload.button !== undefined && payload.button !== "left") {
    throw new ProtocolError("button_not_supported", "Structured page clicks currently support the left button only.");
  }
  const route = requireSnapshotRoute(lease, payload);
  return performSnapshotMutation({
    lease, route, payload, actionId, action: "click",
    pageMessage: {
      type: "nativeagent.page.click",
      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      button: payload.button ?? "left",
    },
  });
}

async function fillSnapshotNode(payload, actionId) {
  const lease = leaseManager.requireForPageAction(payload);
  const route = requireSnapshotRoute(lease, payload);
  return performSnapshotMutation({
    lease, route,
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
  const lease = leaseManager.requireForPageAction(payload);
  const route = requireSnapshotRoute(lease, payload);
  return performSnapshotMutation({
    lease, route,
    payload,
    actionId,
    action: "type",
    pageMessage: {
      type: "nativeagent.page.type",
      leaseId: lease.leaseId,
      leaseExpiresAtMs: Date.parse(lease.expiresAt),
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
  const lease = leaseManager.requireForPageAction(payload);
  const route = requireSnapshotRoute(lease, payload);
  return performSnapshotMutation({
    lease, route, payload, actionId, action,
    pageMessage: {
      type,
      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      ...extra,
    },
  });
}

async function waitForPage(payload, actionId) {
  const lease = leaseManager.requireForPageAction(payload);
  const startedAt = new Date().toISOString();
  const timeoutMs = payload.timeoutMs ?? 5_000;
  if (payload.condition === "navigation_settled") {
    // 2026-09-06: ONE deadline for the whole action. The settle interval used
    // to open its own ceiling only after the completion wait had already spent
    // `timeoutMs`, so this could take twice the time the caller asked for.
    const deadlineAtMs = Date.now() + timeoutMs;
    try {
      await waitForTabComplete(lease.tabId, timeoutMs, () => leaseManager.requireForPageAction(payload));
      const quiet = await awaitNavigationQuiet(lease.tabId, payload.settleMs ?? 0, deadlineAtMs);
      const tab = await chrome.tabs.get(lease.tabId);
      leaseManager.requireForPageAction(payload);
      const complete = tab.id === lease.tabId && tab.status === "complete";
      // A tab that never went quiet is NOT a settled navigation. Reporting it
      // as verified claimed evidence nobody had: the page was still moving when
      // the deadline arrived. `not_quiet` says exactly that, and the Mac reads
      // it as evidence still owed.
      const matched = complete && quiet;
      return pageActionResult({
        actionId,
        action: "wait",
        lease,
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
          actionId, action: "wait", lease, payload, startedAt,
          outcome: "timed_out", verification: "not_verified",
          detail: { condition: payload.condition, matched: false },
        });
      }
      throw error;
    }
  }

  let response;
  const route = requireSnapshotRoute(lease, payload);
  try {
    response = await chrome.tabs.sendMessage(lease.tabId, {
      type: "nativeagent.page.wait",
      leaseId: lease.leaseId,
      leaseExpiresAtMs: Date.parse(lease.expiresAt),
      snapshotId: route.localSnapshotId,
      nodeId: route.localNodeId,
      state: payload.state,
      timeoutMs,
    }, { frameId: route.frameId });
  } catch {
    return pageActionResult({
      actionId, action: "wait", lease, payload, startedAt,
      outcome: "refused", verification: "not_verified",
      detail: {
        condition: payload.condition,
        matched: false,
        error: { code: "page_agent_unavailable", message: "The structured page agent became unavailable." },
      },
    });
  }
  leaseManager.requireForPageAction(payload);
  if (!response?.ok) {
    return pageActionResult({
      actionId, action: "wait", lease, payload, startedAt,
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
    actionId, action: "wait", lease, payload, startedAt,
    outcome: matched ? "succeeded" : "timed_out",
    verification: matched ? "verified" : "not_verified",
    detail: { ...response.result, snapshotId: payload.snapshotId, nodeId: payload.nodeId, frameId: route.frameId },
  });
}

async function performSnapshotMutation({ lease, route, payload, actionId, action, pageMessage }) {
  const startedAt = new Date().toISOString();
  let response;
  try {
    response = await chrome.tabs.sendMessage(lease.tabId, pageMessage, { frameId: route.frameId });
  } catch {
    return pageActionResult({
      actionId, action, lease, payload, startedAt,
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
      actionId, action, lease, payload, startedAt,
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
  const typeLandedCount = !typeResult || typeResult.valueRewritten === true
    ? 0
    : (typeResult.enteredCharacterCount ?? typeResult.characterCount ?? 0);
  return pageActionResult({
    actionId, action, lease, payload, startedAt,
    outcome: typeResult?.completed === false
      ? (typeLandedCount > 0 ? "partially_completed" : "refused")
      : "succeeded",
    verification: typeResult?.completed === false && typeLandedCount === 0
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

function pageActionResult({ actionId, action, lease, payload, startedAt, outcome, verification, detail }) {
  const receipt = {
    id: actionId,
    action,
    leaseId: lease.leaseId,
    userSequence: lease.userSequence,
    snapshotId: payload.snapshotId ?? null,
    nodeId: payload.nodeId ?? payload.targetNodeId ?? null,
    outcome,
    verification,
    retry: outcome === "outcome_unknown" ? "never_automatic"
      : outcome === "partially_completed" ? "fresh_snapshot_then_remaining_text_only" : "fresh_snapshot_required",
    startedAt,
    completedAt: new Date().toISOString(),
  };
  return { ...detail, outcome, receipt };
}

function normalizedPageError(response) {
  return {
    code: response?.error?.code ?? "page_action_failed",
    message: response?.error?.message ?? "The structured page action failed.",
  };
}

async function scrollPage(payload, actionId) {
  const lease = leaseManager.requireForPageAction(payload);
  const route = payload.targetNodeId ? requireSnapshotRoute(lease, {
    ...payload,
    nodeId: payload.targetNodeId,
  }) : { frameId: 0, localSnapshotId: payload.snapshotId, localNodeId: undefined };
  return performSnapshotMutation({
    lease, route, payload, actionId, action: "scroll",
    pageMessage: {
      type: "nativeagent.page.scroll",
      snapshotId: route.localSnapshotId,
      targetNodeId: route.localNodeId,
      deltaX: payload.deltaX,
      deltaY: payload.deltaY,
    },
  });
}

async function sendPageMessage(tabId, message, options = undefined) {
  let response;
  try {
    response = await chrome.tabs.sendMessage(tabId, message, options);
  } catch {
    throw new ProtocolError(
      "page_agent_unavailable",
      "The structured page agent is unavailable in this tab. Navigate to an HTTP(S) page and retry.",
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

function requireSnapshotRoute(lease, payload) {
  const snapshot = snapshotRoutes.get(payload.snapshotId);
  if (!snapshot || snapshot.leaseId !== lease.leaseId || snapshot.tabId !== lease.tabId
      || snapshot.userSequence !== lease.userSequence) {
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

function invalidateFrameSnapshots(tabId, frameId, localSnapshotIds) {
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
  for (const [snapshotId, snapshot] of snapshotRoutes) {
    if (snapshot.tabId !== tabId) continue;
    if ([...snapshot.routes.values()].some(
      (route) => route.frameId === frameId && invalidated.has(route.localSnapshotId),
    )) snapshotRoutes.delete(snapshotId);
  }
}

async function waitForTabComplete(tabId, timeoutMs, requireCurrent = () => {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const waits = activeTabWaits.get(tabId) ?? new Set();
    activeTabWaits.set(tabId, waits);
    function finish(error, tab) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      chrome.tabs.onUpdated.removeListener(listener);
      waits.delete(cancel);
      if (waits.size === 0 && activeTabWaits.get(tabId) === waits) activeTabWaits.delete(tabId);
      if (error) reject(error); else resolve(tab);
    }
    const cancel = (error) => finish(error);
    const timeout = setTimeout(() => {
      finish(new ProtocolError("navigation_timeout", "Chrome navigation did not finish before the deadline."));
    }, timeoutMs);
    function observe(tab) {
      if (settled) return;
      try {
        requireCurrent();
        if (tab.id !== tabId) throw new ProtocolError("tab_identity_changed", "Chrome returned a different tab identity.");
        if (tab.status === "complete") finish(null, tab);
      } catch (error) { finish(error); }
    }
    function listener(updatedTabId, changeInfo, tab) {
      if (updatedTabId !== tabId || changeInfo.status !== "complete") return;
      observe(tab);
    }
    waits.add(cancel);
    chrome.tabs.onUpdated.addListener(listener);
    void chrome.tabs.get(tabId).then(observe).catch((error) => finish(error));
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
async function awaitNavigationQuiet(tabId, quietMs, deadlineAtMs) {
  if (!(quietMs > 0)) return true;
  return new Promise((resolve) => {
    let settled = false;
    let timer = null;
    function finish(quiet) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve(quiet);
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
  });
}

function cancelTabWaits(tabId, error) {
  for (const cancel of [...(activeTabWaits.get(tabId) ?? [])]) cancel(error);
}

function sendEvent(event, payload) {
  if ((event === "lease.yielded" || event === "lease.released") && Number.isInteger(payload?.tabId)) {
    invalidateTabSnapshots(payload.tabId);
    activeNavigations.delete(payload.tabId);
    cancelTabWaits(payload.tabId, new ProtocolError("lease_not_found", "The tab lease ended before navigation could be confirmed."));
    // Stop an in-flight delayed action in every frame, not just future host
    // requests. A local trusted-input listener also stops typing immediately.
    void chrome.tabs.sendMessage(payload.tabId, {
      type: "nativeagent.page.lease.invalidated",
      leaseId: payload.leaseId,
    }).catch(() => {});
  }
  if (!nativePort) return;
  try {
    nativePort.postMessage(eventEnvelope(event, payload));
  } catch {
    nativePort = null;
  }
}
