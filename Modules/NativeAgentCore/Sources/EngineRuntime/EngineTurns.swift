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
import WorkshopExecution
import TrustCenter
import Dispatcher
import Cognition
import AppToolRuntime
import Senses
// Blueprint: | `EngineTurns.swift` | TurnsFacade owns turn lifecycle/Stop/queue/screen-preview presentation, one Capabilities trace feed without an extracted copy, and read-only Agent View pane text/subscriptions keyed by conversation and room; LatestRead orders trace publication and each pane independently. The preview binds L0's pure helper face to its native root without effects and preserves last-seen semantics |

/// `NativeAgentEngine.turns`: the Mac's running chat turns for one data
/// root — which sessions are thinking, streaming and replying, each session's
/// turn lifecycle (the working card), the live computer pane, the queue behind
/// a running turn, and Stop. Chat, detached panels, the sidebar, Simple view
/// and the window haze render this state; Core owns admission, send-next,
/// Stop and lifecycle authority through `runtime`. The run registry is nonisolated so
/// the phone lanes and quit use the same owner.
@MainActor
@Observable
public final class TurnsFacade {
    public private(set) var capabilityTraceTimeline: CapabilityTraceFeed.State = .sourceAbsent
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
        let host=AppToolExecutor.authoredProgramHost(dataRoot:dataRoot) { _,_ in nil }
        return await OwnedProgramInvocation.$host.withValue(host) {
            await latest.read({ await HerScreenPreview.paneText(room, root: dataRoot, scope: scope) },
                publish: { agentScreenPanes[scope, default: [:]][room] = $0 })
        }
    }

    public func observeAgentScreen(room: String, scope: String) async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: HerScreenPreview.watchedPaths.map { dataRoot.appendingPathComponent($0) },
            notifications: [HerScreenPreview.didChange]) {
            _ = await self.readAgentScreen(room: room, scope: scope)
        }
    }

    // Per-session chat state supports concurrent conversations.
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
    public var screenPreviewBySession: [String: MacChatScreenPreview] {
        get { runtime.screenPreviewBySession }
        set { runtime.screenPreviewBySession = newValue }
    }
    public var activeTurnIDsBySession: [String: String] {
        get { runtime.activeTurnIDsBySession }
        set { runtime.activeTurnIDsBySession = newValue }
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
        runtime.queuedBySession
    }
    /// A manual Stop pauses automatic queue drain for that session. Natural
    /// completion drains immediately; Send now explicitly unpauses and promotes.
    public var pausedQueueSessions: Set<String> {
        get { runtime.pausedQueueSessions }
        set { runtime.pausedQueueSessions = newValue }
    }
    /// Queue pause reasons preserve queued-start rejections so the person can see why work paused.
    public var queuePauseReasons: [String: String] {
        get { runtime.queuePauseReasons }
        set { runtime.queuePauseReasons = newValue }
    }
    // Unobserved text and bubble IDs restore an in-flight session; views receive coalesced message updates.
    @ObservationIgnored public var streamingTexts: [String: String] = [:]
    public var streamingBubbleIds: [String: String] = [:]
    // Keep the optimistic user turn while switching between in-flight sessions,
    // until the Swift turn runtime's durable transcript supplies it.
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

    public func queued(for sessionId: String) -> [QueuedChatTurn] {
        guard !sessionId.isEmpty else { return [] }
        return queuedBySession[sessionId] ?? []
    }

    /// Steered: offered to the running turn, still queued until it takes it.
    public func isSteering(_ turnId: String) -> Bool {
        runtime.steeringTurnIDs.contains(turnId)
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

    /// Task-backed turns remain live regardless of age. Only orphaned runtime
    /// markers expire; the provider guard bounds one stream, not the whole turn.
    public var liveStreamingSessionIDs: Set<String> {
        let current = streamingSessions
        streamingSeenAt = streamingSeenAt.filter { current.contains($0.key) }
        let ceiling = Self.streamingMarkerCeilingSeconds
        let now = Date()
        var live: Set<String> = []
        for id in current {
            let seenAt = streamingSeenAt[id] ?? now
            streamingSeenAt[id] = seenAt
            if tasks[id] != nil || ceiling <= 0 || now.timeIntervalSince(seenAt) <= ceiling { live.insert(id) }
        }
        return live.filter { !isReplyTextSettled($0) }
    }

    /// Seconds an orphaned streaming marker may stand before it expires.
    /// Zero (guard disabled) means never expire.
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

    /// Every turn in flight on this root's sessions, whichever door started
    /// it. The Mac chat's own are the ones in `activeTurnIDsBySession`, which
    /// stays the Mac's alone: Stop, steer, the lifecycle receipt and busy act
    /// on it, and a turn another door started has none of those here.
    public nonisolated func inFlightTurns() -> [ChatCancelFlag.InFlightTurn] {
        ChatCancelFlag.inFlightTurns(dataRoot: dataRoot)
    }
}


struct EngineWorkshopSessionEffects: WorkshopSessionEffects {
    /// A turn's app door, the authored-program host included; the session
    /// turn's own gate resolves autonomy once.
    func makeToolDispatcher(dataRoot: URL) -> any ToolDispatchClient {
        NativeAgentEngine.forRoot(dataRoot).toolDispatchClient(enforceAppAutonomy: false)
    }

    /// One ephemeral tool turn on "workshop" ("missions" on historical installs), under User's posture.
    /// No chat session or transcript is created; its pinned model comes from the surface picker.
    func productionTurnExecutor(
        dataRoot: URL
    ) -> @Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String) {
        return { request, tools in
            let client = NativeAgentEngine.live.chatClient(tools: tools)
            let response = try await LLMCallContext.$purpose.withValue("workshop") {
            try await client.runEphemeralToolTurn(
                message: request.promptSeed,
                fileAccess: "auto",
                requireCompleted: true,
                surface: WorkshopSurfaceVocabulary.canonical
            )
            }
            return (response.model, response.output)
        }
    }
}

extension NativeAgentEngine {
    @MainActor
    public func compactSession(
        sessionId: String, model: String? = nil, providerID: String? = nil,
        force: Bool = false, client: SwiftNativeChatOrchestrationClient
    ) async throws -> ChatSessionCompactionOutcome {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.flatMap { $0.isEmpty ? nil : $0 }
        let routedModel = await providers.routing.modelStringForSurface("compaction")
        let outcome = try await client.compactSession(
            sessionId: sessionId, model: resolvedModel ?? routedModel ?? "",
            surface: "compaction", runId: nil, providerID: providerID, force: force)
        if outcome.compacted {
            NotificationCenter.default.post(name: .chatTurnCompleted, object: outcome.sessionId)
        }
        return outcome
    }
}
