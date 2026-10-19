import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore

/// Resume unfinished turns at launch; reconcile legacy turns at settled boundaries.
@MainActor
public enum AbandonedTurnReconciliationHook {
    /// Settled boundaries reuse the launch sweep without repeatedly reading disk.
    private static let minimumIntervalSeconds: TimeInterval = 300

    private static var observer: NSObjectProtocol?
    private static var lastSweepAt: Date?
    private static var running = false
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

    public static func reconcile(dataRoot: URL, sessionId: String, turnId: String) async throws {
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
                    try await reconcile(dataRoot: dataRoot, sessionId: session.lastPathComponent, turnId: "")
                }
                await RepairOwed.settle(dataRoot, operation: AbandonedTurnReconciler.operation(sessionId: sessionId, turnId: turnId),
                    evidence: .init(source: "chat/session_state", id: "reconciled")).value
                return
            }
            if turnId.isEmpty {
                let checkpoints = try TurnCheckpoint.forSession(dataRoot: dataRoot, sessionId: sessionId)
                for checkpoint in checkpoints {
                    try await reconcile(dataRoot: dataRoot, sessionId: sessionId, turnId: checkpoint.turnId)
                }
                await RepairOwed.settle(dataRoot, operation: AbandonedTurnReconciler.operation(sessionId: sessionId, turnId: turnId),
                    evidence: .init(source: AbandonedTurnReconciler.owner(sessionId: sessionId, turnId: turnId), id: sessionId)).value
                return
            }
            guard let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard let resume else { throw CocoaError(.featureUnsupported) }
            try await resume(checkpoint)
            await TurnTraceBus.shared.drainForProcessExit()
            try confirmed(checkpoint, dataRoot: dataRoot)
            await RepairOwed.settle(dataRoot, operation: "turn.reconcile:" + turnId,
                evidence: .init(source: "turn_traces", id: turnId)).value
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
            let text = try String(contentsOf: day, encoding: .utf8)
            if ["completed", "waiting"].contains(where: { AbandonedTurnReconciler.containsTerminal(forTurn: checkpoint.turnId, in: text, status: $0) }) { return }
        }
        throw ToolFailureError("The resumed turn has no confirmed completed or waiting terminal; recovery remains owed.", effects: .unknown)
    }

    private static func sweepIfDue() {
        guard !running else { return }
        let now = Date()
        if let lastSweepAt, now.timeIntervalSince(lastSweepAt) < minimumIntervalSeconds {
            return
        }
        lastSweepAt = now
        running = true
        let active = inFlight().union(resuming)
        Task.detached(priority: .utility) {
            // Let the finished turn's own terminal row reach disk before the
            // sweep reads the day files looking for it.
            await TurnTraceBus.shared.drainForProcessExit()
            let outcome = await AbandonedTurnReconciler().sweep(inFlightTurnIds: active)
            await MainActor.run {
                running = false
                for checkpoint in outcome.resumable where !inFlight().contains(checkpoint.turnId) {
                    Task {
                        do {
                            try await reconcile(dataRoot: PersistenceCore.defaultDataRoot(),
                                sessionId: checkpoint.sessionId, turnId: checkpoint.turnId)
                        } catch {
                            OrganPulse.record("abandoned_turns", .skipped,
                                note: "Turn \(checkpoint.turnId) still owes recovery: \(error.localizedDescription)")
                        }
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
