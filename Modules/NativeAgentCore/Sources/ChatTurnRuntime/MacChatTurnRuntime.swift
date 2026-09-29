import Foundation
import Observation
import NativeAgentShared
import NativeAgentCore
import Transcripts
import PersistenceCore

/// Process-local admission and lifecycle authority for Mac chat. Presentation
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
    public var queuedBySession: [String: [QueuedChatTurn]] = [:]
    public var pausedQueueSessions: Set<String> = []
    public var queuePauseReasons: [String: String] = [:]
    @ObservationIgnored public var drainingQueueSessions: Set<String> = []
    public var pendingStopWrites: [String: Task<Void, Never>] = [:]
    public var pendingStopWriteGenerations: [String: Int] = [:]
    @ObservationIgnored public var chatTurnTranscriptProofReader: any MacChatTurnTranscriptProofReading = MacChatTurnTranscriptProofReader()
    @ObservationIgnored public var chatTurnLifecycleRepairCompleted = false
    @ObservationIgnored public var queuedChatTurnStartOverride: (@MainActor @Sendable (QueuedChatTurn, String) async -> MacChatTurnAcceptance)?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.lifecycleStore = MacChatTurnLifecycleStore(
            fileURL: dataRoot.appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("mac_turn_lifecycle.json")
        )
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
