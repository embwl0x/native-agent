import Foundation

/// Stream-local accumulator for one chat turn's deltas.
///
/// Token intake, append and length accounting stay here; only changed display
/// snapshots cross to MainActor. Idle publish ticks never wake MainActor.
///
/// `takeIfChanged` only hands back growing text. A settled-state update joins
/// the publisher and flushes the full snapshot before changing presentation.
public actor ChatStreamAccumulator {
    public init() {}
    public static let publishInterval: TimeInterval = 0.07
    private var accumulated = ""
    private var accumulatedUTF16 = 0
    private var takenUTF16 = 0

    /// Consume tokens here, not in the MainActor caller. Only changed display
    /// snapshots cross back; a provider pause never leaves a trailing chunk
    /// waiting for the next token. Join the publisher before completion/error
    /// so an already-enqueued snapshot cannot overwrite the final reply.
    public func consume(
        _ stream: AsyncThrowingStream<MacChatStreamUpdate, Error>,
        interval: TimeInterval,
        publish: @escaping @MainActor @Sendable (String, Int, Bool?) throws -> Void
    ) async throws -> String {
        var ticker: Task<Void, Error>?
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
                    takenUTF16 = accumulatedUTF16
                    try await publish(accumulated, accumulatedUTF16, settled)
                    continue
                }
                guard case .text(let delta) = update else { continue }
                accumulated += delta
                accumulatedUTF16 += delta.utf16.count
                guard ticker == nil, let snapshot = takeIfChanged() else { continue }
                try await publish(snapshot, takenUTF16, nil)
                ticker = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(interval))
                        try Task.checkCancellation()
                        guard let snapshot = self.takeIfChanged() else { continue }
                        try await publish(snapshot, self.takenUTF16, nil)
                    }
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
