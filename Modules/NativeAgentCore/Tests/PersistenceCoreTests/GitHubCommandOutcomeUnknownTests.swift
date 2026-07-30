import Foundation
import Testing
@testable import PersistenceCore

@Suite("GitHubCommand outcome-unknown callbacks")
struct GitHubCommandOutcomeUnknownTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-command-outcome-unknown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func observation() -> GitHubCommandObservation {
        GitHubCommandObservation(
            repository: "example/widgets",
            number: 7,
            kind: .pullRequest,
            title: "Repair the widget",
            isOpen: true,
            observedVersion: "observed-review-1",
            actionableEventVersion: "review-1",
            signals: [.reviewComment],
            headSHA: "abc123",
            waitingKind: .review
        )
    }

    @Test("empty terminal callback parks without automatic replay")
    func emptyCallbackDoesNotReplay() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation())
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "completed_without_reply",
            summary: "Codex accepted the turn but returned no final assistant reply."
        )

        let parked = try await store.observe(observation())
        #expect(parked.state == .attention(.codexFailed))
        #expect(parked.blocker?.detail.contains("did not replay") == true)
        #expect(try await store.prepareDispatch(itemId: item.itemId) == nil)

        // The park never auto-replays, so it MUST page User — exactly once.
        // (Audit round 2, G1: codexFailed was the only stuck state that
        // neither retried nor notified.)
        let claimed = try await store.claimPendingNotifications()
        #expect(claimed.count == 1)
        #expect(claimed.first?.itemId == item.itemId)
        #expect(claimed.first?.kind == .blocker)
        #expect(try await store.claimPendingNotifications().isEmpty)
    }

    @Test("codexFailed page is deduped across re-observations of the same event")
    func codexFailedPageIsDedupedAcrossObservations() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubCommandStore(dataRoot: root)
        let item = try await store.observe(observation())
        let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
        let receipt = GitHubCommandDispatchReceipt(
            eventKey: intent.eventKey,
            dispatchId: intent.dispatchId,
            messageId: intent.dispatchId,
            queuedAt: DeskClock.nowISO()
        )
        _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
        _ = try await store.recordCallback(
            messageIds: [receipt.messageId],
            codexStatus: "failed",
            summary: "Codex turn failed."
        )
        _ = try await store.observe(observation())
        #expect(try await store.claimPendingNotifications().count == 1)

        // The same unchanged event re-observed on later refreshes must not
        // page again, and must still refuse a replay.
        _ = try await store.observe(observation())
        #expect(try await store.claimPendingNotifications().isEmpty)
        #expect(try await store.prepareDispatch(itemId: item.itemId) == nil)
    }

    @Test("legacy codex_busy snapshot state is decodable but not dispatchable")
    func legacyBusyStateDoesNotDispatch() async throws {
        let encoded = Data(#"{"name":"attention","reason":"codex_busy"}"#.utf8)
        let state = try JSONDecoder().decode(GitHubCommandItemState.self, from: encoded)
        #expect(state == .attention(.codexBusy))
        #expect(!state.isDispatchPending)
    }
}
