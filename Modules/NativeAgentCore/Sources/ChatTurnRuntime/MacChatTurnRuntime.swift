import Foundation
import CoreGraphics
import AgentWorkspace
import Observation
import NativeAgentShared
import NativeAgentCore
import Transcripts
import PersistenceCore
// Blueprint: | `MacChatTurnRuntime.swift` | Canonical Mac admission, lifecycle and preview state |

/// Admission and lifecycle authority for Mac chat. Presentation facades
/// observe this same state; no second lifecycle is retained.
@MainActor
@Observable
public final class MacChatTurnRuntime {
    /// All Mac entry points share one session slot through transcript settlement.
    /// Register and pin the run for Stop synchronously before any await so cancellation always names the accepted run.
    public func runAdmittedTurn<T>(sessionID: String, turnID: String, arrival: TurnArrival,
                                   turn: Turn, operation: (Turn) async throws -> T) async throws -> TurnAdmission.Admitted<T> {
        let stop = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: sessionID, runId: turn.run, turnId: turnID)
        defer { ChatCancelFlag.finish(stop) }
        try Task.checkCancellation()
        return try await TurnAdmission.shared.run(dataRoot: dataRoot, sessionID: sessionID, arrival: arrival, turn: turn, operation: operation)
    }

    /// A regenerate replaces an answer, so it never joins another turn.
    public func runAloneTurn<T>(sessionID: String, turnID: String,
                                turn: Turn, operation: (Turn) async throws -> T) async throws -> T {
        let stop = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: sessionID, runId: turn.run, turnId: turnID)
        defer { ChatCancelFlag.finish(stop) }
        try Task.checkCancellation()
        return try await TurnAdmission.shared.runAlone(dataRoot: dataRoot, sessionID: sessionID, turn: turn, operation: operation)
    }

    public nonisolated static let streamProgressCoalesceSeconds: TimeInterval = 1.0
    public nonisolated let dataRoot: URL
    @ObservationIgnored public var activityDidChange: (@MainActor () -> Void)?
    public var busySessions: Set<String> = [] {
        didSet { if busySessions != oldValue { activityDidChange?() } }
    }
    public var streamingSessions: Set<String> = [] {
        didSet { if streamingSessions != oldValue { activityDidChange?() } }
    }
    public var tasks: [String: Task<Void, Never>] = [:]
    public var taskGenerations: [String: Int] = [:]
    @ObservationIgnored private var nextTaskGeneration = 0

    /// One session reservation for sends, retries and checkpoint resumes,
    /// acquired synchronously before any admission read can suspend.
    public func reserveTurn(sessionId: String) -> Int? {
        guard tasks[sessionId] == nil, !busySessions.contains(sessionId) else { return nil }
        nextTaskGeneration += 1
        taskGenerations[sessionId] = nextTaskGeneration
        busySessions.insert(sessionId)
        return nextTaskGeneration
    }
    public var replyingSessions: Set<String> = [] {
        didSet { if replyingSessions != oldValue { activityDidChange?() } }
    }
    public var screenPreviewBySession: [String: MacChatScreenPreview] = [:]
    public var lifecycleBySession: [String: MacChatTurnLifecycleState] = [:] {
        didSet {
            let settled = Set(lifecycleBySession.compactMap { $0.value.replyTextSettled ? $0.key : nil })
            if settled != replyTextSettledSessions { replyTextSettledSessions = settled }
        }
    }
    /// Observe settled-text changes separately from 1 Hz lifecycle progress so transcript views need not rerender on every progress tick.
    public private(set) var replyTextSettledSessions: Set<String> = []
    @ObservationIgnored public var activeTurnIDsBySession: [String: String] = [:]
    @ObservationIgnored public var streamProgressAppliedAt: [String: (turnId: String, at: Date)] = [:]
    @ObservationIgnored public var lifecycleStore: MacChatTurnLifecycleStore
    public var pendingStopWrites: [String: Task<Void, Never>] = [:]
    public var pendingStopWriteGenerations: [String: Int] = [:]
    /// Control handoffs invalidate inputs admitted under an older epoch.
    @ObservationIgnored public var controlHandoffGenerations: [String: Int] = [:]
    /// The newest phone handoff's own send time. Later-arriving phone inputs
    /// are ordered against it on the phone's clock, never the Mac's.
    @ObservationIgnored public var phoneControlHandoffSentAt: [String: Date] = [:]
    @ObservationIgnored public let chatTurnTranscriptProofReader: MacChatTurnTranscriptProofReader
    @ObservationIgnored public var chatTurnLifecycleRepairCompleted = false

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.lifecycleStore = MacChatTurnLifecycleStore(
            fileURL: dataRoot.appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("mac_turn_lifecycle.json")
        )
        self.chatTurnTranscriptProofReader = MacChatTurnTranscriptProofReader(dataRoot: dataRoot)
    }

    public func lifecycle(for sessionId: String) -> MacChatTurnLifecycleState? {
        lifecycleBySession[sessionId]
    }

    public func pruneSessionState(_ sessionId: String) {
        let activeTurnId = activeTurnIDsBySession[sessionId]
        let retainedTurnId = activeTurnId == nil ? lifecycleBySession[sessionId]?.identity.turnId : nil
        // A joined producer still owns its terminal proof during Stop/Archive.
        if activeTurnId == nil {
            lifecycleBySession.removeValue(forKey: sessionId)
            activeTurnIDsBySession.removeValue(forKey: sessionId)
        }
        if let retainedTurnId {
            Task { [lifecycleStore] in
                try? await lifecycleStore.remove(sessionId: sessionId, turnId: retainedTurnId)
            }
        }
    }

    public func staleSessionIDs(
        cached: Set<String>, known: Set<String>, keepVisible: (String) -> Bool
    ) -> Set<String> {
        let candidates = cached.union(lifecycleBySession.keys).union(activeTurnIDsBySession.keys)
        return candidates.filter {
            !known.contains($0) && !streamingSessions.contains($0)
                && !busySessions.contains($0) && !keepVisible($0)
        }
    }
    /// Waiters for a Mac session to move resume when any task or reservation changes, then recheck their own session.
    public func sessionSlotChange() async {
        await withCheckedContinuation { moved in
            withObservationTracking { _ = (tasks, busySessions) } onChange: { moved.resume() }
        }
    }

    public func finishRuntime(sessionId: String, generation: Int) -> Bool {
        guard taskGenerations[sessionId] == generation else { return false }
        streamingSessions.remove(sessionId)
        busySessions.remove(sessionId)
        tasks[sessionId] = nil
        taskGenerations[sessionId] = nil
        return true
    }

    /// Install the Stop barrier before any revocation can suspend. Every
    /// subsequent admission waits for this same marker write.
    @discardableResult
    public func requestStop(
        sessionId: String,
        revokeDriverControl: (@MainActor @Sendable () async -> Void)? = nil
    ) -> Task<Void, Never> {
        let activeTask = tasks[sessionId]
        // A reservation still reading admission data has no task to cancel.
        // Revoke that reservation now; its suspended holder must not start.
        if activeTask == nil, let reserved = taskGenerations[sessionId] {
            _ = finishRuntime(sessionId: sessionId, generation: reserved)
        }
        let generation = (pendingStopWriteGenerations[sessionId] ?? 0) + 1
        pendingStopWriteGenerations[sessionId] = generation
        let previousWrite = pendingStopWrites[sessionId]
        if revokeDriverControl == nil {
            activeTask?.cancel()
            streamingSessions.remove(sessionId)
        }
        let write = Task { @MainActor in
            if let revokeDriverControl {
                await revokeDriverControl()
                activeTask?.cancel()
                if tasks[sessionId] == activeTask {
                    streamingSessions.remove(sessionId)
                }
            }
            await previousWrite?.value
            try? await stop(sessionId: sessionId)
            if pendingStopWriteGenerations[sessionId] == generation {
                pendingStopWrites[sessionId] = nil
                pendingStopWriteGenerations[sessionId] = nil
            }
        }
        pendingStopWrites[sessionId] = write
        return write
    }

    /// Explicit run IDs stop only named work; a shared contact session may also hold unrelated queued runs from other doors.
    public nonisolated func stop(sessionId: String, runId: String? = nil, runIDs: [String] = []) async throws {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw NSError(
                domain: "NativeAgentChatSession",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Cannot cancel chat session: invalid chat session id"]
            )
        }
        let namedRuns = runIDs + (runId.map { [$0] } ?? [])
        let flagPath = ChatCancelFlag.path(dataRoot: dataRoot, sessionId: safeSessionId)
        try await SwiftNativePersistenceCore.withFileLock(flagPath) {
            let existing: String?
            do { existing = try String(contentsOf: flagPath, encoding: .utf8) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
            // A failed read cannot authorize replacing earlier Stop requests.
            catch {
                throw ToolFailureError("""
                    The existing Stop marker could not be read: \(error.localizedDescription). Its bytes were preserved. Repair \(flagPath.path) \
                    before merging another Stop request.
                    """,
                    effects: .none, owner: flagPath.path, code: "stop_marker_unavailable", recovery: .repair)
            }
            let requested = namedRuns.isEmpty ? ChatCancelFlag.stopContent(forFlagAt: flagPath) : namedRuns.joined(separator: "\n")
            // An existing empty marker means stop-all; preserve its exact meaning.
            let content = existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0 : $0 + "\n" + requested } ?? requested
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(content.utf8), to: flagPath)
        }
    }
}

/// Preview is transient display only; receipts retain effect truth and no frame becomes memory.
/// Capture already downscales and masks secrets; presentation must not reinterpret what may be shown.
public struct MacChatScreenPreview: @unchecked Sendable {
    /// Missing capture permission, locked screens and refusals may update the caption without supplying a frame.
    public let image: CGImage?
    public let caption: String
    public let updatedAt: Date

    /// Show a pane only when both caption and frame exist.
    public var isShowable: Bool {
        image != nil && !caption.isEmpty
    }

    /// Nil update fields preserve the previous value so caption-only actions retain their window evidence.
    public static func merged(
        _ previous: MacChatScreenPreview?,
        update: MacScreenPreviewUpdate
    ) -> MacChatScreenPreview? {
        let image = update.image ?? previous?.image
        let caption = update.caption ?? previous?.caption ?? ""
        guard image != nil || !caption.isEmpty else { return nil }
        return MacChatScreenPreview(image: image, caption: caption, updatedAt: update.at)
    }
}
