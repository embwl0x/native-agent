import DreamREMCycle
import Foundation
import Testing

@testable import NativeAgentApp

/// LAUNCH CATCH-UP FOR UNSTAGED REM ROWS (Astra audit 2026-09-11, finding 9).
///
/// Staging used to happen only inside the weekly REM job, so five 2026-09-06
/// proposals sat in `rem_proposals.jsonl` with `approvalId: null` waiting six
/// days for a card. The catch-up stages them through the same owner, generates
/// no REM batch, bounds how many cards one pass can produce, and is idempotent.
@Suite("REM staging catch-up")
struct REMStagingCatchUpTests {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rem-staging-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func proposal(_ index: Int) -> REMProposal {
        REMProposal(
            id: "catchup-\(index)",
            targetDoc: "GROWTH.md",
            proposalText: "A lesson the weekly job appended but never staged (\(index)).",
            evidenceDates: ["2026-09-06"],
            confidence: 0.8,
            createdAt: "2026-09-06T09:30:00Z"
        )
    }

    @Test("unstaged pending rows are staged once, bounded, and never re-staged")
    func catchUpStagesTheBacklogOnceUnderItsBound() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = REMProposalStore(dataRoot: root)
        let appended = try await store.appendPending((1...5).map(proposal))
        #expect(appended == 5)

        let firstRecorder = StagerRecorder()
        let firstCount = await BackgroundLoopsAssembly.stagePendingREMProposalsAtLaunch(
            dataRoot: root,
            limit: 3,
            stager: { row in await firstRecorder.stamp(row.id) }
        )
        let firstIds = await firstRecorder.ids
        // BOUNDED: only three cards from one pass, even with five waiting.
        #expect(firstCount == 3)
        #expect(firstIds.count == 3)
        let afterFirst = store.loadAll().filter { $0.approvalId != nil }
        #expect(afterFirst.count == 3)

        // IDEMPOTENT: the second pass sees only what is still unstamped.
        let recorder = StagerRecorder()
        let second = await BackgroundLoopsAssembly.stagePendingREMProposalsAtLaunch(
            dataRoot: root,
            limit: 10,
            stager: { row in await recorder.stamp(row.id) }
        )
        #expect(second == 2)
        #expect(Set(await recorder.ids).isDisjoint(with: Set(firstIds)),
                "a stamped row must never be staged a second time")
        #expect(store.loadAll().allSatisfy { $0.approvalId != nil })

        // Nothing left: the pass is a no-op and stages no card at all.
        let third = await BackgroundLoopsAssembly.stagePendingREMProposalsAtLaunch(
            dataRoot: root,
            limit: 10,
            stager: { _ in "never-used" }
        )
        #expect(third == 0)
    }
}

private actor StagerRecorder {
    var ids: [String] = []

    func stamp(_ id: String) -> String? {
        ids.append(id)
        return "approval-\(id)"
    }
}
