import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AbandonedTurnReconciliationHook.swift` | `AbandonedTurnReconciliationHook` enum; `arm`, `disarm`; retains sweep/resume jobs through exit and removes its observer at engine termination; excludes active turns and claims checkpoint resumes; terminal settlement awaits the installed anchor-intent adapter |

/// Resume unfinished turns at launch; reconcile legacy turns at settled boundaries.
@MainActor
public enum AbandonedTurnReconciliationHook {
    /// Settled boundaries reuse the launch sweep without repeatedly reading disk.
    private static let minimumIntervalSeconds: TimeInterval = 300

    private static var observer: NSObjectProtocol?
    private static var lastSweepAt: Date?
    private static var generation: UUID?
    private static var sweepTask: Task<Void, Never>?
    private static var resumeJobs: [UUID: Task<Void, Never>] = [:]
    private static var resuming: Set<String> = []
    private static var inFlight: @Sendable () -> Set<String> = { [] }
    private static var resume: (@Sendable (TurnCheckpoint) async throws -> Void)?
    private static var retainReplyMirror: (@Sendable (URL, String, String) async throws -> Void)?

    public static func installReplyMirror(_ retain: @escaping @Sendable (URL, String, String) async throws -> Void) {
        retainReplyMirror = retain
    }

    public static func retainMirror(dataRoot: URL, sessionId: String, runId: String) async throws {
        try await retainReplyMirror?(dataRoot, sessionId, runId)
    }

    public static func arm(completedTurnNotification: Notification.Name,
                           inFlight: @escaping @Sendable () -> Set<String>,
                           resume: @escaping @Sendable (TurnCheckpoint) async throws -> Void) {
        guard observer == nil else { return }
        self.inFlight = inFlight
        self.resume = resume
        generation = UUID()
        // Pin the process epoch at launch: only turns accepted BEFORE it are
        // ever reconcilable.
        _ = AbandonedTurnReconciler.processEpoch
        observer = NotificationCenter.default.addObserver(
            forName: completedTurnNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sweepIfDue() }
        }
        sweepIfDue()
    }

    public static func disarm() {
        generation = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        lastSweepAt = nil
        sweepTask?.cancel()
        // A queued job checks the generation before admission. A resume that
        // already began is accepted turn work and keeps its owner until exit.
        resume = nil
        inFlight = { [] }
    }

    public static func reconcile(dataRoot: URL, sessionId: String, turnId: String) async throws {
        try Task.checkCancellation()
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
                    try await reconcile(dataRoot: dataRoot, sessionId: session.lastPathComponent, turnId: "")
                }
                try Task.checkCancellation()
                await RepairOwed.settle(dataRoot, operation: AbandonedTurnReconciler.operation(sessionId: sessionId, turnId: turnId),
                    evidence: .init(source: "chat/session_state", id: "reconciled")).value
                return
            }
            if turnId.isEmpty {
                // Each checkpoint reconciles on its own; one that fails owes its own
                // repair and never holds back its siblings.
                var failed: Error?
                for turn in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: sessionId) {
                    try Task.checkCancellation()
                    do { try await reconcile(dataRoot: dataRoot, sessionId: sessionId, turnId: turn) } catch { failed = error }
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
            guard let resume else { throw CocoaError(.featureUnsupported) }
            try await resume(checkpoint)
            try Task.checkCancellation()
            await TurnTraceBus.shared.drainForProcessExit()
            try Task.checkCancellation()
            try confirmed(checkpoint, dataRoot: dataRoot)
            await RepairOwed.settle(dataRoot, operation: "turn.reconcile:" + turnId,
                evidence: .init(source: "turn_traces", id: turnId)).value
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

    private static func confirmed(_ checkpoint: TurnCheckpoint, dataRoot: URL) throws {
        guard try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: checkpoint.sessionId, turnId: checkpoint.turnId) == nil else {
            throw ToolFailureError("The resumed turn still has unfinished work or an unaccepted reply.", effects: .unknown)
        }
        let days = Set([checkpoint.acceptedAt, checkpoint.updatedAt, Date()].flatMap { day in
            [day] + [-1, 1].compactMap { AbandonedTurnReconciler.dayCalendar.date(byAdding: .day, value: $0, to: day) }
        }.map { dataRoot.appendingPathComponent("turn_traces/" + TurnTracePersistLane.dayString(from: $0) + ".jsonl") })
        for day in days where FileManager.default.fileExists(atPath: day.path) {
            let read = TurnTraceReplayReader.parse(try Data(contentsOf: day))
            // Recovery still needs a complete ledger, unlike a live owner's
            // terminal append, which already knows this turn's outcome.
            guard read.report.isClean else { throw CocoaError(.fileReadCorruptFile) }
            if ["completed", "waiting"].contains(where: { TurnTraceReplayReader.containsTerminal(forTurn: checkpoint.turnId, in: read.events, status: $0) }) { return }
        }
        throw ToolFailureError("The resumed turn has no confirmed completed or waiting terminal; recovery remains owed.", effects: .unknown)
    }

    private static func sweepIfDue() {
        guard let generation, sweepTask == nil else { return }
        let now = Date()
        if let lastSweepAt, now.timeIntervalSince(lastSweepAt) < minimumIntervalSeconds {
            return
        }
        lastSweepAt = now
        let active = inFlight().union(resuming)
        // Never behind telemetry: only an earlier process's turns are
        // candidates, and a resuming one is excluded until it confirms.
        sweepTask = Task(priority: .utility) {
            defer {
                sweepTask = nil
                if self.generation != generation { sweepIfDue() }
            }
            let outcome = await AbandonedTurnReconciler().sweep(inFlightTurnIds: active)
            guard self.generation == generation, !Task.isCancelled else { return }
            for checkpoint in outcome.resumable where !inFlight().contains(checkpoint.turnId) {
                let id = UUID()
                resumeJobs[id] = Task {
                    defer { resumeJobs[id] = nil }
                    guard self.generation == generation, !Task.isCancelled else { return }
                    do {
                        try await reconcile(dataRoot: PersistenceCore.defaultDataRoot(),
                            sessionId: checkpoint.sessionId, turnId: checkpoint.turnId)
                    } catch {
                        guard self.generation == generation, !Task.isCancelled else { return }
                        OrganPulse.record("abandoned_turns", .skipped,
                            note: "Turn \(checkpoint.turnId) still owes recovery: \(error.localizedDescription)")
                    }
                }
            }
            if let failure = outcome.failure {
                OrganPulse.record("abandoned_turns", .skipped, note: failure)
            } else {
                OrganPulse.record("abandoned_turns", found: outcome.reconciled.count,
                                  note: "\(outcome.resumable.count) resuming, \(outcome.reconciled.count) legacy turns owe recovery")
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
