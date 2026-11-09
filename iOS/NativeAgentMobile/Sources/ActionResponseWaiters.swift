import Foundation
import NativeAgentShared

/// MainActor owns the rendezvous; record the durable response outcome before waking its ScopedWaiter.
@MainActor
final class ActionResponseWaiters {
    static let shared = ActionResponseWaiters()

    private var waiters: [String: [UUID: ScopedWaiter]] = [:]
    private var arrived: Set<String> = []
    private var armed: Set<String> = []

    /// Register before reading so an arrival racing the first poll is remembered.
    func arm(_ correlationID: String) {
        if armed.insert(correlationID).inserted { arrived.remove(correlationID) }
    }

    /// Release parked callers when removing their correlation.
    func disarm(_ correlationID: String) {
        iCloudBridge.shared.retireDelivery(for: correlationID)
        armed.remove(correlationID)
        arrived.remove(correlationID)
        for token in Array((waiters[correlationID] ?? [:]).keys) {
            resume(correlationID: correlationID, token: token)
        }
        waiters.removeValue(forKey: correlationID)
    }

    /// Record durable arrivals only for watched correlations so the set stays bounded.
    func signal(_ correlationID: String) {
        guard armed.contains(correlationID) else { return }
        arrived.insert(correlationID)
        for token in Array((waiters[correlationID] ?? [:]).keys) {
            resume(correlationID: correlationID, token: token)
        }
    }

    func consumeArrival(_ correlationID: String) {
        arrived.remove(correlationID)
    }

    func close() {
        for correlationID in Array(armed) { disarm(correlationID) }
    }

    /// Only arrival, owner closure and cancellation release this observation.
    @discardableResult
    func wait(_ correlationID: String) async -> Bool {
        if arrived.contains(correlationID) { return true }
        guard armed.contains(correlationID) else { return false }
        let token = UUID()
        guard !Task.isCancelled else { return false }
        let done = ScopedWaiter()
        waiters[correlationID, default: [:]][token] = done
        await done.park()
        let signalled = arrived.contains(correlationID)
        resume(correlationID: correlationID, token: token)
        return signalled
    }

    private func resume(correlationID: String, token: UUID) {
        guard let done = waiters[correlationID]?.removeValue(forKey: token) else { return }
        if waiters[correlationID]?.isEmpty == true {
            waiters.removeValue(forKey: correlationID)
        }
        done.resume()
    }
}
