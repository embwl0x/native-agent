import Foundation
import NativeAgentCore
import ToolRegistry
import NativeAgentShared
// Blueprint: | `MacChatStreamAccumulator.swift` | `ChatStreamAccumulator`; `TurnStreamEvent`; Coalesced deltas; joined final publication |

/// Accumulate deltas off MainActor and publish changed snapshots only.
/// Join and flush before settlement so an older queued frame cannot overwrite the final reply.
public actor ChatStreamAccumulator {
    public init() {}
    public static let publishInterval: TimeInterval = 0.07
    private var accumulated = ""
    private var accumulatedUTF16 = 0
    private var takenUTF16 = 0
    private var ticker: Task<Void, Error>?
    private var nextPublicationAt: ContinuousClock.Instant?

    /// Publish changed text off the token path so provider pauses leave no stranded chunk.
    /// Join publication before completion or error so stale frames cannot overwrite settlement.
    public func consume(
        _ stream: AsyncThrowingStream<TurnStreamEvent, Error>,
        interval: TimeInterval,
        activityIdentity: MacChatTurnIdentity,
        onTurnActivity: @escaping @Sendable (MacChatTurnActivity) async -> Void,
        onMovement: @escaping @Sendable (TurnCallWriting?) async -> Void,
        publish: @escaping @MainActor @Sendable (String, Int, Bool?) throws -> Void
    ) async throws -> String {
        defer { ticker = nil; nextPublicationAt = nil }
        let shown = ShownToolNames()
        do {
            for try await update in stream {
                try Task.checkCancellation()
                // Join any in-flight publication, then flush the last prose
                // and its display state together, in provider event order.
                if case .replyTextSettled(let settled) = update {
                    ticker?.cancel()
                    if case .failure(let error) = await ticker?.result,
                       !(error is CancellationError) { throw error }
                    ticker = nil
                    nextPublicationAt = nil
                    takenUTF16 = accumulatedUTF16
                    try await publish(accumulated, accumulatedUTF16, settled)
                    continue
                }
                let delta: String
                switch update {
                case .delta(let text): delta = text
                case .toolUse, .toolResult, .notice:
                    if let activity = MacChatTurnActivityBoundary.activity(
                        from: update, identity: activityIdentity, shown: shown, at: Date()
                    ) { await onTurnActivity(activity) }
                    continue
                case .writing(let writing):
                    await onMovement(writing)
                    continue
                case .error(let message):
                    throw NSError(domain: "NativeAgentStream", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: message])
                case .final, .replyTextSettled: continue
                }
                accumulated += delta
                accumulatedUTF16 += delta.utf16.count
                guard ticker == nil, accumulatedUTF16 > takenUTF16 else { continue }
                if let deadline = nextPublicationAt, deadline > .now {
                    armPublication(at: deadline, interval: interval, publish: publish)
                    continue
                }
                guard let snapshot = takeIfChanged() else { continue }
                try await publish(snapshot, takenUTF16, nil)
                nextPublicationAt = .now + .seconds(interval)
                if accumulatedUTF16 > takenUTF16, let deadline = nextPublicationAt {
                    armPublication(at: deadline, interval: interval, publish: publish)
                }
            }
        } catch {
            ticker?.cancel()
            _ = await ticker?.result
            throw error
        }
        ticker?.cancel()
        if case .failure(let error) = await ticker?.result, !(error is CancellationError) {
            throw error
        }
        try Task.checkCancellation()
        return accumulated
    }

    /// A delta owes one deadline. Idle text never arms a check for more text;
    /// deltas received during publication rearm only after that frame settles.
    private func armPublication(
        at deadline: ContinuousClock.Instant,
        interval: TimeInterval,
        publish: @escaping @MainActor @Sendable (String, Int, Bool?) throws -> Void
    ) {
        ticker = Task {
            try await Task.sleep(until: deadline, clock: .continuous)
            try Task.checkCancellation()
            if let snapshot = self.takeIfChanged() {
                try await publish(snapshot, self.takenUTF16, nil)
            }
            try Task.checkCancellation()
            self.nextPublicationAt = .now + .seconds(interval)
            self.ticker = nil
            if self.accumulatedUTF16 > self.takenUTF16, let next = self.nextPublicationAt {
                self.armPublication(at: next, interval: interval, publish: publish)
            }
        }
    }

    private func takeIfChanged() -> String? {
        guard accumulatedUTF16 > takenUTF16 else { return nil }
        takenUTF16 = accumulatedUTF16
        return accumulated
    }
}
