import Synchronization
import MindCore
import Foundation

// Blueprint: | `CognitiveAttentionResidentProjection.swift` | `ResidentAttention`. |

/// Publish immutable state after owner transitions so turn reads need no actor hop, disk, scheduling or model call.
final class ResidentAttention: Sendable {
    private struct PursuitIntent: Sendable, Equatable {
        let activeTask: String
        let goal: String
    }

    private struct State: Sendable {
        var substrate: CognitiveAttentionSignals?
        var predictedToolGroups: Set<String> = []
        var pursuit: PursuitIntent?
    }

    private let state = Mutex(State())

    func replaceSubstrate(_ signals: CognitiveAttentionSignals?) {
        state.withLock { state in state.substrate = signals }
    }

    func replacePredictedToolGroups(_ groups: Set<String>) {
        state.withLock { state in state.predictedToolGroups = Set(groups.sorted().prefix(8)) }
    }

    func replacePursuit(activeTask: String?, goal: String?) {
        let active = activeTask?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.withLock { state in
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
        let snapshot = state.withLock { state in state }
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
