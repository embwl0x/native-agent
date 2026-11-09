import Foundation

// Blueprint: | `ICloudDeliveryNudgeQueue.swift` | Acceptance-triggered wake hints; one worker joins each KVS completion. |

/// A wake hint reports local synchronization, never recipient acceptance.
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

    private let isAvailable: Availability
    private let sendNudge: NudgeSender
    private let observeOutcome: OutcomeObserver

    private var pending: [String] = []
    private var workerTask: Task<Void, Never>?

    init(
        isAvailable: @escaping Availability,
        sendNudge: @escaping NudgeSender,
        observeOutcome: @escaping OutcomeObserver = { _ in }
    ) {
        self.isAvailable = isAvailable
        self.sendNudge = sendNudge
        self.observeOutcome = observeOutcome
    }

    /// Each acceptance event queues one wake; the active send owns its actual completion.
    func schedule(for messageID: String) {
        pending.append(messageID)
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
            guard !pending.isEmpty else { return }
            let messageID = pending.removeFirst()
            await deliver(messageID)
        }
    }

    private func deliver(_ messageID: String) async {
        let outcome: ICloudDeliveryNudgeOutcome
        if await isAvailable() {
            if await sendNudge(messageID) {
                outcome = ICloudDeliveryNudgeOutcome(
                    messageID: messageID,
                    disposition: .synchronized
                )
            } else {
                outcome = ICloudDeliveryNudgeOutcome(
                    messageID: messageID,
                    disposition: .synchronizeFailed
                )
            }
        } else {
            outcome = ICloudDeliveryNudgeOutcome(
                messageID: messageID,
                disposition: .unavailable
            )
        }
        await observeOutcome(outcome)
    }
}
