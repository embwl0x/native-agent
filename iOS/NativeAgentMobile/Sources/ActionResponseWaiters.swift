import Foundation
import NativeAgentShared

/// MainActor owns the rendezvous; record the durable response outcome before waking its ScopedWaiter.
@MainActor
final class ActionResponseWaiters {
    static let shared = ActionResponseWaiters()

    /// Bound transport backstops when no push arrives.
    static let backstopInterval: TimeInterval = 5

    private var waiters: [String: [UUID: ScopedWaiter]] = [:]
    private var results: [UUID: Bool] = [:]
    private var arrived: Set<String> = []
    private var armed: Set<String> = []
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    func isWaiting(_ correlationID: String) -> Bool { armed.contains(correlationID) }

    /// Register before reading so an arrival racing the first poll is remembered.
    func arm(_ correlationID: String) {
        armed.insert(correlationID)
        arrived.remove(correlationID)
    }

    /// Release parked callers when removing their correlation.
    func disarm(_ correlationID: String) {
        iCloudBridge.shared.stopDeliveryNudges(for: correlationID)
        armed.remove(correlationID)
        arrived.remove(correlationID)
        for token in Array((waiters[correlationID] ?? [:]).keys) {
            resume(correlationID: correlationID, token: token, signalled: false)
        }
        waiters.removeValue(forKey: correlationID)
    }

    /// Record durable arrivals only for watched correlations so the set stays bounded.
    func signal(_ correlationID: String) {
        guard armed.contains(correlationID) else { return }
        arrived.insert(correlationID)
        for token in Array((waiters[correlationID] ?? [:]).keys) {
            resume(correlationID: correlationID, token: token, signalled: true)
        }
    }

    func hasArrived(_ correlationID: String) -> Bool {
        arrived.contains(correlationID)
    }

    /// A signalled arrival lets the caller skip a transport drain; timeout still bounds parking.
    @discardableResult
    func wait(_ correlationID: String, timeout: TimeInterval) async -> Bool {
        if arrived.contains(correlationID) { return true }
        guard timeout.isFinite, timeout >= 0,
              let delay = UInt64(exactly: (timeout * 1_000_000_000).rounded(.towardZero)) else { return false }
        let token = UUID()
        guard !Task.isCancelled else { return false }
        let done = ScopedWaiter()
        waiters[correlationID, default: [:]][token] = done
        timeoutTasks[token] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.resume(correlationID: correlationID, token: token, signalled: false)
        }
        await done.park()
        resume(correlationID: correlationID, token: token, signalled: false)
        return results.removeValue(forKey: token)!
    }

    private func resume(correlationID: String, token: UUID, signalled: Bool) {
        timeoutTasks.removeValue(forKey: token)?.cancel()
        guard let done = waiters[correlationID]?.removeValue(forKey: token) else { return }
        if waiters[correlationID]?.isEmpty == true {
            waiters.removeValue(forKey: correlationID)
        }
        results[token] = signalled
        done.resume()
    }
}
