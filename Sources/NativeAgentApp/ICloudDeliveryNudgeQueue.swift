import Foundation

/// The KVS wake-up is not delivery confirmation: it merely gives the paired
/// device a prompt to drain its real transport. Keep the retry plan bounded,
/// observable, and single-flight so a chat burst cannot create an unbounded
/// set of sleeping tasks.
enum ICloudDeliveryNudgeDisposition: Sendable, Equatable {
    case synchronized
    case unavailable
    case synchronizeFailed
}

struct ICloudDeliveryNudgeOutcome: Sendable, Equatable {
    let messageID: String
    let disposition: ICloudDeliveryNudgeDisposition
}

struct ICloudDeliveryNudgeSnapshot: Sendable, Equatable {
    let plannedCount: Int
    let pendingCount: Int
    let synchronizedCount: Int
    let unavailableCount: Int
    let failedCount: Int
    let activeWorkerCount: Int
    let workerStartCount: Int
}

actor ICloudDeliveryNudgeQueue {
    typealias Availability = @Sendable () async -> Bool
    typealias NudgeSender = @Sendable (String) async -> Bool
    typealias OutcomeObserver = @Sendable (ICloudDeliveryNudgeOutcome) async -> Void

    private struct PendingNudge: Sendable {
        let messageID: String
        let dueAt: Date
    }

    private let delaysNanoseconds: [UInt64]
    private let automaticallyRun: Bool
    private let isAvailable: Availability
    private let sendNudge: NudgeSender
    private let observeOutcome: OutcomeObserver

    private var pending: [PendingNudge] = []
    private var workerTask: Task<Void, Never>?
    private var workerActive = false
    private var workerStartCount = 0
    private var plannedCount = 0
    private var synchronizedCount = 0
    private var unavailableCount = 0
    private var failedCount = 0

    init(
        delaysNanoseconds: [UInt64] = ICloudDeliveryNudgePlan.delaysNanoseconds,
        automaticallyRun: Bool = true,
        isAvailable: @escaping Availability,
        sendNudge: @escaping NudgeSender,
        observeOutcome: @escaping OutcomeObserver = { _ in }
    ) {
        self.delaysNanoseconds = delaysNanoseconds.filter { $0 > 0 }
        self.automaticallyRun = automaticallyRun
        self.isAvailable = isAvailable
        self.sendNudge = sendNudge
        self.observeOutcome = observeOutcome
    }

    /// Enqueue exactly one declared nudge per plan delay. A single worker owns
    /// every pending message, including bursts, rather than spawning one task
    /// per delay per outbound message.
    func schedule(for messageID: String) {
        let scheduledAt = Date()
        for delayNanoseconds in delaysNanoseconds {
            let delaySeconds = Double(delayNanoseconds) / 1_000_000_000
            pending.append(PendingNudge(
                messageID: messageID,
                dueAt: scheduledAt.addingTimeInterval(delaySeconds)
            ))
            plannedCount += 1
        }
        startWorkerIfNeeded()
    }

    func snapshot() -> ICloudDeliveryNudgeSnapshot {
        ICloudDeliveryNudgeSnapshot(
            plannedCount: plannedCount,
            pendingCount: pending.count,
            synchronizedCount: synchronizedCount,
            unavailableCount: unavailableCount,
            failedCount: failedCount,
            activeWorkerCount: workerActive ? 1 : 0,
            workerStartCount: workerStartCount
        )
    }

    /// Hermetic evaluation seam. It runs the same availability, KVS-send, and
    /// outcome accounting path without waiting for wall-clock delivery delays.
    func drainImmediatelyForTesting() async {
        workerTask?.cancel()
        workerTask = nil
        workerActive = false
        let scheduled = pending
        pending.removeAll()
        for nudge in scheduled {
            await deliver(nudge)
        }
    }

    func cancelAll() {
        workerTask?.cancel()
        workerTask = nil
        workerActive = false
        pending.removeAll()
    }

    private func startWorkerIfNeeded() {
        guard automaticallyRun, !workerActive else { return }
        workerActive = true
        workerStartCount += 1
        workerTask = Task { [weak self] in
            await self?.runScheduledNudges()
        }
    }

    private func runScheduledNudges() async {
        defer {
            workerTask = nil
            workerActive = false
            startWorkerIfNeeded()
        }
        while !Task.isCancelled {
            guard let next = pending.map(\.dueAt).min() else { return }
            let remaining = next.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }

            let now = Date()
            let due = pending.filter { $0.dueAt <= now }
            guard !due.isEmpty else { continue }
            pending.removeAll { $0.dueAt <= now }
            for nudge in due {
                await deliver(nudge)
            }
        }
    }

    private func deliver(_ nudge: PendingNudge) async {
        let outcome: ICloudDeliveryNudgeOutcome
        if await isAvailable() {
            if await sendNudge(nudge.messageID) {
                synchronizedCount += 1
                outcome = ICloudDeliveryNudgeOutcome(
                    messageID: nudge.messageID,
                    disposition: .synchronized
                )
            } else {
                failedCount += 1
                outcome = ICloudDeliveryNudgeOutcome(
                    messageID: nudge.messageID,
                    disposition: .synchronizeFailed
                )
            }
        } else {
            unavailableCount += 1
            outcome = ICloudDeliveryNudgeOutcome(
                messageID: nudge.messageID,
                disposition: .unavailable
            )
        }
        await observeOutcome(outcome)
    }
}
