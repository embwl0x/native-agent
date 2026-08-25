import Foundation
import Testing
@testable import PersistenceCore

// EVAL FENCE: core.workshop / workshop.githubCommand.feeds
//
// Exercises the real append-only command store, its dispatch receipts, replay
// reader, compaction base/tail family, and adverse on-disk states. A queued
// bridge request is acceptance evidence only: GitHub verification remains the
// later external-effect boundary.

@Suite("GitHub Command feed family")
struct GitHubCommandFeedFamilyEvalTests {
    private func root(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-command-feed-family-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func actionable(number: Int, version: String) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/workshop",
            number: number,
            kind: .pullRequest,
            title: "Repair feed \(number)",
            isOpen: true,
            observedVersion: "observed-\(version)",
            actionableEventVersion: version,
            signals: [.reviewComment],
            headSHA: "head-\(number)",
            waitingKind: .review
        )
    }

    @Test("command feeds preserve acceptance, refusal, failure, compaction, and honest adverse reads")
    func commandReceiptReadBoundariesRemainTruthful() async throws {
        let dataRoot = try root("primary")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let otherRoot = try root("other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let store = GitHubCommandStore(
            dataRoot: dataRoot,
            changeBus: StoreChangeBus(),
            opsCompactionThreshold: 8
        )

        let acceptedSeed = try await store.observe(actionable(number: 1, version: "review-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: acceptedSeed.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        let accepted = try await store.recordDispatchSuccess(itemId: intent.itemId, receipt: receipt)

        // An accepted `codex_message` is not an external GitHub effect. The
        // real read model keeps the work waiting for callback + GitHub proof.
        #expect(accepted.state == .codexWorking)
        #expect(accepted.dispatchReceipt == receipt)
        let acceptedMotor = try #require(try await store.motorActionReadModel(actionId: intent.itemId))
        #expect(acceptedMotor.phase == .waitingExternal)
        #expect(acceptedMotor.verification == .notStarted)
        #expect(acceptedMotor.expectedNextEvidence == "codex_callback")

        // A duplicate command while the first one is active is a refusal, not
        // a second API attempt or a quietly fabricated success receipt.
        let opsBeforeRefusal = try Data(contentsOf: store.opsPath)
        #expect(try await store.prepareDispatch(itemId: intent.itemId) == nil)
        #expect(try Data(contentsOf: store.opsPath) == opsBeforeRefusal)

        let failedSeed = try await store.observe(actionable(number: 2, version: "review-2"))
        let failedIntent = try #require(try await store.prepareDispatch(itemId: failedSeed.itemId))
        let failed = try await store.recordDispatchFailure(
            itemId: failedSeed.itemId,
            eventKey: failedIntent.eventKey,
            detail: "bridge rejected the request"
        )
        #expect(failed.state == .attention(.dispatchFailed))
        #expect(failed.dispatchReceipt == nil)
        #expect(failed.workLog.last?.kind == "dispatch_failed")

        // Cross the compaction threshold through the public store API. The
        // base snapshot must retain a structural replay root while the tail
        // remains bounded; the other injected root stays entirely untouched.
        for number in 3...12 {
            _ = try await store.observe(actionable(number: number, version: "review-\(number)"))
        }
        #expect(FileManager.default.fileExists(atPath: store.basePath.path))
        let baseData = try Data(contentsOf: store.basePath)
        let baseObject = try #require(
            try JSONSerialization.jsonObject(with: baseData) as? [String: Any]
        )
        #expect(Set(["state", "lastCompactedOpId", "compactedAt", "compactedOpCount", "tailFirstOpId"])
            .isSubset(of: Set(baseObject.keys)))
        let tailRows = try String(contentsOf: store.opsPath, encoding: .utf8)
            .split(separator: "\n").count
        #expect(tailRows < 8)
        #expect(try await store.liveState().item(intent.itemId)?.dispatchReceipt == receipt)
        #expect(try await GitHubCommandStore(dataRoot: otherRoot).liveState().items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: otherRoot.appendingPathComponent("workshop/github_command/ops.jsonl").path))

        // An optional base is absent before the first compaction, not silently
        // interpreted as a zero-item snapshot. A torn last line is explicitly
        // reported as an append-in-flight while the complete prefix remains
        // readable; it never masquerades as a clean feed.
        let partialRoot = try root("pre-compaction")
        defer { try? FileManager.default.removeItem(at: partialRoot) }
        let partialStore = GitHubCommandStore(dataRoot: partialRoot, changeBus: StoreChangeBus())
        _ = try await partialStore.observe(actionable(number: 99, version: "review-99"))
        #expect(FileManager.default.fileExists(atPath: partialStore.opsPath.path))
        #expect(FileManager.default.fileExists(atPath: partialStore.statePath.path))
        #expect(!FileManager.default.fileExists(atPath: partialStore.basePath.path))
        #expect(try await partialStore.liveState().items.count == 1)
        let tornAppend = try FileHandle(forWritingTo: partialStore.opsPath)
        try tornAppend.seekToEnd()
        try tornAppend.write(contentsOf: Data("{torn append".utf8))
        try tornAppend.close()
        #expect(try await partialStore.liveState().items.count == 1)
        let partialHealth = try await partialStore.opLogHealth()
        #expect(partialHealth.integrity.trailingPartialLine)
        #expect(partialHealth.status == .warn)

        let unavailableRoot = try root("unavailable")
        defer { try? FileManager.default.removeItem(at: unavailableRoot) }
        let unavailableStore = GitHubCommandStore(dataRoot: unavailableRoot, changeBus: StoreChangeBus())
        try FileManager.default.createDirectory(
            at: unavailableStore.basePath,
            withIntermediateDirectories: true
        )
        await #expect(throws: GitHubCommandStoreError.baseUnreadable(unavailableStore.basePath.path)) {
            _ = try await unavailableStore.liveState()
        }

        let malformedRoot = try root("malformed")
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        let malformedStore = GitHubCommandStore(dataRoot: malformedRoot, changeBus: StoreChangeBus())
        try FileManager.default.createDirectory(
            at: malformedStore.opsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not-json}\n".utf8).write(to: malformedStore.opsPath)
        await #expect(throws: GitHubCommandStoreError.malformedOperation) {
            _ = try await malformedStore.liveState()
        }
        let malformedIntegrity = try await malformedStore.opLogIntegrity()
        #expect(malformedIntegrity.malformedLineCount == 1)
        #expect((try await malformedStore.opLogHealth()).status == .blocked)
    }
}
