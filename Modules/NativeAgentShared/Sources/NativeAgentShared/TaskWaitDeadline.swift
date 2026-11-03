import Foundation

// Blueprint: | `TaskWaitDeadline.swift` | `TaskWaitDeadline`: one inherited absolute tool-call ceiling; shared parking cancellation and bounded response, with body-owned cleanup outside the deadline |

/// Set once at the call's entry. Nested calls and `Task {}` keep the same
/// instant; detached settlement deliberately has no work deadline.
public enum TaskWaitDeadline {
    @TaskLocal public static var current: ContinuousClock.Instant?

    public struct Exceeded: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The tool call exceeded its deadline." }
        public init() {}
    }

    public static var expired: Bool { current.map { ContinuousClock.now >= $0 } ?? false }

    /// A durable receipt's wall-clock projection, never a second running timer.
    public static var wallDate: Date? {
        guard let current else { return nil }
        let left = ContinuousClock.now.duration(to: current).components
        return Date().addingTimeInterval(Double(left.seconds) + Double(left.attoseconds) * 1e-18)
    }

    public static var cancellationError: any Error {
        expired ? Exceeded() : CancellationError()
    }

    /// Each parker retires its timer when it wakes. Expiry uses that parker's
    /// cancellation path, never resolves a shared wait on behalf of siblings.
    static func arm(_ cancel: @escaping @Sendable () -> Void) -> Task<Void, Never>? {
        guard let deadline = current else { return nil }
        return Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            cancel()
        }
    }

    /// The response cannot join a producer that may never answer. Its task
    /// keeps ownership of its resources/settlement until actual exit.
    public static func withDeadline<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if current != nil { return try await work() }
        try Task.checkCancellation()
        return try await $current.withValue(ContinuousClock.now.advanced(by: .seconds(seconds))) {
            let result = ContinuationOnce<Result<T, Error>>()
            let body = Task {
                do {
                    try Task.checkCancellation()
                    let value = try await work()
                    if expired { throw Exceeded() }
                    result.resume(.success(value))
                } catch { result.resume(.failure(expired ? Exceeded() : error)) }
            }
            return try await result.wait(cancellingWith: .failure(cancellationError),
                onCancel: { body.cancel() }).get()
        }
    }
}
