import Foundation

// Blueprint: | `ICloudDeliveryNudgeQueue.swift` | `ICloudDeliveryNudgeQueue`: one bounded single-flight KVS wake worker; a nudge never proves transport delivery |

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

actor ICloudDeliveryNudgeQueue {
    typealias Availability = @Sendable () async -> Bool
    typealias NudgeSender = @Sendable (String) async -> Bool
    typealias OutcomeObserver = @Sendable (ICloudDeliveryNudgeOutcome) async -> Void

    private struct PendingNudge: Sendable {
        let messageID: String
        let dueAt: Date
    }

    private let delaysNanoseconds: [UInt64]
    private let isAvailable: Availability
    private let sendNudge: NudgeSender
    private let observeOutcome: OutcomeObserver

    private var pending: [PendingNudge] = []
    private var workerTask: Task<Void, Never>?

    init(
        delaysNanoseconds: [UInt64] = ICloudDeliveryNudgePlan.delaysNanoseconds,
        isAvailable: @escaping Availability,
        sendNudge: @escaping NudgeSender,
        observeOutcome: @escaping OutcomeObserver = { _ in }
    ) {
        self.delaysNanoseconds = delaysNanoseconds.filter { $0 > 0 }
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
        }
        startWorkerIfNeeded()
    }

    func cancelAll() {
        workerTask?.cancel()
        pending.removeAll()
    }

    private func startWorkerIfNeeded() {
        // Only pending work starts a worker; cancellation retains ownership until the worker exits.
        guard workerTask == nil, !pending.isEmpty else { return }
        workerTask = Task { [weak self] in
            await self?.runScheduledNudges()
        }
    }

    private func runScheduledNudges() async {
        defer {
            workerTask = nil
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
                guard !Task.isCancelled else { return }
                await deliver(nudge)
            }
        }
    }

    private func deliver(_ nudge: PendingNudge) async {
        let outcome: ICloudDeliveryNudgeOutcome
        if await isAvailable() {
            if await sendNudge(nudge.messageID) {
                outcome = ICloudDeliveryNudgeOutcome(
                    messageID: nudge.messageID,
                    disposition: .synchronized
                )
            } else {
                outcome = ICloudDeliveryNudgeOutcome(
                    messageID: nudge.messageID,
                    disposition: .synchronizeFailed
                )
            }
        } else {
            outcome = ICloudDeliveryNudgeOutcome(
                messageID: nudge.messageID,
                disposition: .unavailable
            )
        }
        await observeOutcome(outcome)
    }
}
