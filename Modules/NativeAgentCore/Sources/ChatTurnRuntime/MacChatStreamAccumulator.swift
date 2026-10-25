import Foundation
// Blueprint: | `MacChatStreamAccumulator.swift` | `ChatStreamAccumulator` actor; `consume`; deltas arm one publication deadline, rearmed only for owed text; settlement/termination cancel and join publication |

/// Stream-local accumulator for one chat turn's deltas.
///
/// Token intake, append and length accounting stay here; only changed display
/// snapshots cross to MainActor. Publication retires when no text has changed.
///
/// `takeIfChanged` only hands back growing text. A settled-state update joins
/// the publisher and flushes the full snapshot before changing presentation.
public actor ChatStreamAccumulator {
    public init() {}
    public static let publishInterval: TimeInterval = 0.07
    private var accumulated = ""
    private var accumulatedUTF16 = 0
    private var takenUTF16 = 0
    private var ticker: Task<Void, Error>?
    private var nextPublicationAt: ContinuousClock.Instant?

    /// Consume tokens here, not in the MainActor caller. Only changed display
    /// snapshots cross back; a provider pause never leaves a trailing chunk
    /// waiting for the next token. Join the publisher before completion/error
    /// so an already-enqueued snapshot cannot overwrite the final reply.
    public func consume(
        _ stream: AsyncThrowingStream<MacChatStreamUpdate, Error>,
        interval: TimeInterval,
        publish: @escaping @MainActor @Sendable (String, Int, Bool?) throws -> Void
    ) async throws -> String {
        defer { ticker = nil; nextPublicationAt = nil }
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
                guard case .text(let delta) = update else { continue }
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

    /// The latest text, but only when it has grown since the last take.
    private func takeIfChanged() -> String? {
        guard accumulatedUTF16 > takenUTF16 else { return nil }
        takenUTF16 = accumulatedUTF16
        return accumulated
    }
}

public enum MacChatStreamUpdate: Sendable {
    case text(String)
    case replyTextSettled(Bool)
}
