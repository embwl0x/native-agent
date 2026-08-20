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
const snapshotRoutes = new Map();
const leaseManager = new TabLeaseManager({
  chromeApi: chrome,
  emitEvent: sendEvent,
});
const leasesReady = leaseManager.restore();

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
  void leasesReady.then(() => leaseManager.yieldForTab(tabId, "tab_activated"));
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
      return navigateLeasedTab(request.payload);
    case "page.snapshot.read":
      return readStructuredSnapshot(request.payload);
    case "page.element.click":
      return clickSnapshotNode(request.payload);
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
      return scrollPage(request.payload);
    default:
      throw new ProtocolError("unknown_action", `Unknown action '${request.action}'.`);
  }
}

async function navigateLeasedTab(payload) {
  const lease = leaseManager.requireForPageAction(payload);
  invalidateTabSnapshots(lease.tabId);
  const updated = await chrome.tabs.update(lease.tabId, { url: payload.url });
  if (updated?.active === true && lease.originalTab.active !== true) {
    await leaseManager.yieldForTab(lease.tabId, "tab_activated_during_navigation");
    throw new ProtocolError("focus_invariant_failed", "Navigation unexpectedly activated the leased tab.");
  }
  const tab = updated?.status === "complete"
    ? updated
    : await waitForTabComplete(lease.tabId, 30_000);
  return {
    leaseId: lease.leaseId,
    tabId: lease.tabId,
    url: tab.url ?? payload.url,
    title: tab.title ?? "",
    status: "complete",
  };
}

async function readStructuredSnapshot(payload) {
  const lease = leaseManager.requireForPageAction(payload);
  invalidateTabSnapshots(lease.tabId);
  const maxNodes = payload.maxNodes ?? 500;
  const maxTextChars = payload.maxTextChars ?? 50_000;
  const discovered = await chrome.webNavigation.getAllFrames({ tabId: lease.tabId });
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
  snapshotRoutes.set(snapshotId, {
    leaseId: lease.leaseId,
    tabId: lease.tabId,
    userSequence: lease.userSequence,
    routes,
  });
  const { frame: _topFrameMetadata, ...topPage } = topSnapshot;
  return {
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
  };
}

async function clickSnapshotNode(payload) {
  const lease = leaseManager.requireForPageAction(payload);
  if (payload.button !== undefined && payload.button !== "left") {
    throw new ProtocolError("button_not_supported", "Structured page clicks currently support the left button only.");
  }
  const route = requireSnapshotRoute(lease, payload);
  const result = await sendPageMessage(lease.tabId, {
    type: "nativeagent.page.click",
    snapshotId: route.localSnapshotId,
    nodeId: route.localNodeId,
    button: payload.button ?? "left",
  }, { frameId: route.frameId });
  return { ...result, snapshotId: payload.snapshotId, nodeId: payload.nodeId, frameId: route.frameId };
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
    try {
      const tab = await waitForTabComplete(lease.tabId, timeoutMs);
      if ((payload.settleMs ?? 0) > 0) await delay(payload.settleMs);
      return pageActionResult({
        actionId,
        action: "wait",
        lease,
        payload,
        startedAt,
        outcome: "succeeded",
        verification: "verified",
        detail: {
          condition: payload.condition,
          matched: true,
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
  return pageActionResult({
    actionId, action, lease, payload, startedAt,
    outcome: "succeeded", verification: "page_acknowledged",
    detail: { ...response.result, snapshotId: payload.snapshotId, nodeId: payload.nodeId, frameId: route.frameId },
  });
}

function pageActionResult({ actionId, action, lease, payload, startedAt, outcome, verification, detail }) {
  const receipt = {
    id: actionId,
    action,
    leaseId: lease.leaseId,
    userSequence: lease.userSequence,
    snapshotId: payload.snapshotId ?? null,
    nodeId: payload.nodeId ?? null,
    outcome,
    verification,
    retry: outcome === "outcome_unknown" ? "never_automatic" : "fresh_snapshot_required",
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

async function scrollPage(payload) {
  const lease = leaseManager.requireForPageAction(payload);
  const route = payload.targetNodeId ? requireSnapshotRoute(lease, {
    ...payload,
    nodeId: payload.targetNodeId,
  }) : { frameId: 0, localSnapshotId: payload.snapshotId, localNodeId: undefined };
  const result = await sendPageMessage(lease.tabId, {
    type: "nativeagent.page.scroll",
    snapshotId: route.localSnapshotId,
    targetNodeId: route.localNodeId,
    deltaX: payload.deltaX,
    deltaY: payload.deltaY,
  }, { frameId: route.frameId });
  return { ...result, snapshotId: payload.snapshotId ?? null, targetNodeId: payload.targetNodeId ?? null, frameId: route.frameId };
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
  for (const [snapshotId, snapshot] of snapshotRoutes) {
    if (snapshot.tabId === tabId) snapshotRoutes.delete(snapshotId);
  }
}

function invalidateFrameSnapshots(tabId, frameId, localSnapshotIds) {
  const invalidated = new Set(Array.isArray(localSnapshotIds) ? localSnapshotIds : []);
  for (const [snapshotId, snapshot] of snapshotRoutes) {
    if (snapshot.tabId !== tabId) continue;
    if ([...snapshot.routes.values()].some(
      (route) => route.frameId === frameId && invalidated.has(route.localSnapshotId),
    )) snapshotRoutes.delete(snapshotId);
  }
}

async function waitForTabComplete(tabId, timeoutMs) {
  const initial = await chrome.tabs.get(tabId);
  if (initial.status === "complete") return initial;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(listener);
      reject(new ProtocolError("navigation_timeout", "Chrome navigation did not finish before the deadline."));
    }, timeoutMs);
    function listener(updatedTabId, changeInfo, tab) {
      if (updatedTabId !== tabId || changeInfo.status !== "complete") return;
      clearTimeout(timeout);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve(tab);
    }
    chrome.tabs.onUpdated.addListener(listener);
    void chrome.tabs.get(tabId).then((tab) => {
      if (tab.status !== "complete") return;
      clearTimeout(timeout);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve(tab);
    }).catch(() => {});
  });
}

function delay(milliseconds) { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }

function sendEvent(event, payload) {
  if ((event === "lease.yielded" || event === "lease.released") && Number.isInteger(payload?.tabId)) {
    invalidateTabSnapshots(payload.tabId);
  }
  if (!nativePort) return;
  try {
    nativePort.postMessage(eventEnvelope(event, payload));
  } catch {
    nativePort = null;
  }
}
