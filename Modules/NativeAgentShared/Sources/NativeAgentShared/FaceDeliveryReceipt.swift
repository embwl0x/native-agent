import Foundation
// Blueprint: | `FaceDeliveryReceipt.swift` | Event-settled pipeline delivery with cancellation and owner-close settlement |

/// An owner completes this receipt after its earlier admitted changes have left its queue.
public actor FaceDeliveryReceipt {
    private enum Closed: LocalizedError {
        case ownerClosed
        var errorDescription: String? { "The face publication owner closed before delivery." }
    }
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    public init() {}

    public func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { waiters.append(continuation) }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.finish(.failure(CancellationError())) }
        }
    }

    public func complete() { finish(.success(())) }
    public func close() { finish(.failure(Closed.ownerClosed)) }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let held = waiters
        waiters.removeAll()
        for waiter in held { waiter.resume(with: result) }
    }
}
