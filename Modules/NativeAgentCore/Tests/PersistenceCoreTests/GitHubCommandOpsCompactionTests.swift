import Foundation
import Testing
@testable import PersistenceCore

/// Audit round 2, F1: the op-log grew without bound (15.9k ops in 6 days)
/// and every write replayed all of it. Compaction snapshots the reduced state
/// (INCLUDING the dispatched at-most-once ledger) and truncates the feed.
/// These tests pin: semantic equivalence with an uncompacted store, feed
/// boundedness, at-most-once survival across compaction, and continued
/// operation (second compaction) afterwards.
@Suite("GitHubCommand ops compaction", .serialized)
struct GitHubCommandOpsCompactionTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-command-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func actionable(_ version: String, number: Int = 11) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets",
            number: number,
            kind: .pullRequest,
            title: "Repair widget \(number)",
            isOpen: true,
            observedVersion: "observed-\(version)",
            actionableEventVersion: version,
            signals: [.reviewComment],
            headSHA: "abc123",
            waitingKind: .review
        )
    }

    private func quiet(number: Int = 11) -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets",
            number: number,
            kind: .pullRequest,
            title: "Repair widget \(number)",
            isOpen: true,
            observedVersion: "observed-quiet-\(number)",
            actionableEventVersion: nil,
            signals: [],
            headSHA: "abc123",
            waitingKind: .review
        )
    }

    /// Deterministic semantic projection — op UUIDs and wall-clock stamps
    /// differ between runs, but item identity, routing state, settle keys,
    /// claim ledgers, and the dispatched set must not.
    private func fingerprint(_ state: GitHubCommandState) -> [String] {
        var rows = state.items.map { item in
            "\(item.itemId)|\(item.state.name.rawValue)|\(item.lastSettledEventKey ?? "-")|claims:\(item.notificationClaims.count)|receipt:\(item.dispatchReceipt?.eventKey ?? "-")"
        }.sorted()
        rows.append("dispatched:" + state.dispatchedEventKeys.sorted().joined(separator: ","))
        return rows
    }

    /// Drives one identical logical sequence through a store.
    private func drive(_ store: GitHubCommandStore) async throws {
        // Full lifecycle on item 11: actionable → dispatch → callback →
        // quiet settle (stamps lastSettledEventKey, G3).
        _ = try await store.observe(actionable("review-1"))
        let intent = try #require(try await store.prepareDispatch(itemId: actionable("review-1").itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: intent.itemId, receipt: receipt)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "completed",
            summary: "Codex resolved the review thread."
        )
        _ = try await store.observe(quiet())
        // Churn on other items pushes the op count over the small threshold.
        for n in 20...29 {
            _ = try await store.observe(actionable("push-\(n)", number: n))
        }
        // The settled event resurfaces after compaction has happened.
        _ = try await store.observe(actionable("review-1"))
    }

    @Test("compacted store is semantically identical to an uncompacted twin")
    func compactionPreservesSemantics() async throws {
        let rootA = try root(); defer { try? FileManager.default.removeItem(at: rootA) }
        let rootB = try root(); defer { try? FileManager.default.removeItem(at: rootB) }
        let uncompacted = GitHubCommandStore(dataRoot: rootA, changeBus: StoreChangeBus(), opsCompactionThreshold: 1_000_000)
        let compacted = GitHubCommandStore(dataRoot: rootB, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)

        try await drive(uncompacted)
        try await drive(compacted)

        let stateA = try await uncompacted.liveState()
        let stateB = try await compacted.liveState()
        #expect(fingerprint(stateA) == fingerprint(stateB))

        // The compacted feed is actually bounded and the base exists.
        let opsLinesB = (try? String(contentsOf: compacted.opsPath, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        #expect(opsLinesB < 8)
        #expect(FileManager.default.fileExists(atPath: compacted.basePath.path))
        let opsLinesA = (try? String(contentsOf: uncompacted.opsPath, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        #expect(opsLinesA > 8)
        #expect(!FileManager.default.fileExists(atPath: uncompacted.basePath.path))
    }

    @Test("dispatched at-most-once ledger and settle stamp survive compaction")
    func atMostOnceSurvivesCompaction() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)
        try await drive(store)

        // drive() ends by re-observing the SETTLED eventKey after compaction:
        // the item must stay settled (no bounce, G3 stamp survived the base)
        // and must not be dispatch-eligible (at-most-once ledger survived).
        let state = try await store.liveState()
        let item = try #require(state.item(actionable("review-1").itemId))
        #expect(item.state == .waitingUpstream(.review))
        #expect(item.lastSettledEventKey != nil)
        #expect(try await store.prepareDispatch(itemId: item.itemId) == nil)
    }

    @Test("a corrupt base file fails loud instead of replaying a truncated feed from empty")
    func corruptBaseFailsLoud() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)
        try await drive(store)
        #expect(FileManager.default.fileExists(atPath: store.basePath.path))

        // Corrupt the base after compaction has truncated the op-log.
        try Data("{not json".utf8).write(to: store.basePath)
        await #expect(throws: (any Error).self) {
            _ = try await store.liveState()
        }
    }

    @Test("a writer holding the flock fails loud on a corrupt pairing instead of wedging")
    func writerCorruptPairingFailsLoudNotWedged() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)
        try await drive(store)
        #expect(FileManager.default.fileExists(atPath: store.basePath.path))

        // Empty the op-log while the base survives: no pairing proof can ever
        // succeed (lastCompactedOpId absent, no head to match tailFirstOpId).
        try Data().write(to: store.opsPath)

        // The write path reads the feed UNDER the ops flock. Before the
        // readFeedLocked split, a failed pairing fell into readFeedUnlocked's
        // flock fallback — withFileLock is not reentrant, so the writer spun
        // on its own lock forever. Bound the await so a regression fails
        // loudly instead of hanging the suite; cancellation unwinds the spin
        // (its retry sleep is cancellable), so no task leaks either way.
        let observation = actionable("post-corruption")
        let outcome: Bool? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do { _ = try await store.observe(observation); return false }
                catch { return true }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(outcome == true, "writer must throw on a corrupt (base, ops) pairing — not succeed, not wedge")
    }

    @Test("compaction keeps a recent-evidence tail, not an empty feed")
    func compactionKeepsEvidenceTail() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)
        try await drive(store)

        // threshold 8 → tail keep = 2: the op-log holds recent ops, and the
        // causal-evidence projection still sees post-compaction transitions
        // (review round 2, finding 4: an empty feed blanked recent evidence).
        let opsLines = (try? String(contentsOf: store.opsPath, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        #expect(opsLines > 0, "tail must survive compaction")
        let evidence = try await store.causalTransitionEvidence(limit: 16)
        #expect(!evidence.isEmpty, "recent causal evidence must survive compaction")
    }

    @Test("the store keeps operating and compacts again after the first compaction")
    func secondCompactionWorks() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root, changeBus: StoreChangeBus(), opsCompactionThreshold: 8)
        try await drive(store)
        let baseAfterFirst = try Data(contentsOf: store.basePath)

        // Another churn wave crosses the threshold again.
        for n in 40...49 {
            _ = try await store.observe(actionable("wave2-\(n)", number: n))
        }
        let state = try await store.liveState()
        #expect(state.items.count >= 21)
        let baseAfterSecond = try Data(contentsOf: store.basePath)
        #expect(baseAfterFirst != baseAfterSecond)
        let opsLines = (try? String(contentsOf: store.opsPath, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        #expect(opsLines < 8)
    }
}
