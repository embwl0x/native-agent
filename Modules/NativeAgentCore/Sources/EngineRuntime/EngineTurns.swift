import Transcripts
import Foundation
import Observation
import ChatOrchestration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting

/// `NativeAgentEngine.turns` (S10): the Mac's running chat turns for one data
/// root — which sessions are thinking, streaming and replying, each session's
/// turn lifecycle (the working card), the live computer pane, the queue behind
/// a running turn, and Stop. Chat, detached panels, the sidebar, Simple view
/// and the window haze render this state; Core owns admission, send-next,
/// Stop and lifecycle authority through `runtime`. The run registry is nonisolated so
/// the phone lanes and quit use the same owner.
@MainActor
@Observable
public final class TurnsFacade {
    public nonisolated let dataRoot: URL
    public nonisolated let runtime: MacChatTurnRuntime

    // PATCH-2026-05-13: parallel-sessions — per-session chat state so the user
    // can work in multiple sessions concurrently.
    public var activityDidChange: (@MainActor () -> Void)? {
        get { runtime.activityDidChange }
        set { runtime.activityDidChange = newValue }
    }
    public var busySessions: Set<String> {
        get { runtime.busySessions }
        set { runtime.busySessions = newValue }
    }
    public var streamingSessions: Set<String> {
        get { runtime.streamingSessions }
        set { runtime.streamingSessions = newValue }
    }
    /// Sessions whose running turn has started to publish reply text. Written
    /// once when the first non-empty snapshot lands and cleared with the
    /// turn, never per token — the window haze reads it (WindowHaze.swift).
    public var replyingSessions: Set<String> = [] {
        didSet { if replyingSessions != oldValue { activityDidChange?() } }
    }
    public var tasks: [String: Task<Void, Never>] {
        get { runtime.tasks }
        set { runtime.tasks = newValue }
    }
    public var taskGenerations: [String: Int] {
        get { runtime.taskGenerations }
        set { runtime.taskGenerations = newValue }
    }
    /// The one authoritative Mac presentation lifecycle for the current or
    /// most-recent accepted turn in each session. Operational events, stop
    /// requests, and evidence-backed terminals all reduce into this state.
    public var lifecycleBySession: [String: MacChatTurnLifecycleState] {
        get { runtime.lifecycleBySession }
        set { runtime.lifecycleBySession = newValue }
    }
    /// What the agent is looking at while it drives the Mac, per session. Lives
    /// and dies with the turn's card: opened by the first Mac verb of a turn,
    /// cleared when the next turn opens or this one's intake closes. Empty for
    /// every turn that never touches the Mac.
    public var screenPreviewBySession: [String: MacChatScreenPreview] = [:]
    public var activeTurnIDsBySession: [String: String] {
        get { runtime.activeTurnIDsBySession }
        set { runtime.activeTurnIDsBySession = newValue }
    }
    /// When this session's turn last applied a pure stream-progress bump, and
    /// to which turn. 2026-09-14 (snappiness): see
    /// `AppModel.recordChatTurnStreamProgress`.
    public var streamProgressAppliedAt: [String: (turnId: String, at: Date)] {
        get { runtime.streamProgressAppliedAt }
        set { runtime.streamProgressAppliedAt = newValue }
    }
    /// The durable record of each session's open turn lifecycle.
    public var lifecycleStore: MacChatTurnLifecycleStore {
        get { runtime.lifecycleStore }
        set { runtime.lifecycleStore = newValue }
    }
    /// User-authored turns waiting behind the active turn, keyed by canonical
    /// session id. They stay outside the transcript/provider path until they
    /// become active, so queued text cannot race or duplicate the running turn.
    public var queuedBySession: [String: [QueuedChatTurn]] {
        get { runtime.queuedBySession }
        set { runtime.queuedBySession = newValue }
    }
    /// A manual Stop pauses automatic queue drain for that session. Natural
    /// completion drains immediately; Steer explicitly unpauses and promotes.
    public var pausedQueueSessions: Set<String> {
        get { runtime.pausedQueueSessions }
        set { runtime.pausedQueueSessions = newValue }
    }
    /// 2026-09-06: why the queue paused, when it paused because a queued turn
    /// FAILED to start. The drain used to discard the typed rejection's
    /// message, so the strip read "Paused" and the person was never told what
    /// went wrong. Absent for an ordinary Stop-pause, which needs no reason.
    public var queuePauseReasons: [String: String] {
        get { runtime.queuePauseReasons }
        set { runtime.queuePauseReasons = newValue }
    }
    public var drainingQueueSessions: Set<String> {
        get { runtime.drainingQueueSessions }
        set { runtime.drainingQueueSessions = newValue }
    }
    // 2026-06-10 audit FIX 4: Stop's cancelled.flag write used to be
    // fire-and-forget — Stop then a quick re-Send raced the new turn's
    // flag-clear, so the stale write could land mid-turn and kill the NEW
    // turn. Track the in-flight write per session; turn starts await it via
    // awaitPendingCancelFlagWrite(for:) so the write is ordered BEFORE the
    // turn-start clear. Entries self-remove when the latest write completes
    // (generation-guarded, all on MainActor).
    public var pendingStopWrites: [String: Task<Void, Never>] {
        get { runtime.pendingStopWrites }
        set { runtime.pendingStopWrites = newValue }
    }
    public var pendingStopWriteGenerations: [String: Int] {
        get { runtime.pendingStopWriteGenerations }
        set { runtime.pendingStopWriteGenerations = newValue }
    }
    // PATCH-2026-05-13: parallel-sessions — when a session is streaming but
    // not active, we still need to know (a) the live delta-buffer and (b)
    // the in-flight bubble id so that switching back to the session can
    // restore the live-text bubble without waiting for the next refresh.
    // 2026-09-13 (performance pass 3): this buffer is written on EVERY delta —
    // the only uncoalesced per-token write in the turn — and it is read only by
    // `selectChatSession`'s restore path, never by a view. Keeping it out of
    // observation means a token costs a dictionary store and nothing else; the
    // one write the UI reacts to stays the coalesced
    // `updateChatMessageContent` below it.
    @ObservationIgnored public var streamingTexts: [String: String] = [:]
    public var streamingBubbleIds: [String: String] = [:]
    // PATCH-2026-05-13: parallel-sessions — also stash the optimistic user
    // turn (id + content) for each in-flight session. If the user switches
    // away/back before the daemon has persisted the user message, we
    // re-inject it so the visible session shows both the prompt and the
    // streaming reply, not just the reply.
    public var streamingUserTurnIds: [String: String] = [:]
    public var streamingUserTurnTexts: [String: String] = [:]
    /// First instant each `streamingSessions` id was observed. Not observed,
    /// so reading it during a SwiftUI view update cannot invalidate that
    /// update.
    @ObservationIgnored private var streamingSeenAt: [String: Date] = [:]

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.runtime = MacChatTurnRuntime(dataRoot: dataRoot)
    }

    // MARK: - Per-session reads

    public func lifecycle(for sessionId: String) -> MacChatTurnLifecycleState? {
        lifecycleBySession[sessionId]
    }

    /// What the agent is looking at in this session, if it is driving the Mac.
    public func screenPreview(for sessionId: String) -> MacChatScreenPreview? {
        screenPreviewBySession[sessionId]
    }

    /// Presentation reads only. Admission, cancellation and queue drain use
    /// the runtime sets/tasks, including while a reply looks settled.
    public func isBusy(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return busySessions.contains(sessionId) && !isReplyTextSettled(sessionId)
    }

    public func isStreaming(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return streamingSessions.contains(sessionId) && !isReplyTextSettled(sessionId)
    }

    public func isReplyTextSettled(_ sessionId: String) -> Bool {
        lifecycleBySession[sessionId]?.replyTextSettled == true
    }

    public var visiblyWorkingSessionIDs: Set<String> {
        busySessions.union(streamingSessions).filter { !isReplyTextSettled($0) }
    }

    /// True if any session anywhere is streaming.
    public var anyStreaming: Bool { !streamingSessions.isEmpty }

    public func queued(for sessionId: String) -> [QueuedChatTurn] {
        guard !sessionId.isEmpty else { return [] }
        return queuedBySession[sessionId] ?? []
    }

    public func isQueuePaused(_ sessionId: String) -> Bool {
        pausedQueueSessions.contains(sessionId)
    }

    /// Why the queue paused, when it paused because the next turn could not
    /// start. Nil for a Stop-pause and for a queue that is running.
    public func queuePauseReason(_ sessionId: String) -> String? {
        guard isQueuePaused(sessionId) else { return nil }
        guard let reason = queuePauseReasons[sessionId]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty
        else { return nil }
        return reason
    }

    /// The live-task-backed running set used by pinned conversation tabs.
    /// `streamingSessions` is intentionally a broad runtime marker while a
    /// producer unwinds, migrates a placeholder, or processes Stop. A tab's
    /// green dot is a narrower claim: this exact session still has an
    /// in-flight chat task. Intersecting the two owners prevents a stale
    /// marker from becoming permanent "running" chrome.
    public var runningTabSessionIDs: Set<String> {
        Set(Set(tasks.keys).intersection(streamingSessions).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isReplyTextSettled($0)
        })
    }

    /// `streamingSessions` filtered to markers young enough to still belong to
    /// a live turn.
    ///
    /// `finishRuntime` returns early when the generation no longer matches —
    /// correctly, since clearing there would wipe a NEWER turn's marker — so a
    /// turn that dies between the generation bump and its own cleanup leaves
    /// its id in `streamingSessions` forever, and the "other sessions running"
    /// banner never comes down. Ids are stamped on first observation and
    /// un-stamped the moment they leave the set, so a re-started session
    /// always starts a fresh clock. Live turns are untouched: nothing
    /// legitimate outlives the provider guard's ceiling.
    public var liveStreamingSessionIDs: Set<String> {
        let current = streamingSessions
        if streamingSeenAt.count != current.count {
            streamingSeenAt = streamingSeenAt.filter { current.contains($0.key) }
        }
        let ceiling = Self.streamingMarkerCeilingSeconds
        let now = Date()
        var live: Set<String> = []
        for id in current {
            let seenAt = streamingSeenAt[id] ?? now
            streamingSeenAt[id] = seenAt
            if ceiling <= 0 || now.timeIntervalSince(seenAt) <= ceiling { live.insert(id) }
        }
        return live.filter { !isReplyTextSettled($0) }
    }

    /// Seconds a `streamingSessions` marker may stand before it is treated as
    /// a ghost: the provider stream guard's own hard wall ceiling, since a
    /// turn cannot outlive it. Zero (guard disabled) means never expire.
    public nonisolated static let streamingMarkerCeilingSeconds: TimeInterval =
        ProviderStreamGuardConfig.fromEnvironment().wallTimeout

    // MARK: - Runtime

    /// Clears one exact task generation after its producer has reached a
    /// terminal path. Generation matching prevents a late completion or
    /// failure from clearing the running marker for a newer turn.
    @discardableResult
    public func finishRuntime(sessionId: String, generation: Int) -> Bool {
        runtime.finishRuntime(sessionId: sessionId, generation: generation)
    }

    public func clearStreamingBubbleState(_ sessionId: String) {
        streamingTexts[sessionId] = nil
        streamingBubbleIds[sessionId] = nil
        streamingUserTurnIds[sessionId] = nil
        streamingUserTurnTexts[sessionId] = nil
        replyingSessions.remove(sessionId)
    }

    // MARK: - Stop and the run registry

    /// The durable half of Stop: `chat/sessions/<id>/cancelled.flag`, naming
    /// the runs in flight on this session so only they stop (ChatCancelFlag).
    /// The streaming tool loop checks this marker to abort in flight.
    public nonisolated func stop(sessionId: String) async throws {
        try await runtime.stop(sessionId: sessionId)
    }

    /// Every run accepted and not yet finished, on any session and surface.
    public nonisolated func inFlightRunIDs() -> Set<String> {
        ChatCancelFlag.inFlightRunIDs()
    }
}
