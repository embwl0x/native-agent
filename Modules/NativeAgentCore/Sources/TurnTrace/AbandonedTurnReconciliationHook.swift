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
                    guard resuming.insert(checkpoint.turnId).inserted, let resume else { continue }
                    Task {
                        defer { resuming.remove(checkpoint.turnId) }
                        do { try await resume(checkpoint) }
                        catch { OrganPulse.record("abandoned_turns", .skipped,
                            note: "Turn \(checkpoint.turnId) could not resume: \(error.localizedDescription)") }
                    }
                }
            }
            if let failure = outcome.failure {
                OrganPulse.record("abandoned_turns", .skipped, note: failure)
            } else {
                OrganPulse.record("abandoned_turns", found: outcome.reconciled.count,
                                  note: "\(outcome.resumable.count) resuming, \(outcome.reconciled.count) legacy turns closed")
            }
            guard !outcome.reconciled.isEmpty else { return }
            FileHandle.standardError.write(
                Data(
                    ("AbandonedTurnReconciler: wrote \(outcome.reconciled.count) abandoned"
                        + " terminal row(s) across \(outcome.acceptedScanned) accepted turn(s)\n").utf8
                )
            )
        }
    }

}
