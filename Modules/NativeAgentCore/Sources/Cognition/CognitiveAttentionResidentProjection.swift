import CognitiveSubstrate
import Foundation

// Blueprint: | `CognitiveAttentionResidentProjection.swift` | `ResidentAttention`: lock-backed immutable cognition/organism handoff for turn reads without actor, disk or provider work |

/// Lock-backed immutable handoff from the canonical cognition/organism owners
/// to turn preparation. Writers publish after state transitions; readers never
/// enter an actor, touch disk, schedule work, or call a model.
final class ResidentAttention: @unchecked Sendable {
    private struct PursuitIntent: Sendable, Equatable {
        let activeTask: String
        let goal: String
    }

    private struct State: Sendable {
        var substrate: CognitiveAttentionSignals?
        var predictedToolGroups: Set<String> = []
        var pursuit: PursuitIntent?
    }

    private let lock = NSLock()
    private var state = State()

    func replaceSubstrate(_ signals: CognitiveAttentionSignals?) {
        lock.withLock { state.substrate = signals }
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
            guard let window = base?.completionWindow,
                  date >= window.openedAt, date <= window.expiresAt else { return nil }
            return base?.unresolvedQuestion
        }()
        let signals = CognitiveAttentionSignals(
            terms: base?.terms ?? [:],
            unresolvedQuestion: unresolvedQuestion,
            completionWindow: base?.completionWindow,
            activeTask: snapshot.pursuit?.activeTask ?? base?.activeTask,
            goal: snapshot.pursuit?.goal ?? base?.goal,
            residentWorkIntent: snapshot.pursuit != nil,
            predictedToolGroups: snapshot.predictedToolGroups,
            memoryActivation: base?.memoryActivation ?? [:],
            suppressedMemory: base?.suppressedMemory ?? [:]
        )
        return signals.isEmpty ? nil : signals
    }
}
