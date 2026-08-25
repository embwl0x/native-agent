import Foundation
import Testing
@testable import MemoryV2

/// Eval for ledger surface `memory.api.listProposals`
/// (docs/evals/ledger.json, fence core.memory).
///
/// Silent-failure class: wrong value / stale queue. "List the proposals" has
/// TWO spellings with DIFFERENT defaults:
///   * `MemoryStorage.listProposals(status:)` defaults to `"pending"` — the
///     review queue (MemoryV2+Storage.swift:1924);
///   * `SwiftNativeMemoryV2.listProposals(status:)` defaults to `nil` — every
///     row ever staged, rejected ones included (MemoryV2+Wiring.swift:1053).
/// On the live root that is the difference between a queue of a handful and a
/// list of hundreds, most of them already rejected. No test asserted EITHER
/// default, so a caller that relies on the default gets whichever set the layer
/// it happened to reach decided on, and a change to either default is invisible.
///
/// This eval pins the two defaults against each other on one populated store,
/// and pins the ordering the review queue depends on (newest staged first).
/// The instrument-tier half of the proposed eval — is the pending queue's newest
/// `staged_at` inside the window that saw memory writes, i.e. is the staging
/// lane still ALIVE — is live-readonly and lives outside this fence; see the
/// BUILD report.
@Suite("MemoryV2 listProposals default scope")
struct ListProposalsDefaultScopeTests {

    private func makeTempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memv2-proposals-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Two pending rows, one approved, one rejected — a miniature of the live
    /// queue's shape (a small live set inside a much larger resolved history).
    private func populate(_ storage: MemoryStorage) async throws {
        _ = try await storage.insertProposal(StoredProposal(
            id: "pending-old", content: "an older staged claim",
            stagedAt: "2026-08-01T00:00:00Z", status: "pending"
        ))
        _ = try await storage.insertProposal(StoredProposal(
            id: "pending-new", content: "a newer staged claim",
            stagedAt: "2026-08-20T00:00:00Z", status: "pending"
        ))
        _ = try await storage.insertProposal(StoredProposal(
            id: "approved-1", content: "a claim that was accepted",
            stagedAt: "2026-07-01T00:00:00Z", status: "approved"
        ))
        _ = try await storage.insertProposal(StoredProposal(
            id: "rejected-1", content: "a claim that was refused",
            stagedAt: "2026-06-01T00:00:00Z", status: "rejected"
        ))
    }

    @Test("the storage default is the pending queue; the facade default is everything")
    func theTwoDefaultsAreDistinctAndBothPinned() async throws {
        let root = try makeTempRoot("defaults")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        try await populate(storage)
        let facade = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 8),
            storage: MemoryStorageBridge(storage: storage)
        )

        // Storage default == the REVIEW QUEUE. The consolidator's drain loop and
        // the human review surface both depend on this being pending-only.
        let storageDefault = try await storage.listProposals()
        #expect(Set(storageDefault.map(\.id)) == ["pending-old", "pending-new"],
                "MemoryStorage.listProposals() no longer defaults to the pending queue")
        #expect(storageDefault.allSatisfy { $0.status == "pending" })

        // Facade default == EVERY row, resolved history included. Different
        // set, deliberately — pinning it means a silent narrowing (which would
        // empty the admin/history surfaces) fails here.
        let facadeDefault = try await facade.listProposals()
        #expect(Set(facadeDefault.map(\.id))
                == ["pending-old", "pending-new", "approved-1", "rejected-1"],
                "SwiftNativeMemoryV2.listProposals() no longer defaults to the full history")
        #expect(facadeDefault.count > storageDefault.count,
                "the two 'list the proposals' defaults collapsed to the same set")

        // The explicit spelling agrees across both layers, so a caller that
        // states its scope gets the same answer wherever it enters.
        let facadePending = try await facade.listProposals(status: "pending")
        #expect(Set(facadePending.map(\.id)) == Set(storageDefault.map(\.id)))
    }

    @Test("the pending queue is ordered newest-staged first")
    func pendingQueueIsNewestFirst() async throws {
        let root = try makeTempRoot("order")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        try await populate(storage)

        // The review surface and the drain loop both read the head of this
        // list; a flipped order silently makes them work the oldest backlog
        // first and never reach today's proposals under a bound.
        #expect(try await storage.listProposals().map(\.id) == ["pending-new", "pending-old"])

        let all = try await storage.listProposals(status: nil).map(\.stagedAt)
        #expect(all == all.sorted(by: >), "listProposals(status: nil) is not newest-first")
    }

    @Test("an unknown status is an empty queue, never a silent full list")
    func unknownStatusReturnsEmptyNotEverything() async throws {
        let root = try makeTempRoot("unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        try await populate(storage)

        // A typo'd or renamed status must NOT fall through to "no filter" —
        // that would present rejected claims as the review queue.
        #expect(try await storage.listProposals(status: "Pending").isEmpty)
        #expect(try await storage.listProposals(status: "queued").isEmpty)
    }
}
