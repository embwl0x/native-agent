import Foundation
import GitHubConnector
import NativeAgentCore
import PersistenceCore

actor GitHubCommandRuntime {
    typealias ObservationLoader = @Sendable (GitHubCommandItem) async throws -> GitHubCommandObservation
    typealias NotificationSender = @Sendable (GitHubCommandNotificationIntent) async throws -> (String, String)
    typealias OutcomeObserver = @Sendable (MotorActionReadModel) async -> Void

    static let shared = GitHubCommandRuntime.live()

    private let store: GitHubCommandStore
    private let dataRoot: URL
    /// Last (mtime,size) fingerprint of the op-log pair this runtime replayed
    /// from. nil until the first replay, so the first tick after launch always
    /// replays. See `processConnectorChangesIfChanged`.
    private var opLogFingerprint: String?
    private var connectorReplayCount = 0
    private let observationLoader: ObservationLoader
    private let notificationSender: NotificationSender
    private let outcomeObserver: OutcomeObserver
    private let residentStateLoader: @Sendable () async throws -> [GitHubCommandItem]
    private var residentOutcomeFingerprints: [String: String] = [:]
    private var residentOutcomeBaselinePrimed = false
    /// Both launch branches require the same baseline before they can safely
    /// recover credentials or start connector loops. `liveState()` suspends,
    /// so a boolean guard alone is reentrant and permits duplicate full-store
    /// reductions. Every concurrent caller awaits this one in-flight read.
    private var residentOutcomeBaselineTask: Task<[GitHubCommandItem], Error>?
    private var residentOutcomeBaselineLoadCount = 0

    init(
        dataRoot: URL,
        observationLoader: @escaping ObservationLoader,
        notificationSender: @escaping NotificationSender,
        outcomeObserver: @escaping OutcomeObserver = { _ in },
        residentStateLoader: (@Sendable () async throws -> [GitHubCommandItem])? = nil
    ) {
        let store = GitHubCommandStore(dataRoot: dataRoot)
        self.store = store
        self.dataRoot = dataRoot
        self.observationLoader = observationLoader
        self.notificationSender = notificationSender
        self.outcomeObserver = outcomeObserver
        self.residentStateLoader = residentStateLoader ?? {
            try await store.liveState().items
        }
    }

    static func live(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> GitHubCommandRuntime {
        let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
        return GitHubCommandRuntime(
            dataRoot: dataRoot,
            observationLoader: { item in
                try await GitHubConnectorActions.commandObservation(for: item, dataRoot: dataRoot)
            },
            notificationSender: { intent in
                guard usesLiveAppBody else {
                    throw NSError(
                        domain: "GitHubCommandRuntime",
                        code: 503,
                        userInfo: [NSLocalizedDescriptionKey: "canonical notification body unavailable for alternate data root"]
                    )
                }
                // Item 26: a GitHub command notification is Agent handing User a
                // decision — owner-waiting. Payload unchanged.
                let outcome = try await AttentionRouter.shared.route(
                    eventId: "github_command:\(intent.dedupKey)",
                    importance: .ownerWaiting,
                    title: intent.title,
                    body: intent.body,
                    userInfo: [
                        "kind": "github_command",
                        "githubCommandItemId": intent.itemId,
                        "dedupKey": intent.dedupKey,
                    ]
                )
                guard let receipt = outcome.receipt else {
                    // Routed away from the phone (Telegram) or already
                    // delivered under this exact dedup key. Either way the
                    // knock happened; there is no APNS receipt to report.
                    return (
                        outcome.suppressed ? "duplicate" : "delivered_\(outcome.delivery.rawValue)",
                        outcome.suppressed
                            ? "already delivered under \(intent.dedupKey)"
                            : "routed to \(outcome.delivery.rawValue)"
                    )
                }
                let fields = JSONValue.object(receipt.deliveryFields())
                return (receipt.status, Self.failureDetail(fields))
            },
            outcomeObserver: { model in
                guard usesLiveAppBody else { return }
                await NativeCognitionRuntime.shared.observeMotorActionState(model)
            }
        )
    }

    /// Captures the pre-refresh semantic baseline after launch without turning
    /// historical rows into fresh physiology. A later canonical reducer change
    /// is compared against this baseline and only that transition is emitted.
    func replayResidentStateAtLaunch() async {
        guard !residentOutcomeBaselinePrimed else { return }
        let task: Task<[GitHubCommandItem], Error>
        let ownsTask: Bool
        if let inFlight = residentOutcomeBaselineTask {
            task = inFlight
            ownsTask = false
        } else {
            residentOutcomeBaselineLoadCount += 1
            let loader = residentStateLoader
            let created = Task { try await loader() }
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
            NSLog("github_command: resident replay failed: \(error.localizedDescription)")
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
    func recoverAtLaunch() async {
        do {
            let items = try await store.liveState().nonTerminalItems.filter {
                switch $0.state {
                case .detected, .needsCodex, .codexWorking, .verifying, .attention:
                    return true
                case .needsUser, .waitingUpstream, .resolved:
                    return false
                }
            }
            var observations: [GitHubCommandObservation] = []
            var failures: [(String, String)] = []
            for item in items {
                do {
                    observations.append(try await observationLoader(item))
                } catch {
                    failures.append((item.itemId, GitHubCommandRuntime.readableDetail(error)))
                }
            }
            let observed = try await store.observe(observations)
            await observeOutcomes(observed)
            for (itemId, detail) in failures {
                if let failed = try? await store.recordVerificationReadFailure(itemId: itemId, detail: detail) {
                    await observeOutcome(failed)
                }
            }
            await processWatcherState()
        } catch {
            NSLog("github_command: launch recovery failed: \(error.localizedDescription)")
        }
    }

    /// Called after a connector refresh has already written live observations.
    func processConnectorChanges() async {
        connectorReplayCount += 1
        await processWatcherState()
    }

    /// A1/FIX-2: the former 300s github_tracking poll used to call
    /// `processConnectorChanges()` unconditionally, so every tick paid a full
    /// `liveState()` decode + reducer replay of a ~2MB op log (~630MB/day) just
    /// to learn nothing had changed.
    ///
    /// The replay now runs when the connector actually refreshed, OR when the
    /// op-log pair's (mtime,size) fingerprint differs from the one we last
    /// replayed from. The out-of-process-writer recovery property is PRESERVED
    /// exactly: canonical GitHub Command base/tail invalidations now wake the
    /// event/deadline runner directly, while its six-hour integrity sweep
    /// repairs any missed file event. Either path fingerprints both files and
    /// replays on ANY change — an external append (size grows), a compaction
    /// (base rewritten, ops truncated, size SHRINKS), or a same-size rewrite
    /// with a new mtime. It skips only when the bytes it would decode are
    /// provably the bytes it already decoded.
    ///
    /// The fingerprint is captured BEFORE the replay on purpose. Work done
    /// during the replay mutates the op log and therefore invalidates the
    /// stamp we just took, which costs one extra replay next tick — the safe
    /// direction. Capturing it afterwards would fold a concurrent external
    /// write into the cache without ever having processed it.
    func processConnectorChangesIfChanged(refreshed: Bool) async {
        let fingerprint = opLogFingerprintNow()
        guard refreshed || opLogFingerprint != fingerprint else { return }
        opLogFingerprint = fingerprint
        await processConnectorChanges()
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

    /// Test seam: how many full `liveState()` replay cycles this runtime has
    /// actually performed.
    func _testConnectorReplayCount() -> Int { connectorReplayCount }
    func _testResidentBaselineLoadCount() -> Int { residentOutcomeBaselineLoadCount }

    /// Legacy compatibility for callbacks from work that was already in flight
    /// before GitHub Command became watcher-only. This path cannot create or
    /// resume a Codex turn.
    func handleCodexCompletion(
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
            var observations: [GitHubCommandObservation] = []
            var failures: [(String, String)] = []
            for item in items {
                do {
                    observations.append(try await observationLoader(item))
                } catch {
                    failures.append((item.itemId, GitHubCommandRuntime.readableDetail(error)))
                }
            }
            let observed = try await store.observe(observations)
            await observeOutcomes(observed)
            for (itemId, detail) in failures {
                let failed = try await store.recordVerificationReadFailure(itemId: itemId, detail: detail)
                await observeOutcome(failed)
            }
            await processNotifications()
        } catch {
            NSLog("github_command: callback correlation failed: \(error.localizedDescription)")
        }
    }

    private func processWatcherState() async {
        do {
            let state = try await store.liveState()
            await observeOutcomes(state.items)
            pruneResidentOutcomeFingerprints(reportedItems: state.items)
            await processNotifications()
        } catch {
            NSLog("github_watcher: state cycle failed: \(error.localizedDescription)")
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
    /// Internal (not private) so the runtime tests can drive it directly.
    func pruneResidentOutcomeFingerprints(reportedItems: [GitHubCommandItem]) {
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
            NSLog("github_command: notification cycle failed: \(error.localizedDescription)")
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
                NSLog("github_command: receipt persist failed for \(intent.dedupKey): \(GitHubCommandRuntime.readableDetail(error))")
            }
        }
    }

    private static func failureDetail(_ value: JSONValue) -> String {
        (try? value.serialize(pretty: false)).map { String($0.prefix(1_000)) } ?? "unknown bridge result"
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
