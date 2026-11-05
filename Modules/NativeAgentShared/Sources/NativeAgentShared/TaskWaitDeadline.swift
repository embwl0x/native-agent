import Foundation

// Blueprint: | `TaskWaitDeadline.swift` | `OperationWaitBudget`: explicit call ceiling; producer owns settlement after timeout |

/// One operation's wait ceiling, passed to each waiter and child operation.
/// No deadline means no timed wait; settlement receives no work budget unless its owner explicitly supplies one.
public struct OperationWaitBudget: Sendable {
    public let deadline: ContinuousClock.Instant?

    public init(deadline: ContinuousClock.Instant? = nil) { self.deadline = deadline }

    public func capped(seconds: Double) -> Self {
        let ceiling = ContinuousClock.now.advanced(by: .seconds(seconds))
        return Self(deadline: deadline.map { min($0, ceiling) } ?? ceiling)
    }

    public struct Exceeded: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "The tool call exceeded its deadline." }
        public init() {}
    }

    public var expired: Bool { deadline.map { ContinuousClock.now >= $0 } ?? false }

    /// A durable receipt's wall-clock projection, never a second running timer.
    public var wallDate: Date? {
        guard let deadline else { return nil }
        let left = ContinuousClock.now.duration(to: deadline).components
        return Date().addingTimeInterval(Double(left.seconds) + Double(left.attoseconds) * 1e-18)
    }

    public var cancellationError: any Error {
        expired ? Exceeded() : CancellationError()
    }

    /// Each parker retires its timer when it wakes. Expiry uses that parker's cancellation path, never resolves a shared wait on behalf of siblings.
    func arm(_ cancel: @escaping @Sendable () -> Void) -> Task<Void, Never>? {
        guard let deadline else { return nil }
        return Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            cancel()
        }
    }

    /// The response cannot join a producer that may never answer. Its task keeps ownership of its resources/settlement until actual exit.
    public static func withDeadline<T: Sendable>(
        seconds: Double,
        budget: OperationWaitBudget = .init(),
        _ work: @escaping @Sendable (OperationWaitBudget) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let budget = budget.capped(seconds: seconds)
        guard !budget.expired else { throw Exceeded() }
        let result = ContinuationOnce<Result<T, Error>>()
        let body = Task {
            do {
                try Task.checkCancellation()
                let value = try await work(budget)
                if budget.expired { throw Exceeded() }
                result.resume(.success(value))
            } catch { result.resume(.failure(budget.expired ? Exceeded() : error)) }
        }
        return try await result.wait(budget: budget, cancellingWith: .failure(budget.cancellationError),
            onCancel: { body.cancel() }).get()
    }
}
