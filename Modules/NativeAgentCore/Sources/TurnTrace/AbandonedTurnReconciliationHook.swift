import Foundation
import PersistenceCore

/// Bounded terminal reconciliation: once at launch, and after a completed turn
/// (throttled), never during one.
///
/// A3 / audit (2026-09-11): 33 accepted turns since Aug 29 have no terminal row
/// of any kind — a process that died mid-turn wrote neither an outcome nor an
/// error, so the turn reads as accepted forever. The sweep writes the one row
/// the evidence supports and replays nothing.
///
/// GPT-5.6 round review (2026-09-11): the trigger used to be the per-provider
/// usage receipt, which fires MID TOOL LOOP. A long productive turn whose last
/// provider call crossed the 6h ceiling could therefore stamp itself abandoned
/// before writing its real terminal. The trigger is now the completed-turn
/// boundary, and the sweep waits for trace persistence to settle first so the
/// terminal it is about to look for is actually on disk.
@MainActor
public enum AbandonedTurnReconciliationHook {
    /// The sweep reads at most three day files and writes at most 25 rows, so
    /// the throttle is about not repeating pointless work, not about cost.
    private static let minimumIntervalSeconds: TimeInterval = 300

    private static var observer: NSObjectProtocol?
    private static var lastSweepAt: Date?
    private static var running = false

    public static func arm(completedTurnNotification: Notification.Name) {
        guard observer == nil else { return }
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
        Task.detached(priority: .utility) {
            // Let the finished turn's own terminal row reach disk before the
            // sweep reads the day files looking for it.
            await TurnTraceBus.shared.drainForProcessExit()
            let outcome = await AbandonedTurnReconciler().sweep()
            await MainActor.run { running = false }
            guard !outcome.reconciled.isEmpty else { return }
            await noteInterruptedTurns(outcome.interruptedSessions)
            FileHandle.standardError.write(
                Data(
                    ("AbandonedTurnReconciler: wrote \(outcome.reconciled.count) abandoned"
                        + " terminal row(s) across \(outcome.acceptedScanned) accepted turn(s)\n").utf8
                )
            )
        }
    }

    /// Doors that don't show Mac chat's own interrupted card. The note costs
    /// no model call: the person says "continue" if they want the rest.
    private static let notedSurfaces: Set<String> = ["telegram", "agent-bridge", "slack", "ios", "phone", "siri"]
    static let interruptedNote = "I got cut off when the app restarted, so that reply didn't finish. Say continue and I'll pick it up."

    private static func noteInterruptedTurns(_ sessions: [(sessionId: String, surface: String)]) async {
        let persistence = SwiftNativePersistenceCore()
        let root = PersistenceCore.defaultDataRoot().appendingPathComponent("chat/messages")
        var seen = Set<String>()
        // Agent-contact sessions (agent-…) can report surface "chat"; Mac chat itself shows its own card.
        for session in sessions where notedSurfaces.contains(session.surface) || session.sessionId.hasPrefix("agent-") {
            let id = session.sessionId
            guard seen.insert(id).inserted, !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { continue }
            let path = root.appendingPathComponent("\(id).jsonl")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let row: JSONValue = .object([
                "id": .string(UUID().uuidString.lowercased()),
                "sessionId": .string(id),
                "role": .string("assistant"),
                "content": .string(interruptedNote),
                "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                "source": .string(session.surface),
                "metadata": .object(["kind": .string("interrupted_turn_note")]),
            ])
            try? await persistence.withFileLock(path) { [persistence] in
                try await persistence.appendJSONL(row, to: path)
            }
        }
    }
}
