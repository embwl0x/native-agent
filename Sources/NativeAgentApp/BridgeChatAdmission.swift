import Foundation
import ChatOrchestration

/// Bridge callbacks and ordinary messages share one Workspace per chat. Queue
/// their model turns, while durable enqueue and completion deduplication keep
/// their existing owners and HTTP response semantics.
actor BridgeChatAdmission {
    static let shared = BridgeChatAdmission()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var active: [String: UUID] = [:]
    private var waiting: [String: [Waiter]] = [:]

    struct Full: LocalizedError {
        var errorDescription: String? { "This chat has too many waiting bridge turns. No new turn was started." }
    }

    func run(sessionID: String?, operation: @Sendable () async throws -> ChatOrchestration.ChatResponse) async throws -> ChatOrchestration.ChatResponse {
        guard let sessionID else { return try await operation() }
        let id = UUID()
        try await acquire(sessionID, id: id)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(sessionID, id: id)
            return result
        } catch {
            release(sessionID, id: id)
            throw error
        }
    }

    private func acquire(_ key: String, id: UUID) async throws {
        try Task.checkCancellation()
        if active[key] == nil {
            active[key] = id
            return
        }
        guard (waiting[key]?.count ?? 0) < 8,
              waiting.values.reduce(0, { $0 + $1.count }) < 32 else { throw Full() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[key, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(key, id: id) }
        }
    }

    private func cancel(_ key: String, id: UUID) {
        guard let index = waiting[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiting[key]?.remove(at: index) else { return }
        if waiting[key]?.isEmpty == true { waiting.removeValue(forKey: key) }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: String, id: UUID) {
        guard active[key] == id else { return }
        active.removeValue(forKey: key)
        guard var queue = waiting.removeValue(forKey: key), !queue.isEmpty else { return }
        let next = queue.removeFirst()
        if !queue.isEmpty { waiting[key] = queue }
        active[key] = next.id
        next.continuation.resume()
    }
}
