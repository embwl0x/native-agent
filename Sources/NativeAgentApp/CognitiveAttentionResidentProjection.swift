import CognitiveSubstrate
import Foundation

/// Lock-backed immutable handoff from the canonical cognition/organism owners
/// to turn preparation. Writers publish after state transitions; readers never
/// enter an actor, touch disk, schedule work, or call a model.
final class CognitiveAttentionResidentProjection: @unchecked Sendable {
    private struct PursuitIntent: Sendable, Equatable {
        let activeTask: String
        let goal: String
    }

    private struct State: Sendable {
        var substrate: CognitiveAttentionSignals?
        var substratePublishedAt: Date?
        var predictedToolGroups: Set<String> = []
        var pursuit: PursuitIntent?
    }

    /// Mirrors CognitiveSubstrate's pending-completion horizon. The resident
    /// handoff may outlive the actor mutation that published it, so the open
    /// question expires defensively even when no later event arrives.
    private static let unresolvedQuestionMaximumAge: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var state = State()

    func replaceSubstrate(_ signals: CognitiveAttentionSignals?, publishedAt: Date) {
        lock.withLock {
            state.substrate = signals
            state.substratePublishedAt = publishedAt
        }
    }

    func replacePredictedToolGroups(_ groups: Set<String>) {
        lock.withLock { state.predictedToolGroups = Set(groups.sorted().prefix(8)) }
    }

    func replacePursuit(activeTask: String?, goal: String?) {
        let active = activeTask?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            guard let active, !active.isEmpty, let target, !target.isEmpty else {
                state.pursuit = nil
                return
            }
            state.pursuit = PursuitIntent(
                activeTask: String(active.prefix(200)),
                goal: String(target.prefix(200))
            )
        }
    }

    func read(at date: Date) -> CognitiveAttentionSignals? {
        let snapshot = lock.withLock { state }
        let base = snapshot.substrate
        let unresolvedQuestion: String? = {
            guard let question = base?.unresolvedQuestion else { return nil }
            guard let publishedAt = snapshot.substratePublishedAt else { return nil }
            let age = date.timeIntervalSince(publishedAt)
            return age >= 0 && age <= Self.unresolvedQuestionMaximumAge ? question : nil
        }()
        let signals = CognitiveAttentionSignals(
            terms: base?.terms ?? [:],
            unresolvedQuestion: unresolvedQuestion,
            activeTask: snapshot.pursuit?.activeTask ?? base?.activeTask,
            goal: snapshot.pursuit?.goal ?? base?.goal,
            predictedToolGroups: snapshot.predictedToolGroups,
            memoryActivation: base?.memoryActivation ?? [:],
            workingMemoryRecordIDs: base?.workingMemoryRecordIDs ?? []
        )
        return signals.isEmpty ? nil : signals
    }
}
