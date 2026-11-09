import ActivityWatch
import Foundation
import MemoryV2
import NativeAgentShared
import Observation
import Privacy
// Blueprint: | `CountsStatusProjection.swift` | `CountsStatusProjection`: ordered off-main phone, health, capture, download, transport and toast values |

public actor CountsStatusProjection {
    struct Input: Sendable {
        let phoneConnection: NAPhoneConnection?
        let phoneStanding: NAPhoneStanding?
        let phoneStatus: String?
        let pairingError: String?
        let isCheckingPairing: Bool
        let health: RuntimeHealth?
        let capturePolicy: ActivityPolicy
        let captureAvailability: ActivityWatchController.PolicyAvailability
        let isCapturing: Bool
        let telegram: TelegramPresentationSnapshot?
        let telegramIssue: String?
    }

    private enum Change: Sendable {
        case owners(Input)
        case download(EmbeddingDownloadStatus, Bool)
        case toasts(UUID, [SystemToast])
        case removeToastCenter(UUID)
    }

    private let countsFeed: CountsFeedProjection
    private var value = CountStatusValues()
    private var sent: CountStatusValues?
    private var downloadObservation: Task<Void, Never>?
    private var toastObservations: [UUID: Task<Void, Never>] = [:]
    private nonisolated let changes: AsyncStream<Change>.Continuation

    public init(countsFeed: CountsFeedProjection) {
        self.countsFeed = countsFeed
        let (stream, continuation) = AsyncStream.makeStream(of: Change.self)
        changes = continuation
        Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                await self.apply(change)
            }
        }
    }

    deinit {
        downloadObservation?.cancel()
        for task in toastObservations.values { task.cancel() }
        changes.finish()
    }

    nonisolated func submit(_ input: Input) { changes.yield(.owners(input)) }

    nonisolated func submitDownload(_ status: EmbeddingDownloadStatus, activating: Bool) {
        changes.yield(.download(status, activating))
    }

    func observeDownload(_ updates: AsyncStream<EmbeddingModelDownloadController.Update>) {
        downloadObservation?.cancel()
        downloadObservation = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { return }
                submitDownload(update.status, activating: update.activating)
            }
        }
    }

    public func observeToasts(_ center: SystemToastCenter) {
        let id = center.id
        guard toastObservations[id] == nil else { return }
        toastObservations[id] = Task { [weak self, weak center] in
            guard let updates = await center?.updates() else {
                await self?.retireToasts(id)
                return
            }
            for await queue in updates {
                guard !Task.isCancelled, let self else { return }
                changes.yield(.toasts(id, queue))
            }
            await self?.retireToasts(id)
        }
    }

    private func retireToasts(_ id: UUID) {
        toastObservations.removeValue(forKey: id)
        changes.yield(.removeToastCenter(id))
    }

    private func apply(_ change: Change) async {
        switch change {
        case .owners(let input):
            value.phoneConnection = input.phoneConnection.map {
                .init(pairing: disclosed($0.pairing), transport: disclosed($0.transport), exchange: disclosed($0.exchange))
            }
            value.phoneStanding = input.phoneStanding
            value.phoneStatus = input.phoneStatus.map(NativeAppSecretRedactor.redactText)
            value.pairingError = input.pairingError.map(NativeAppSecretRedactor.redactText)
            value.isCheckingPairing = input.isCheckingPairing
            value.health = input.health
            let availability: ActivityCaptureFace.Availability
            switch input.captureAvailability {
            case .loading: availability = .reading
            case .available: availability = .available
            case .unavailable(let issue): availability = .unavailable(NativeAppSecretRedactor.redactText(issue))
            }
            value.capture = .init(isCapturing: input.isCapturing,
                capturesTitles: input.capturePolicy.captureTitles && !input.capturePolicy.appNameOnlyMode, availability: availability)
            value.telegram = input.telegram.map {
                .init(enabled: $0.transport.enabled, pollerRunning: $0.transport.pollerEnabled,
                    lastError: $0.lastError.map(NativeAppSecretRedactor.redactText),
                    credentialIssue: $0.credentialIssue.map(NativeAppSecretRedactor.redactText),
                    routingIssue: $0.routingIssue.map(NativeAppSecretRedactor.redactText),
                    readIssue: input.telegramIssue.map(NativeAppSecretRedactor.redactText))
            }
            if input.telegram == nil, let issue = input.telegramIssue {
                value.telegram = .init(enabled: nil, pollerRunning: nil, lastError: nil, credentialIssue: nil,
                    routingIssue: nil, readIssue: NativeAppSecretRedactor.redactText(issue))
            }
        case .download(let status, let activating):
            var disclosed = status
            disclosed.phase = NativeAppSecretRedactor.redactText(status.phase)
            disclosed.cleanupFailure = status.cleanupFailure.map(NativeAppSecretRedactor.redactText)
            value.download = .init(status: disclosed, activating: activating)
        case .toasts(let center, let queue):
            value.toastQueues[center] = queue.map {
                SystemToast(kind: $0.kind, text: NativeAppSecretRedactor.redactText($0.text),
                    autoDismissAfter: $0.autoDismissAfter, id: $0.id, createdAt: $0.createdAt)
            }
        case .removeToastCenter(let center):
            value.toastQueues.removeValue(forKey: center)
        }
        guard value != sent else { return }
        sent = value
        await countsFeed.updateStatuses(value)
    }

    private func disclosed(_ fact: NAPhoneConnection.Fact) -> NAPhoneConnection.Fact {
        .init(fact.state, NativeAppSecretRedactor.redactText(fact.line), owner: fact.owner,
            lever: fact.lever.map(NativeAppSecretRedactor.redactText))
    }
}

extension NativeAgentEngine {
    @MainActor public func bindCountStatusSources() {
        let updates = EmbeddingModelDownloadController.shared.updates()
        Task { [countsStatus] in await countsStatus.observeDownload(updates) }
        observeCountStatusSources()
    }

    @MainActor private func observeCountStatusSources() {
        let input = withObservationTracking {
            CountsStatusProjection.Input(phoneConnection: sync.connection, phoneStanding: sync.standing,
                phoneStatus: sync.status, pairingError: sync.pairingError, isCheckingPairing: sync.isCheckingPairing,
                health: doctor.health, capturePolicy: activityWatch.policy, captureAvailability: activityWatch.policyAvailability,
                isCapturing: activityWatch.isCapturing, telegram: telegram.status, telegramIssue: telegram.statusIssue)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCountStatusSources() }
        }
        countsStatus.submit(input)
    }
}
