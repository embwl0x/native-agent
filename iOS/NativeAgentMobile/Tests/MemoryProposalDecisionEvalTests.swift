import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.memory.proposalDecide`.
@MainActor
final class MemoryProposalDecisionEvalTests: XCTestCase {
    func test_timeoutRestoresAnUnresolvedProposalWhenTheNextSnapshotStillListsIt() async throws {
        let proposal = try makeProposal(id: "proposal-timeout")
        let store = MemoryStore()
        store.applySyncedState(memories: [], memoryProposals: [proposal])

        await store.performMemoryProposalDecision(
            proposal,
            approve: true,
            submit: { _, _ in
                throw SyncError.timeout("Timed out waiting for Mac response to proposal-timeout")
            },
            refresh: {
                store.applySyncedState(memories: [], memoryProposals: [proposal])
            }
        )

        XCTAssertEqual(store.memoryProposals.map(\.id), [proposal.id])
        XCTAssertTrue(store.decidingMemoryProposalIDs.isEmpty)
        XCTAssertEqual(store.error, "Decision sent; waiting for Mac/iCloud to publish the result.")
    }

    private func makeProposal(id: String) throws -> MemoryProposalRecord {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "text": "Remember this only after a confirmed decision.",
            "status": "pending",
            "supporting_session_ids": ["session-eval"],
            "recurrence_count": 1,
        ])
        return try JSONDecoder().decode(MemoryProposalRecord.self, from: data)
    }
}
