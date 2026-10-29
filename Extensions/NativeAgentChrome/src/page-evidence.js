import { ProtocolError } from "./protocol.js";
// Reserve response-envelope headroom within the relay's 1,048,576-byte UTF-8 limit.
export const MAX_SNAPSHOT_RESULT_BYTES = 1_000_000;
export const utf8Encoder = new TextEncoder();
export function frameAddressFragment(frameId, fragment) {
  if (!fragment) return undefined;
  return frameId === 0 ? fragment : `frame/${frameId}/${fragment}`;
}

export function boundSnapshotForTransport(snapshot, routes, byteLimit = MAX_SNAPSHOT_RESULT_BYTES) {
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
  // Counts grow by at most three digits; reserve accounting margin and measure each retained node once.
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
        position: nextNode.readPosition, textOffset: nextNode.textOffset ?? 0,
        ...(snapshot.reading.viewportObservationId && nextNode.frameId === snapshot.reading.cursor?.frameId
          ? { viewportObservationId: snapshot.reading.viewportObservationId } : {}),
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
  // A folded snapshot summarizes only its retained evidence.
  snapshot.summary.text = snapshot.nodes.filter(node => !node.inlineProof)
    .map(node => node.text || node.name).filter(Boolean).join("\n");
  snapshot.reading.sections = [...new Set(snapshot.nodes.map(node => node.sectionName).filter(Boolean))];
  return snapshot;
}
export function pageActionResult({ actionId, action, ownedTab, payload, startedAt, outcome, verification, detail }) {
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

export function normalizedPageError(response) {
  return {
    code: response?.error?.code ?? "page_action_failed",
    message: response?.error?.message ?? "The structured page action failed.",
  };
}
