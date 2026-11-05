import AuthoredCapabilities
import Transcripts
import Foundation
import Observation
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TrustCenter
import Dispatcher
import Cognition
import AppToolRuntime
import Senses
// Blueprint: | `EngineTurns.swift` | Canonical turn/Stop presentation and independent read-only pane publication |

/// Share per-root Mac turn presentation across surfaces; runtime owns admission, Stop and lifecycle. Nonisolated run registry reads also
/// serve phone and quit.
@MainActor
@Observable
public final class TurnsFacade {
    public private(set) var capabilityTraceTimeline: CapabilityTraceFeed.State = .unread
    @ObservationIgnored private let tracesRead = LatestRead()
    @ObservationIgnored private var paneReads: [String: [String: LatestRead]] = [:]

    public func refreshCapabilityTraces() async {
        _ = await tracesRead.read({ await CapabilityTraceFeed.read(dataRoot: dataRoot) },
            publish: { capabilityTraceTimeline = $0 })
    }

    public nonisolated let dataRoot: URL
    public nonisolated let runtime: MacChatTurnRuntime
    public private(set) var agentScreenPanes: [String: [String: String]] = [:]

    @discardableResult
    public func readAgentScreen(room: String, scope: String) async -> String {
        let latest = paneReads[scope]?[room] ?? LatestRead()
        paneReads[scope, default: [:]][room] = latest
        let invocation = ChatToolInvocation()
        let execution = AppActionExecution(invocation: invocation, deadlines: invocation.deadlines,
            turnWork: .init(toolInvocation: invocation))
        let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot, turn: nil, execution: execution) { _, _, _, _ in
            nil
        }
        let preview = invocation.with(\.programHost, host)
        return await latest.read({ await AgentScreenPreview.paneText(room, root: dataRoot, scope: scope, invocation: preview) },
            publish: { agentScreenPanes[scope, default: [:]][room] = $0 })
    }

    public func observeAgentScreen(room: String, scope: String) async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: AgentScreenPreview.watchedPaths.map { dataRoot.appendingPathComponent($0) },
            notifications: [AgentScreenPreview.didChange, AbilityStore.didChange]) {
            _ = await self.readAgentScreen(room: room, scope: scope)
        }
    }

    // Keep state per session so conversations can run concurrently.
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
    /// Publish streaming presence only at first nonempty text and turn end so window haze does not update per token.
    public var replyingSessions: Set<String> {
        get { runtime.replyingSessions }
        set { runtime.replyingSessions = newValue }
    }
    public var tasks: [String: Task<Void, Never>] {
        get { runtime.tasks }
        set { runtime.tasks = newValue }
    }
    public var taskGenerations: [String: Int] {
        get { runtime.taskGenerations }
        set { runtime.taskGenerations = newValue }
    }
    /// Reduce operational events, Stop and evidence-backed terminals into one Mac presentation lifecycle.
    public var lifecycleBySession: [String: MacChatTurnLifecycleState] {
        get { runtime.lifecycleBySession }
        set { runtime.lifecycleBySession = newValue }
    }
    /// Scope computer preview to the turn card; close it with intake and leave untouched turns empty.
    public var screenPreviewBySession: [String: MacChatScreenPreview] {
        get { runtime.screenPreviewBySession }
        set { runtime.screenPreviewBySession = newValue }
    }
    public var activeTurnIDsBySession: [String: String] {
        get { runtime.activeTurnIDsBySession }
        set { runtime.activeTurnIDsBySession = newValue }
    }
    public var lifecycleStore: MacChatTurnLifecycleStore {
        get { runtime.lifecycleStore }
        set { runtime.lifecycleStore = newValue }
    }
    // Keep restoration state unobserved; publish coalesced message updates to views.
    @ObservationIgnored public var streamingTexts: [String: String] = [:]
    public var streamingBubbleIds: [String: String] = [:]
    // Retain optimistic user rows across in-flight session switches until durable transcripts supply them.
    /// Keep first-stream timestamps unobserved so reads during SwiftUI updates cannot invalidate that update.
    @ObservationIgnored private var streamingSeenAt: [String: Date] = [:]

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.runtime = MacChatTurnRuntime(dataRoot: dataRoot)
    }

    // MARK: - Per-session reads

    public func lifecycle(for sessionId: String) -> MacChatTurnLifecycleState? {
        lifecycleBySession[sessionId]
    }

    public func screenPreview(for sessionId: String) -> MacChatScreenPreview? {
        screenPreviewBySession[sessionId]
    }

    /// Presentation never decides operational liveness; admission, cancellation and drain use runtime tasks and sets.
    public func isBusy(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return busySessions.contains(sessionId) && !isReplyTextSettled(sessionId)
    }

    public func isStreaming(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return streamingSessions.contains(sessionId) && !isReplyTextSettled(sessionId)
    }

    public func isReplyTextSettled(_ sessionId: String) -> Bool {
        runtime.replyTextSettledSessions.contains(sessionId)
    }

    public var visiblyWorkingSessionIDs: Set<String> {
        busySessions.union(streamingSessions).filter { !isReplyTextSettled($0) }
    }

    public func isThinkingBeforeReply(for sessionId: String) -> Bool {
        guard isBusy(sessionId) || isStreaming(sessionId) else { return false }
        guard let lifecycle = lifecycle(for: sessionId) else { return true }
        return !lifecycle.presentation.isTerminal && lifecycle.presentation.streamedTextLength == 0
    }

    /// Only orphaned markers expire; live tasks can outlast individual provider stream limits.
    public var liveStreamingSessionIDs: Set<String> {
        let current = streamingSessions
        streamingSeenAt = streamingSeenAt.filter { current.contains($0.key) }
        let ceiling = Self.streamingMarkerCeilingSeconds
        let now = Date()
        var live: Set<String> = []
        for id in current {
            let seenAt = streamingSeenAt[id] ?? now
            streamingSeenAt[id] = seenAt
            // An unavailable deadline cannot prove expiry; provider execution owns invalid-config refusal.
            if tasks[id] != nil || !ceiling.isFinite || ceiling <= 0 || now.timeIntervalSince(seenAt) <= ceiling { live.insert(id) }
        }
        return live.filter { !isReplyTextSettled($0) }
    }

    /// Zero disables orphan expiry rather than expiring immediately.
    public nonisolated static let streamingMarkerCeilingSeconds: TimeInterval =
        ProviderStreamGuardConfig.fromEnvironment().wallTimeout

    // MARK: - Runtime

    /// Clear only the producer’s exact generation so late completion cannot clear a newer turn.
    @discardableResult
    public func finishRuntime(sessionId: String, generation: Int) -> Bool {
        runtime.finishRuntime(sessionId: sessionId, generation: generation)
    }

    public func clearStreamingBubbleState(_ sessionId: String) {
        streamingTexts[sessionId] = nil
        streamingBubbleIds[sessionId] = nil
        replyingSessions.remove(sessionId)
    }

    // MARK: - Stop and the run registry

    /// Persist Stop with exact in-flight run ids so cancellation cannot spill into later turns.
    public nonisolated func stop(sessionId: String) async throws {
        try await runtime.stop(sessionId: sessionId)
    }

    public nonisolated func inFlightRunIDs() -> Set<String> {
        ChatCancelFlag.inFlightRunIDs()
    }

    /// Keep cross-surface in-flight reads distinct from Mac-owned turn ids, whose Stop, steer and lifecycle controls apply only to Mac turns.
    public nonisolated func inFlightTurns() -> [ChatCancelFlag.InFlightTurn] {
        ChatCancelFlag.inFlightTurns(dataRoot: dataRoot)
    }
}
