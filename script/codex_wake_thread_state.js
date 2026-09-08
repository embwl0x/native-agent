"use strict";

const UNHEALTHY_THREAD_STATUS_TYPES = new Set(["systemError"]);

function threadStateFromThread(thread, threadId) {
  const status = thread && thread.status ? thread.status : {};
  const turns = thread && Array.isArray(thread.turns) ? thread.turns : [];
  const inProgressTurns = turns.filter((turn) => turn && turn.status === "inProgress");
  return {
    threadId: (thread && thread.id) || threadId,
    statusType: status.type || "unknown",
    activeFlags: Array.isArray(status.activeFlags) ? status.activeFlags : [],
    inProgressTurnIds: inProgressTurns.map((turn) => turn.id).filter(Boolean),
    active: status.type === "active" || inProgressTurns.length > 0,
  };
}

function isUnhealthyThreadState(state) {
  return Boolean(state && UNHEALTHY_THREAD_STATUS_TYPES.has(state.statusType));
}

function unhealthyThreadResult(threadId, state, extra = {}) {
  return {
    status: "failed",
    reason: "target_thread_unhealthy",
    threadId,
    active: Boolean(state && state.active),
    activeStatus: state && state.statusType ? state.statusType : "unknown",
    activeFlags: state && Array.isArray(state.activeFlags) ? state.activeFlags : [],
    inProgressTurnIds: state && Array.isArray(state.inProgressTurnIds) ? state.inProgressTurnIds : [],
    fix: "Use deliveryMode=fresh_thread, or point pinned_thread mode at a healthy Codex thread.",
    ...extra,
  };
}

function rpcFailure(error, threadId, extra = {}) {
  return {
    status: "failed",
    reason: error && error.message ? error.message : "app_server_error",
    threadId,
    error: String(error && error.message || error),
    ...(error && error.detail ? { detail: error.detail } : {}),
    ...extra,
  };
}

function stateExcludingTurnIds(state, turnIds) {
  if (!state) return state;
  const ignored = new Set((Array.isArray(turnIds) ? turnIds : []).filter(Boolean));
  if (ignored.size === 0) return state;
  const inProgressTurnIds = (state.inProgressTurnIds || []).filter((id) => !ignored.has(id));
  return {
    ...state,
    active: inProgressTurnIds.length > 0,
    statusType: inProgressTurnIds.length > 0 ? state.statusType : "idle",
    inProgressTurnIds,
  };
}

module.exports = {
  threadStateFromThread, isUnhealthyThreadState, unhealthyThreadResult,
  rpcFailure, stateExcludingTurnIds,
};
