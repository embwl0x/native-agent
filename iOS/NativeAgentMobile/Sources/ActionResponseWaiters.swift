import Foundation

/// One MainActor-isolated rendezvous between the transport drain that persists
/// `responses/<correlationID>.json` and the task waiting on that response.
/// Single-resume is guaranteed structurally: a continuation is removed from the
/// table before it is resumed, so timeout, signal, and cancellation race safely.
@MainActor
final class ActionResponseWaiters {
    static let shared = ActionResponseWaiters()

    /// Backstop cadence for transport drains when no push arrives.
    static let backstopInterval: TimeInterval = 5

    private var waiters: [String: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    private var arrived: Set<String> = []
    private var armed: Set<String> = []
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    func isWaiting(_ correlationID: String) -> Bool { armed.contains(correlationID) }

    /// Start watching `correlationID`. Called before the first response read so
    /// an arrival that races the first poll is remembered, not lost.
    func arm(_ correlationID: String) {
        armed.insert(correlationID)
        arrived.remove(correlationID)
    }

    /// Stop watching and release anyone still parked on this correlation.
    func disarm(_ correlationID: String) {
        iCloudBridge.shared.stopDeliveryNudges(for: correlationID)
        armed.remove(correlationID)
        arrived.remove(correlationID)
        for token in Array((waiters[correlationID] ?? [:]).keys) {
            resume(correlationID: correlationID, token: token, signalled: false)
        }
        waiters.removeValue(forKey: correlationID)
    }

    /// The response for `correlationID` is now durable in the local mailbox.
    /// Ignored for correlations nobody is waiting on so the arrival set cannot
    /// grow without bound across a long session.
    func signal(_ correlationID: String) {
        guard armed.contains(correlationID) else { return }
        arrived.insert(correlationID)
        for token in Array((waiters[correlationID] ?? [:]).keys) {
            resume(correlationID: correlationID, token: token, signalled: true)
        }
    }

    /// True when a signal for `correlationID` is already recorded.
    func hasArrived(_ correlationID: String) -> Bool {
        arrived.contains(correlationID)
    }

    /// Park until the response is signalled or `timeout` elapses. Returns true
    /// when a push signalled the arrival — the caller can then skip the
    /// transport drain it would otherwise have paid for.
    @discardableResult
    func wait(_ correlationID: String, timeout: TimeInterval) async -> Bool {
        if arrived.contains(correlationID) { return true }
        guard timeout.isFinite, timeout >= 0,
              let delay = UInt64(exactly: (timeout * 1_000_000_000).rounded(.towardZero)) else { return false }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if arrived.contains(correlationID) {
                    continuation.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters[correlationID, default: [:]][token] = continuation
                timeoutTasks[token] = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    self?.resume(correlationID: correlationID, token: token, signalled: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resume(correlationID: correlationID, token: token, signalled: false)
            }
        }
    }

    private func resume(correlationID: String, token: UUID, signalled: Bool) {
        timeoutTasks.removeValue(forKey: token)?.cancel()
        guard let continuation = waiters[correlationID]?.removeValue(forKey: token) else { return }
        if waiters[correlationID]?.isEmpty == true {
            waiters.removeValue(forKey: correlationID)
        }
        continuation.resume(returning: signalled)
    }
}
