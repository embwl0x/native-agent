import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AbandonedTurnReconciliationHook.swift` | Engine-owned checkpoint recovery and cancellation-aware trace flush |

/// Resume checkpoints and reconcile prior-process trace evidence once at launch.
@MainActor
package final class AbandonedTurnReconciliation {
    private let dataRoot: URL
    private let traceBus: TurnTraceBus
    private var generation: UUID?
    private var sweepTask: Task<Void, Never>?
    private var resumeJobs: [UUID: Task<Void, Never>] = [:]
    private var resuming: Set<String> = []
    private var resume: (@Sendable (TurnCheckpoint) async throws -> Void)?

    package nonisolated init(dataRoot: URL, traceBus: TurnTraceBus) {
        self.dataRoot = dataRoot
        self.traceBus = traceBus
    }

    private func inFlight() -> Set<String> { Set(ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).map(\.turnId)) }

    package func arm(resume: @escaping @Sendable (TurnCheckpoint) async throws -> Void) {
        guard generation == nil else { return }
        self.resume = resume
        generation = UUID()
        // Pin the process epoch at launch: only turns accepted BEFORE it are ever reconcilable.
        _ = AbandonedTurnReconciler.processEpoch
        sweepAtLaunch()
    }

    package func disarm() {
        generation = nil
        sweepTask?.cancel()
        // A queued job checks the generation before admission. A resume that already began is accepted turn work and keeps its owner until exit.
        resume = nil
    }

    package func reconcile(sessionId: String, turnId: String) async throws {
        try Task.checkCancellation()
        guard let resume else {
            throw ToolFailureError("Checkpoint recovery is not running for this data root.", effects: .none)
        }
        let recoveryID = turnId.isEmpty ? "session:" + sessionId : turnId
        guard !inFlight().contains(turnId), resuming.insert(recoveryID).inserted else {
            throw ToolFailureError("This turn is already running; its recovery has not been repeated.", effects: .none)
        }
        defer { resuming.remove(recoveryID) }
        do {
            if sessionId.isEmpty {
                let root = dataRoot.appendingPathComponent("chat/session_state")
                for session in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    where try session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    && session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true {
                    try Task.checkCancellation()
                    try await reconcile(sessionId: session.lastPathComponent, turnId: "")
                }
                try Task.checkCancellation()
                await RepairOwed.settle(dataRoot, operation: AbandonedTurnReconciler.operation(sessionId: sessionId, turnId: turnId),
                    evidence: .init(source: "chat/session_state", id: "reconciled")).value
                return
            }
            if turnId.isEmpty {
                // Each checkpoint reconciles on its own; one that fails owes its own repair and never holds back its siblings.
                var failed: Error?
                for turn in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: sessionId) {
                    try Task.checkCancellation()
                    do { try await reconcile(sessionId: sessionId, turnId: turn) } catch { failed = error }
                }
                if let failed { throw failed }
                try Task.checkCancellation()
                await RepairOwed.settle(dataRoot, operation: AbandonedTurnReconciler.operation(sessionId: sessionId, turnId: turnId),
                    evidence: .init(source: AbandonedTurnReconciler.owner(sessionId: sessionId, turnId: turnId), id: sessionId)).value
                return
            }
            guard let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try await resume(checkpoint)
            try Task.checkCancellation()
            try await traceBus.flush(turnId: turnId)
            try Task.checkCancellation()
            try await confirmed(checkpoint, dataRoot: dataRoot)
            await RepairOwed.settle(dataRoot, operation: "turn.reconcile:" + turnId,
                evidence: .init(source: "experiences/experiences.sqlite", id: turnId)).value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AbandonedTurnReconciler.owe(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId,
                detail: error.localizedDescription)
            throw ToolFailureError("Turn \(turnId) still needs recovery: \(error.localizedDescription)", effects: .unknown,
                owner: AbandonedTurnReconciler.owner(sessionId: sessionId, turnId: turnId),
                nextCall: AbandonedTurnReconciler.repairCall(sessionId: sessionId, turnId: turnId))
        }
    }

    private func confirmed(_ checkpoint: TurnCheckpoint, dataRoot: URL) async throws {
        guard try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: checkpoint.sessionId, turnId: checkpoint.turnId) == nil else {
            throw ToolFailureError("The resumed turn still has unfinished work or an unaccepted reply.", effects: .unknown)
        }
        let read = try await TurnTracePersistLane(dataRootOverride: dataRoot).events(.init(subjects: [checkpoint.turnId]))
        // Missing or unreadable evidence never confirms recovery.
        guard read.isClean else { throw CocoaError(.fileReadCorruptFile) }
        if ["completed", "waiting"].contains(where: { TurnTraceReplayReader.containsTerminal(forTurn: checkpoint.turnId, in: read.events,
            status: $0) }) { return }
        throw ToolFailureError("The resumed turn has no confirmed completed or waiting terminal; recovery remains owed.", effects: .unknown)
    }

    private func sweepAtLaunch() {
        guard let generation, sweepTask == nil else { return }
        let active = inFlight().union(resuming)
        // Never behind telemetry: only an earlier process's turns are candidates, and a resuming one is excluded until it confirms.
        sweepTask = Task(priority: .utility) { [self] in
            defer {
                sweepTask = nil
                if self.generation != generation { sweepAtLaunch() }
            }
            let outcome = await AbandonedTurnReconciler(dataRoot: dataRoot).sweep(inFlightTurnIds: active)
            guard self.generation == generation, !Task.isCancelled else { return }
            // One job per conversation, in the order its sends were accepted: a session runs one turn at a time, so its
            // second saved send waits for the first instead of colliding with it. Conversations still recover side by side.
            let bySession = Dictionary(grouping: outcome.resumable.filter { !inFlight().contains($0.turnId) }, by: \.sessionId)
            for (_, checkpoints) in bySession {
                let id = UUID()
                resumeJobs[id] = Task { [self] in
                    defer { resumeJobs[id] = nil }
                    for checkpoint in checkpoints.sorted(by: { $0.acceptedAt < $1.acceptedAt }) {
                        guard self.generation == generation, !Task.isCancelled else { return }
                        do {
                            try await reconcile(sessionId: checkpoint.sessionId, turnId: checkpoint.turnId)
                        } catch {
                            guard self.generation == generation, !Task.isCancelled else { return }
                            OrganPulse.record("abandoned_turns", .failed,
                                note: "Turn \(checkpoint.turnId) still owes recovery: \(error.localizedDescription)")
                        }
                    }
                }
            }
            if let failure = outcome.failure {
                OrganPulse.record("abandoned_turns", .failed, note: failure)
            } else {
                OrganPulse.record("abandoned_turns", found: outcome.reconciled.count,
                                  note: "\(outcome.resumable.count) resuming, \(outcome.reconciled.count) without a checkpoint owe recovery")
            }
            guard !outcome.reconciled.isEmpty else { return }
            FileHandle.standardError.write(
                Data(
                    ("AbandonedTurnReconciler: wrote \(outcome.reconciled.count) unfinished"
                        + " repair obligation(s) across \(outcome.acceptedScanned) accepted turn(s)\n").utf8
                )
            )
        }
    }

}
