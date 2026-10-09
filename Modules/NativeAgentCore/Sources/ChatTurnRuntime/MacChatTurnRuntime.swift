import Foundation
import Observation
import NativeAgentShared
import NativeAgentCore
import Transcripts
import PersistenceCore

/// Admission, durable queue and lifecycle authority for Mac chat. Presentation
/// facades observe this same state; no second queue or lifecycle is retained.
@MainActor
@Observable
public final class MacChatTurnRuntime {
    /// Ordinary sends, retries and receipt follow-ups share this runtime's
    /// session slot through transcript settlement, including detached chat
    /// and local bridge turns that also carry the chat surface.
    public func runAdmittedTurn<T>(sessionID: String, operation: () async throws -> T) async throws -> T {
        try await TurnAdmission.shared.run(sessionID: sessionID, operation: operation)
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
    public var lifecycleBySession: [String: MacChatTurnLifecycleState] = [:]
    @ObservationIgnored public var activeTurnIDsBySession: [String: String] = [:]
    @ObservationIgnored public var streamProgressAppliedAt: [String: (turnId: String, at: Date)] = [:]
    @ObservationIgnored public var lifecycleStore: MacChatTurnLifecycleStore
    private var queueState: [String: [QueuedChatTurn]] = [:]
    @ObservationIgnored public private(set) var queueStorageError: String?
    @ObservationIgnored private var queueLoad: Task<Void, Never>?
    @ObservationIgnored private var queueWrite: Task<Bool, Never>?
    public var queuedBySession: [String: [QueuedChatTurn]] { queueState }

    @discardableResult
    public func updateQueuedTurns(_ change: @escaping @MainActor @Sendable (inout [String: [QueuedChatTurn]]) -> Void) async -> Bool {
        await loadQueuedTurnsIfNeeded()
        let previous = queueWrite
        let write = Task { @MainActor in
            _ = await previous?.value
            guard queueStorageError == nil else { return false }
            var next = queueState
            change(&next)
            guard next != queueState else { return true }
            do {
                queueState = try await lifecycleStore.saveQueuedTurns(next)
                return true
            } catch {
                queueStorageError = "Send-next storage is unavailable. Repair chat/mac_turn_lifecycle.json and restart NativeAgent before sending: \(error.localizedDescription)"
                for session in Set(queueState.keys).union(next.keys) {
                    pausedQueueSessions.insert(session)
                    queuePauseReasons[session] = queueStorageError
                }
                return false
            }
        }
        queueWrite = write
        return await write.value
    }
    public var pausedQueueSessions: Set<String> = []
    public var queuePauseReasons: [String: String] = [:]
    /// Queued turns User chose to Steer: offered to the running turn, not yet taken.
    public var steeringTurnIDs: Set<String> = []
    @ObservationIgnored public var drainingQueueSessions: Set<String> = []
    public var pendingStopWrites: [String: Task<Void, Never>] = [:]
    public var pendingStopWriteGenerations: [String: Int] = [:]
    /// Bumped by every control handoff. A remote input that entered under an
    /// older value was already waiting when control was released.
    @ObservationIgnored public var controlHandoffGenerations: [String: Int] = [:]
    /// The newest phone handoff's own send time. Later-arriving phone inputs
    /// are ordered against it on the phone's clock, never the Mac's.
    @ObservationIgnored public var phoneControlHandoffSentAt: [String: Date] = [:]
    @ObservationIgnored public var chatTurnTranscriptProofReader: any MacChatTurnTranscriptProofReading = MacChatTurnTranscriptProofReader()
    @ObservationIgnored public var chatTurnLifecycleRepairCompleted = false
    @ObservationIgnored public var queuedChatTurnStartOverride: (@MainActor @Sendable (QueuedChatTurn, String) async -> MacChatTurnAcceptance)?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.lifecycleStore = MacChatTurnLifecycleStore(
            fileURL: dataRoot.appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("mac_turn_lifecycle.json")
        )
        self.chatTurnTranscriptProofReader = MacChatTurnTranscriptProofReader(dataRoot: dataRoot)
    }

    public func loadQueuedTurnsIfNeeded() async {
        if queueLoad == nil {
            queueLoad = Task { await restoreQueuedTurns() }
        }
        await queueLoad?.value
    }

    private func restoreQueuedTurns() async {
        do {
            let loaded = try await lifecycleStore.queuedTurns()
            var saved = loaded
            let records = try await lifecycleStore.records()
            for (session, turns) in saved where turns.contains(where: { $0.startedTurnID != nil }) {
                var waiting: [QueuedChatTurn] = []
                for var turn in turns {
                    if let started = turn.startedTurnID {
                        let identity = MacChatTurnIdentity(sessionId: session, turnId: started)
                        let wasSteering = started != turn.id
                        let record = records.first { $0.identity == identity }
                        if record?.isTerminal == true,
                           record?.terminalEvidence != .interruptedOutcomeUnknown,
                           !wasSteering || record?.terminalEvidence == .finalResponsePersisted { continue }
                        switch try await chatTurnTranscriptProofReader.proof(for: identity) {
                        case .completed: continue
                        case .failed, .canceled:
                            if !wasSteering { continue }
                            turn.startedTurnID = nil
                        case .unavailable: throw MacChatTurnLifecycleStoreError.invalidRecord
                        case .absent: turn.startedTurnID = nil
                        }
                        pausedQueueSessions.insert(session)
                        queuePauseReasons[session] = "A queued turn was interrupted. Check its conversation before resuming it."
                    }
                    waiting.append(turn)
                }
                saved[session] = waiting.isEmpty ? nil : waiting
            }
            queueState = saved == loaded ? saved : try await lifecycleStore.saveQueuedTurns(saved)
        } catch {
            self.queueStorageError = "Send-next storage is unavailable. Repair chat/mac_turn_lifecycle.json and restart NativeAgent before sending: \(error.localizedDescription)"
        }
    }

    public func lifecycle(for sessionId: String) -> MacChatTurnLifecycleState? {
        lifecycleBySession[sessionId]
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
        sessionId: String, pauseQueuedTurns: Bool = true,
        revokeDriverControl: (@MainActor @Sendable () async -> Void)? = nil
    ) -> Task<Void, Never> {
        if pauseQueuedTurns {
            pausedQueueSessions.insert(sessionId)
            queuePauseReasons.removeValue(forKey: sessionId)
        } else {
            pausedQueueSessions.remove(sessionId)
        }
        let activeTask = tasks[sessionId]
        let generation = (pendingStopWriteGenerations[sessionId] ?? 0) + 1
        pendingStopWriteGenerations[sessionId] = generation
        let previousWrite = pendingStopWrites[sessionId]
        if revokeDriverControl == nil {
            activeTask?.cancel()
            tasks[sessionId] = nil
            streamingSessions.remove(sessionId)
        }
        let write = Task { @MainActor in
            if let revokeDriverControl {
                await revokeDriverControl()
                activeTask?.cancel()
                if tasks[sessionId] == activeTask {
                    tasks[sessionId] = nil
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

    public nonisolated func stop(sessionId: String) async throws {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw NSError(
                domain: "NativeAgentChatSession",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Cannot cancel chat session: invalid chat session id"]
            )
        }
        let flagPath = ChatCancelFlag.path(dataRoot: dataRoot, sessionId: safeSessionId)
        try await SwiftNativePersistenceCore().withFileLock(flagPath) {
            let parent = flagPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(ChatCancelFlag.stopContent(forFlagAt: flagPath).utf8).write(to: flagPath, options: .atomic)
        }
    }
}
