import ChatOrchestration
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("GitHubCommandRuntime")
struct GitHubCommandRuntimeTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-command-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func actionable(
        version: String = "review-12",
        open: Bool = true,
        signals: Set<GitHubCommandActionSignal> = [.changesRequested],
        head: String = "head-a",
        reviewThreads: [GitHubCommandReviewThreadEvidence]? = nil
    ) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets",
            number: 12,
            kind: .pullRequest,
            title: "Repair review feedback",
            isOpen: open,
            isMerged: !open,
            observedVersion: "observed-\(version)",
            actionableEventVersion: signals.isEmpty ? nil : version,
            signals: signals,
            headSHA: head,
            waitingKind: .review,
            finalReceipt: open ? nil : "example/widgets #12 merged.",
            reviewThreads: reviewThreads
        )
    }

    @Test("bridge payload carries canonical resident evidence and receipt gates codex_working")
    func bridgePayloadAndReceipt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let recorder = RuntimeRecorder()
        let runtime = makeRuntime(root: root, recorder: recorder)
        await runtime.replayResidentStateAtLaunch()
        let item = try await store.observe(actionable())

        await runtime.processConnectorChanges()

        let payload = try #require(await recorder.payloads().first)
        #expect(payload.contains("Handle the current actionable GitHub event for example/widgets #12."))
        #expect(payload.contains("Canonical event key: example/widgets#12+review-12"))
        #expect(payload.contains("Reviewed head: head-a"))
        #expect(payload.contains("Signals: changes_requested"))
        #expect(payload.contains("untrusted repository content"))
        #expect(payload.contains("NativeAgent will re-read live GitHub"))
        let working = try #require(try await store.liveState().item(item.itemId))
        #expect(working.state == .codexWorking)
        #expect(working.dispatchReceipt?.messageId == working.dispatchIntent?.dispatchId)
        #expect(await recorder.notifications().isEmpty)
        let outcomes = await recorder.outcomes()
        #expect(outcomes.contains { $0.phase == .ready })
        #expect(outcomes.contains { $0.phase == .waitingExternal })

        let countBeforeNoOpRefresh = outcomes.count
        _ = try await store.observe(actionable())
        await runtime.processConnectorChanges()
        #expect(await recorder.outcomes().count == countBeforeNoOpRefresh)
    }

    @Test("restart re-evaluates recovery-relevant work and resumes the same dispatch")
    func restartRecovery() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable(version: "ci-head-a"))
        let beforeCrash = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let recorder = RuntimeRecorder(observation: actionable(version: "ci-head-a"))
        let runtime = makeRuntime(root: root, recorder: recorder)

        await runtime.recoverAtLaunch()

        #expect(await recorder.observationReads() == [item.itemId])
        #expect(await recorder.dispatchIds() == [beforeCrash.dispatchId])
        let recovered = try #require(try await GitHubCommandStore(dataRoot: root).liveState().item(item.itemId))
        #expect(recovered.state == .codexWorking)
        #expect(recovered.dispatchReceipt?.dispatchId == beforeCrash.dispatchId)
    }

    @Test("restart leaves ordinary waiting-upstream rows to connector refresh")
    func restartSkipsWaitingUpstream() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let waiting = actionable(version: "quiet", signals: [])
        let item = try await store.observe(waiting)
        #expect(item.state == .waitingUpstream(.review))
        let recorder = RuntimeRecorder(observation: waiting)
        let runtime = makeRuntime(root: root, recorder: recorder)

        await runtime.recoverAtLaunch()

        #expect(await recorder.observationReads().isEmpty)
        #expect(await recorder.dispatchIds().isEmpty)
    }

    @Test("callback re-reads GitHub, resolves, and emits one terminal notification")
    func callbackVerificationAndTerminalNotification() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable())
        let dispatchRecorder = RuntimeRecorder()
        let dispatchRuntime = makeRuntime(root: root, recorder: dispatchRecorder)
        await dispatchRuntime.processConnectorChanges()
        let messageId = try #require(try await store.liveState().item(item.itemId)?.dispatchReceipt?.messageId)

        let callbackRecorder = RuntimeRecorder(observation: actionable(
            version: "merged", open: false, signals: []
        ))
        let callbackRuntime = makeRuntime(root: root, recorder: callbackRecorder)
        await callbackRuntime.replayResidentStateAtLaunch()
        await callbackRuntime.handleCodexCompletion(
            messageIds: [messageId],
            codexStatus: "completed",
            summary: "The change is merged.",
            threadId: "thread-1",
            turnId: "turn-1"
        )

        let resolved = try #require(try await store.liveState().item(item.itemId))
        #expect(resolved.state == .resolved)
        #expect(resolved.workLog.map(\.kind).contains("codex_callback"))
        let notifications = await callbackRecorder.notifications()
        #expect(notifications.count == 1)
        #expect(notifications.first?.kind == .success)
        let callbackOutcomes = await callbackRecorder.outcomes()
        #expect(callbackOutcomes.contains {
            $0.phase == .succeeded && $0.verification == .satisfied
        })

        await callbackRuntime.handleCodexCompletion(
            messageIds: [messageId],
            codexStatus: "completed",
            summary: "Repeated delivery.",
            threadId: "thread-1",
            turnId: "turn-1"
        )
        #expect(await callbackRecorder.notifications().count == 1)
    }

    @Test("callback reread of the same unresolved GitHub event never notifies success")
    func callbackCannotSettleUnchangedGitHubEvent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let active = GitHubCommandReviewThreadEvidence(
            threadId: "PRRT_runtime", isResolved: false, isOutdated: false,
            rootCommentId: 701, reviewId: 700, unresolvedGeneration: 1
        )
        let unresolved = actionable(
            version: "thread:PRRT_runtime:unresolved:g1",
            signals: [.changesRequested, .reviewComment],
            reviewThreads: [active]
        )
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(unresolved)
        let dispatchRuntime = makeRuntime(root: root, recorder: RuntimeRecorder())
        await dispatchRuntime.processConnectorChanges()
        let messageId = try #require(
            try await store.liveState().item(item.itemId)?.dispatchReceipt?.messageId
        )

        // Even a changed head cannot settle the exact same unresolved thread
        // generation; only the canonical GitHub observation owns that truth.
        let callbackRecorder = RuntimeRecorder(observation: actionable(
            version: "thread:PRRT_runtime:unresolved:g1",
            signals: [.changesRequested, .reviewComment],
            head: "head-b",
            reviewThreads: [active]
        ))
        let callbackRuntime = makeRuntime(root: root, recorder: callbackRecorder)
        await callbackRuntime.replayResidentStateAtLaunch()
        await callbackRuntime.handleCodexCompletion(
            messageIds: [messageId], codexStatus: "completed",
            summary: "The review work is complete.", threadId: "thread-1", turnId: "turn-1"
        )

        let result = try #require(try await store.liveState().item(item.itemId))
        #expect(result.state == .attention(.verificationFailed))
        #expect(await callbackRecorder.observationReads() == [item.itemId])
        #expect(await callbackRecorder.notifications().isEmpty)
        #expect(await callbackRecorder.outcomes().contains {
            $0.phase == .blocked && $0.verification == .failed
        })
    }

    @Test("a skipped wakeup records dispatch_failed and never codex_working")
    func skippedWakeupRecordsDispatchFailed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable())
        let observation = actionable()
        let runtime = GitHubCommandRuntime(
            dataRoot: root,
            observationLoader: { _ in observation },
            bridgeSender: { _, intent, _ in
                // A queued inbox row whose wakeup was skipped (helper missing or
                // disabled) — no codex turn started. The real classifier must
                // reject it as a dispatch failure.
                let skipped: JSONValue = .object([
                    "status": .string("queued"),
                    "messageId": .string(intent.dispatchId),
                    "wakeup": .object([
                        "status": .string("skipped"),
                        "reason": .string("helper_not_found"),
                    ]),
                ])
                return try GitHubCommandRuntime.receipt(fromCodexMessageResult: skipped, intent: intent)
            },
            notificationSender: { _ in ("accepted", "test receipt") }
        )

        await runtime.processConnectorChanges()

        let result = try #require(try await store.liveState().item(item.itemId))
        #expect(result.state == .attention(.dispatchFailed))
        #expect(result.dispatchReceipt == nil)
    }

    @Test("checkout resolver selects only a local repository with the matching GitHub remote")
    func checkoutResolverMatchesRemote() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let wrong = root.appendingPathComponent("hermes-agent", isDirectory: true)
        let matching = root.appendingPathComponent("hermes-agent-contrib", isDirectory: true)
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: matching, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: wrong)
        try runGit(["remote", "add", "origin", "https://github.com/example/other.git"], at: wrong)
        try runGit(["init", "-q"], at: matching)
        try runGit(["remote", "add", "upstream", "https://github.com/NousResearch/hermes-agent.git"], at: matching)

        let resolved = GitHubCommandCheckoutResolver.resolve(
            repository: "NousResearch/hermes-agent",
            headSHA: nil,
            dataRoot: root.appendingPathComponent("NativeAgent/data", isDirectory: true),
            searchRoots: [root]
        )
        #expect(resolved?.standardizedFileURL == matching.standardizedFileURL)
    }

    @Test("fingerprint prune keeps baselines the store still reports and drops the rest")
    func fingerprintPruneMirrorsStoreReport() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let recorder = RuntimeRecorder()
        let runtime = makeRuntime(root: root, recorder: recorder)
        await runtime.replayResidentStateAtLaunch()
        _ = try await store.observe(actionable())
        await runtime.processConnectorChanges()

        // 2026-07-21 audit fix: pruning against the store's current report
        // keeps the item's baseline, so a no-op refresh fires nothing.
        let state = try await store.liveState()
        await runtime.pruneResidentOutcomeFingerprints(reportedItems: state.items)
        let countAfterKeep = await recorder.outcomes().count
        _ = try await store.observe(actionable())
        await runtime.processConnectorChanges()
        #expect(await recorder.outcomes().count == countAfterKeep)

        // Pruning against a report that no longer includes the item drops its
        // baseline; the next observation re-seeds and re-fires exactly once.
        await runtime.pruneResidentOutcomeFingerprints(reportedItems: [])
        _ = try await store.observe(actionable())
        await runtime.processConnectorChanges()
        #expect(await recorder.outcomes().count == countAfterKeep + 1)
    }

    private func makeRuntime(root: URL, recorder: RuntimeRecorder) -> GitHubCommandRuntime {
        GitHubCommandRuntime(
            dataRoot: root,
            observationLoader: { item in try await recorder.load(item) },
            bridgeSender: { item, intent, payload in
                try await recorder.dispatch(item: item, intent: intent, payload: payload)
            },
            notificationSender: { intent in try await recorder.notify(intent) },
            outcomeObserver: { model in await recorder.recordOutcome(model) }
        )
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

private actor RuntimeRecorder {
    enum ProbeError: Error { case missingObservation }

    private var observation: GitHubCommandObservation?
    private var readItemIds: [String] = []
    private var sentPayloads: [String] = []
    private var sentDispatchIds: [String] = []
    private var sentNotifications: [GitHubCommandNotificationIntent] = []
    private var motorOutcomes: [MotorActionReadModel] = []

    init(observation: GitHubCommandObservation? = nil) {
        self.observation = observation
    }

    func load(_ item: GitHubCommandItem) throws -> GitHubCommandObservation {
        readItemIds.append(item.itemId)
        guard let observation else { throw ProbeError.missingObservation }
        return observation
    }

    func dispatch(
        item: GitHubCommandItem,
        intent: GitHubCommandDispatchIntent,
        payload: String
    ) -> GitHubCommandDispatchReceipt {
        sentPayloads.append(payload)
        sentDispatchIds.append(intent.dispatchId)
        return GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
    }

    func notify(_ intent: GitHubCommandNotificationIntent) -> (String, String) {
        sentNotifications.append(intent)
        return ("accepted", "test receipt")
    }

    func recordOutcome(_ model: MotorActionReadModel) { motorOutcomes.append(model) }

    func payloads() -> [String] { sentPayloads }
    func dispatchIds() -> [String] { sentDispatchIds }
    func observationReads() -> [String] { readItemIds }
    func notifications() -> [GitHubCommandNotificationIntent] { sentNotifications }
    func outcomes() -> [MotorActionReadModel] { motorOutcomes }
}
