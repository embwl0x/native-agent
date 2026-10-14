import Foundation
import NativeAgentCore
import PersistenceCore

public actor GitHubCommandRuntime {
    public typealias ObservationLoader = @Sendable (GitHubCommandItem) async throws -> GitHubCommandObservation
    public typealias NotificationSender = @Sendable (GitHubCommandNotificationIntent) async throws -> (String, String)
    public typealias OutcomeObserver = @Sendable (MotorActionReadModel) async -> Void

    private let store: GitHubCommandStore
    private let dataRoot: URL
    /// Last (mtime,size) fingerprint of the op-log pair this runtime replayed
    /// from. nil until the first replay, so the first tick after launch always
    /// replays. See `processConnectorChangesIfChanged`.
    private var opLogFingerprint: String?
    private let observationLoader: ObservationLoader
    private let notificationSender: NotificationSender
    private let outcomeObserver: OutcomeObserver
    private var residentOutcomeFingerprints: [String: String] = [:]
    private var residentOutcomeBaselinePrimed = false
    /// Both launch branches require the same baseline before they can safely
    /// recover credentials or start connector loops. `liveState()` suspends,
    /// so a boolean guard alone is reentrant and permits duplicate full-store
    /// reductions. Every concurrent caller awaits this one in-flight read.
    private var residentOutcomeBaselineTask: Task<[GitHubCommandItem], Error>?

    public init(
        dataRoot: URL,
        observationLoader: @escaping ObservationLoader,
        notificationSender: @escaping NotificationSender,
        outcomeObserver: @escaping OutcomeObserver = { _ in }
    ) {
        let store = GitHubCommandStore(dataRoot: dataRoot)
        self.store = store
        self.dataRoot = dataRoot
        self.observationLoader = observationLoader
        self.notificationSender = notificationSender
        self.outcomeObserver = outcomeObserver
    }

    /// Captures the pre-refresh semantic baseline after launch without turning
    /// historical rows into fresh physiology. A later canonical reducer change
    /// is compared against this baseline and only that transition is emitted.
    public func replayResidentStateAtLaunch() async {
        guard !residentOutcomeBaselinePrimed else { return }
        let task: Task<[GitHubCommandItem], Error>
        let ownsTask: Bool
        if let inFlight = residentOutcomeBaselineTask {
            task = inFlight
            ownsTask = false
        } else {
            let store = self.store
            let created = Task { try await store.liveState().items }
            residentOutcomeBaselineTask = created
            task = created
            ownsTask = true
        }
        do {
            let items = try await task.value
            if !residentOutcomeBaselinePrimed {
                seedOutcomeBaseline(items)
            }
        } catch {
            nativeLog("github_command: resident replay failed: \(error.localizedDescription)")
        }
        // Only the caller that installed this task clears it. On a failed
        // load, a waiter may resume before the owner; letting that waiter clear
        // the slot would allow a third caller to start a duplicate retry while
        // the owner is still unwinding the first attempt.
        if ownsTask {
            residentOutcomeBaselineTask = nil
        }
    }

    /// Launch recovery replays the store and re-reads active watcher rows so
    /// Desk and notifications reflect current GitHub state. It never starts,
    /// resumes, or retries work in Codex or any other provider.
    public func recoverAtLaunch() async {
        do {
            let items = try await store.liveState().nonTerminalItems.filter {
                switch $0.state {
                case .detected, .needsCodex, .codexWorking, .verifying, .attention:
                    return true
                case .needsOwner, .waitingUpstream, .resolved:
                    return false
                }
            }
            let (observations, failures) = await loadObservations(items)
            let observed = try await store.observe(observations)
            await observeOutcomes(observed)
            for (itemId, detail) in failures {
                if let failed = try? await store.recordVerificationReadFailure(itemId: itemId, detail: detail) {
                    await observeOutcome(failed)
                }
            }
            await processWatcherState()
        } catch {
            nativeLog("github_command: launch recovery failed: \(error.localizedDescription)")
        }
    }

    /// Replay after a connector refresh or a changed base/tail fingerprint.
    /// Canonical file invalidations wake the runner; its six-hour integrity
    /// sweep catches missed events. Capture before replay so a concurrent
    /// writer or our own notification claims remain visible on the next pass.
    public func processConnectorChangesIfChanged(refreshed: Bool) async {
        let fingerprint = opLogFingerprintNow()
        guard refreshed || opLogFingerprint != fingerprint else { return }
        opLogFingerprint = fingerprint
        await processWatcherState()
    }

    private func opLogFingerprintNow() -> String {
        let directory = dataRoot.appendingPathComponent("workshop/github_command", isDirectory: true)
        return [
            directory.appendingPathComponent("ops.jsonl"),
            directory.appendingPathComponent("ops_base.json"),
        ]
        .map { url -> String in
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ), let size = values.fileSize else { return "-" }
            let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? -1
            return "\(stamp):\(size)"
        }
        .joined(separator: "|")
    }

    /// Legacy compatibility for callbacks from work that was already in flight
    /// before GitHub Command became watcher-only. This path cannot create or
    /// resume a Codex turn.
    public func handleCodexCompletion(
        messageIds: [String],
        codexStatus: String,
        summary: String,
        threadId: String?,
        turnId: String?,
        errorMessage: String? = nil,
        noWorkObserved: Bool? = nil
    ) async {
        do {
            let items = try await store.recordCallback(
                messageIds: messageIds,
                codexStatus: codexStatus,
                summary: summary,
                threadId: threadId,
                turnId: turnId,
                errorMessage: errorMessage,
                noWorkObserved: noWorkObserved
            )
            await observeOutcomes(items)
            let (observations, failures) = await loadObservations(items)
            let observed = try await store.observe(observations)
            await observeOutcomes(observed)
            for (itemId, detail) in failures {
                let failed = try await store.recordVerificationReadFailure(itemId: itemId, detail: detail)
                await observeOutcome(failed)
            }
            await processNotifications()
        } catch {
            nativeLog("github_command: callback correlation failed: \(error.localizedDescription)")
        }
    }

    private func loadObservations(_ items: [GitHubCommandItem]) async -> ([GitHubCommandObservation], [(String, String)]) {
        var observations: [GitHubCommandObservation] = []
        var failures: [(String, String)] = []
        for item in items {
            do {
                observations.append(try await observationLoader(item))
            } catch {
                failures.append((item.itemId, Self.readableDetail(error)))
            }
        }
        return (observations, failures)
    }

    private func processWatcherState() async {
        do {
            let state = try await store.liveState()
            await observeOutcomes(state.items)
            pruneResidentOutcomeFingerprints(reportedItems: state.items)
            await processNotifications()
        } catch {
            nativeLog("github_watcher: state cycle failed: \(error.localizedDescription)")
        }
    }

    private func observeOutcomes(_ items: [GitHubCommandItem]) async {
        guard residentOutcomeBaselinePrimed else {
            seedOutcomeBaseline(items)
            return
        }
        for item in items {
            await observeOutcome(item)
        }
    }

    private func observeOutcome(_ item: GitHubCommandItem) async {
        let model = GitHubCommandStore.motorActionReadModel(item: item)
        let fingerprint = GitHubCommandStore.motorSemanticFingerprint(model)
        guard residentOutcomeFingerprints[model.actionIdentity] != fingerprint else { return }
        residentOutcomeFingerprints[model.actionIdentity] = fingerprint
        await outcomeObserver(model)
    }

    /// 2026-07-21 audit fix: residentOutcomeFingerprints only ever inserted,
    /// so one baseline per item lived for the process lifetime. The store
    /// retires terminal items out of its reduced state
    /// (terminalItemRetentionSeconds) and the cockpit's bucket() only
    /// surfaces what the store still reports — mirror that: keep exactly the
    /// identities the store's latest live state reported. Runs AFTER
    /// observeOutcomes so a still-reported settled item never loses its
    /// baseline (a missing entry diffs as changed and would re-fire the
    /// observer every cycle); a retired item that somehow reappears re-seeds
    /// next observation — one honest re-fire, not a stale baseline.
    private func pruneResidentOutcomeFingerprints(reportedItems: [GitHubCommandItem]) {
        let reported = Set(reportedItems.map {
            GitHubCommandStore.motorActionReadModel(item: $0).actionIdentity
        })
        guard residentOutcomeFingerprints.count > reported.count else { return }
        residentOutcomeFingerprints = residentOutcomeFingerprints.filter { reported.contains($0.key) }
    }

    private func seedOutcomeBaseline(_ items: [GitHubCommandItem]) {
        for item in items {
            let model = GitHubCommandStore.motorActionReadModel(item: item)
            residentOutcomeFingerprints[model.actionIdentity] =
                GitHubCommandStore.motorSemanticFingerprint(model)
        }
        residentOutcomeBaselinePrimed = true
    }

    private func processNotifications() async {
        let intents: [GitHubCommandNotificationIntent]
        do {
            intents = try await store.claimPendingNotifications()
        } catch {
            nativeLog("github_command: notification cycle failed: \(error.localizedDescription)")
            return
        }
        // Every intent above is already durably claimed and will never be
        // re-surfaced, so a persistence failure for one intent must not abort
        // the rest of the batch, and a receipt-write failure after a delivered
        // send must not be recorded as a send failure.
        for intent in intents {
            var status = "failed"
            var detail = ""
            do {
                (status, detail) = try await notificationSender(intent)
            } catch {
                detail = GitHubCommandRuntime.readableDetail(error)
            }
            do {
                _ = try await store.recordNotification(
                    itemId: intent.itemId,
                    dedupKey: intent.dedupKey,
                    status: status,
                    detail: detail
                )
            } catch {
                nativeLog("github_command: receipt persist failed for \(intent.dedupKey): \(GitHubCommandRuntime.readableDetail(error))")
            }
        }
    }
}

extension GitHubCommandRuntime {
    /// Human-readable error detail for work logs and blocker lines —
    /// String(describing:) leaks Swift enum debug syntax (Optional(...)) into
    /// the UI, which read as a rate-limit problem when GitHub returned a 502.
    static func readableDetail(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
