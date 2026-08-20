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

    @Test("actionable GitHub state notifies once and never creates a dispatch")
    func actionableNotifiesWithoutDispatch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let recorder = RuntimeRecorder()
        let runtime = makeRuntime(root: root, recorder: recorder)
        await runtime.replayResidentStateAtLaunch()
        let item = try await store.observe(actionable())

        await runtime.processConnectorChanges()

        let watched = try #require(try await store.liveState().item(item.itemId))
        #expect(watched.state == .needsCodex)
        #expect(watched.dispatchIntent == nil)
        #expect(watched.dispatchReceipt == nil)
        let notifications = await recorder.notifications()
        #expect(notifications.count == 1)
        #expect(notifications.first?.kind == .actionable)
        #expect(notifications.first?.title == "GitHub needs attention")
        let outcomes = await recorder.outcomes()
        #expect(outcomes.contains { $0.phase == .ready })

        let countBeforeNoOpRefresh = outcomes.count
        _ = try await store.observe(actionable())
        await runtime.processConnectorChanges()
        #expect(await recorder.outcomes().count == countBeforeNoOpRefresh)
        #expect(await recorder.notifications().count == 1)
    }

    @Test("restart refreshes actionable watcher state without resuming a reserved dispatch")
    func restartRecoveryIsWatcherOnly() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable(version: "ci-head-a"))
        let beforeCrash = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let recorder = RuntimeRecorder(observation: actionable(version: "ci-head-a"))
        let runtime = makeRuntime(root: root, recorder: recorder)

        await runtime.recoverAtLaunch()

        #expect(await recorder.observationReads() == [item.itemId])
        let recovered = try #require(try await GitHubCommandStore(dataRoot: root).liveState().item(item.itemId))
        #expect(recovered.state == .needsCodex)
        #expect(recovered.dispatchIntent?.dispatchId == beforeCrash.dispatchId)
        #expect(recovered.dispatchReceipt == nil)
        #expect(await recorder.notifications().first?.kind == .actionable)
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
    }

    @Test("callback re-reads GitHub, resolves, and emits one terminal notification")
    func callbackVerificationAndTerminalNotification() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(actionable())
        let messageId = try await seedLegacyDispatch(store: store, itemId: item.itemId).messageId

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
        let messageId = try await seedLegacyDispatch(store: store, itemId: item.itemId).messageId

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
            notificationSender: { intent in try await recorder.notify(intent) },
            outcomeObserver: { model in await recorder.recordOutcome(model) }
        )
    }

    private func seedLegacyDispatch(
        store: GitHubCommandStore,
        itemId: String
    ) async throws -> GitHubCommandDispatchReceipt {
        let intent = try #require(try await store.prepareDispatch(itemId: itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: itemId, receipt: receipt)
        return receipt
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
    private var sentNotifications: [GitHubCommandNotificationIntent] = []
    private var motorOutcomes: [MotorActionReadModel] = []
    private let failObservationReads: Bool

    init(
        observation: GitHubCommandObservation? = nil,
        failObservationReads: Bool = false
    ) {
        self.observation = observation
        self.failObservationReads = failObservationReads
    }

    func load(_ item: GitHubCommandItem) throws -> GitHubCommandObservation {
        readItemIds.append(item.itemId)
        if failObservationReads { throw ProbeError.missingObservation }
        if let observation { return observation }
        guard let current = item.observation else { throw ProbeError.missingObservation }
        return current
    }

    func notify(_ intent: GitHubCommandNotificationIntent) -> (String, String) {
        sentNotifications.append(intent)
        return ("accepted", "test receipt")
    }

    func recordOutcome(_ model: MotorActionReadModel) { motorOutcomes.append(model) }

    func observationReads() -> [String] { readItemIds }
    func notifications() -> [GitHubCommandNotificationIntent] { sentNotifications }
    func outcomes() -> [MotorActionReadModel] { motorOutcomes }
}
