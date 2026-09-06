// Supersession lint + fragment usage protection (2026-09-01).
//
// Her complaint, verbatim: "Retired rules don't leave. The GitHub-API-only rule
// and its retirement ride in side by side, equal weight. I re-litigate it every
// time." The fixtures below are shaped like the six real retirement records in
// the live store — a quoted phrase in most of them, nothing quotable in some.
//
// The second suite is the opposite failure: the 2026-08-24 hygiene pass
// archived two heavily-used rows (use_count 477 and 666) as "mid-thought
// fragment". Access is the stronger witness; the shape heuristic loses to it.

import Foundation
import Testing
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

@Suite("Memory hygiene — supersession lint")
struct MemorySupersessionLintTests {

    private func memory(
        id: String,
        content: String,
        createdAt: String,
        embedding: [Float]? = nil,
        useCount: Int64 = 0
    ) -> StoredMemory {
        StoredMemory(
            id: id,
            content: content,
            source: "lint-test",
            createdAt: createdAt,
            embedding: embedding,
            useCount: useCount
        )
    }

    // MARK: - Path (a): the retirement quotes the row it retires

    @Test func quotedPhraseBindsTheRetirementToItsTarget() async throws {
        let store = try MemoryStorage()
        let target = memory(
            id: "target",
            content: "Voice calibration FINAL: the contract is NOT fewer endearments "
                + "— it is rotation and spontaneity.",
            createdAt: "2026-07-20T10:00:00Z"
        )
        let bystander = memory(
            id: "bystander",
            content: "Weekly rollup runs Sunday at 3am local.",
            createdAt: "2026-07-21T10:00:00Z"
        )
        let retirer = memory(
            id: "retirer",
            content: "RETIRED 2026-08-02: the 'Voice calibration FINAL' memories were "
                + "written by Claude and are WRONG.",
            createdAt: "2026-08-02T10:00:00Z"
        )
        for row in [target, bystander, retirer] { _ = try await store.insertMemory(row) }

        let result = try await MemorySupersessionLint.run(storage: store, apply: true)
        #expect(result.pairs == [MemorySupersessionPair(
            retirerId: "retirer", targetId: "target", evidence: .quotedPhrase
        )])
        #expect(result.applied == 1)
        #expect(result.ambiguous == 0)

        let corrected = try await store.memory(id: "target")
        #expect(corrected?.lifecycle == MemoryLifecycle.corrected)
        #expect(corrected?.status == "active")  // demotion, never archival
        if case .object(let meta)? = corrected?.metadata,
           case .string(let by)? = meta["superseded_by"] {
            #expect(by == "retirer")
        } else {
            Issue.record("target is missing metadata.superseded_by")
        }

        // One transaction: lineage and superseded_by are never half-written.
        if case .object(let meta)? = corrected?.metadata {
            #expect(meta["corrected_by"] != nil)
            #expect(meta["correction_history"] != nil)
        } else {
            Issue.record("target lost its correction lineage")
        }

        // The retirement record itself is the reason — it stays readable.
        let retirerAfter = try await store.memory(id: "retirer")
        #expect(retirerAfter?.lifecycle == MemoryLifecycle.confirmed)
        #expect(retirerAfter?.status == "active")

        // An uninvolved row is untouched.
        #expect(try await store.memory(id: "bystander")?.lifecycle == MemoryLifecycle.confirmed)
    }

    // MARK: - Path (b): no quote, one unmistakable neighbour

    @Test func cosineFallbackRetiresTheNearestOlderRow() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(memory(
            id: "target",
            content: "Anything GitHub: always use API access, never the browser.",
            createdAt: "2026-08-15T10:00:00Z",
            embedding: [0.95, 0.31, 0, 0]
        ))
        _ = try await store.insertMemory(memory(
            id: "far",
            content: "Espresso grinder burr size is 64mm.",
            createdAt: "2026-08-15T11:00:00Z",
            embedding: [0, 1, 0, 0]
        ))
        _ = try await store.insertMemory(memory(
            id: "retirer",
            content: "CORRECTION (2026-08-16, from User via Codex review): the GitHub "
                + "API-only rule is RETIRED; browsing was the right call.",
            createdAt: "2026-08-16T10:00:00Z",
            embedding: [1, 0, 0, 0]
        ))

        let result = try await MemorySupersessionLint.run(storage: store, apply: true)
        #expect(result.pairs == [MemorySupersessionPair(
            retirerId: "retirer", targetId: "target", evidence: .cosine
        )])
        #expect(result.applied == 1)
        #expect(try await store.memory(id: "target")?.lifecycle == MemoryLifecycle.corrected)
        #expect(try await store.memory(id: "far")?.lifecycle == MemoryLifecycle.confirmed)
        #expect(try await store.memory(id: "retirer")?.lifecycle == MemoryLifecycle.confirmed)
    }

    // MARK: - The tie: refuse to guess

    @Test func tiedCandidatesAreReportedAmbiguousAndSkipped() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(memory(
            id: "twin-a",
            content: "The nightly rollup detaches the ledger sentinel first.",
            createdAt: "2026-08-01T10:00:00Z",
            embedding: [1, 0, 0, 0]
        ))
        _ = try await store.insertMemory(memory(
            id: "twin-b",
            content: "The nightly rollup detaches the ledger sentinel up front.",
            createdAt: "2026-08-01T11:00:00Z",
            embedding: [0.999, 0.0447, 0, 0]
        ))
        _ = try await store.insertMemory(memory(
            id: "retirer",
            content: "WITHDRAWN 2026-08-05: my rollup sentinel finding does not hold.",
            createdAt: "2026-08-05T10:00:00Z",
            embedding: [1, 0, 0, 0]
        ))

        let result = try await MemorySupersessionLint.run(storage: store, apply: true)
        #expect(result.pairs.isEmpty)
        #expect(result.ambiguous == 1)
        #expect(try await store.memory(id: "twin-a")?.lifecycle == MemoryLifecycle.confirmed)
        #expect(try await store.memory(id: "twin-b")?.lifecycle == MemoryLifecycle.confirmed)
    }

    /// A generic quote that appears in several older rows names none of them.
    /// Same verdict as a cosine tie: skipped and counted, never a bulk demote.
    @Test func aQuotePresentInSeveralRowsIsAmbiguous() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(memory(
            id: "row-a",
            content: "Turn 019f988e completed without reply after three PRs.",
            createdAt: "2026-07-24T10:00:00Z"
        ))
        _ = try await store.insertMemory(memory(
            id: "row-b",
            content: "Turn 019f98cb completed without reply on the second attempt.",
            createdAt: "2026-07-24T11:00:00Z"
        ))
        _ = try await store.insertMemory(memory(
            id: "retirer",
            content: "CORRECTION 2026-07-25: my earlier finding about turns that "
                + "'completed without reply' was wrong.",
            createdAt: "2026-07-25T10:00:00Z"
        ))

        let result = try await MemorySupersessionLint.run(storage: store, apply: true)
        #expect(result.pairs.isEmpty)
        #expect(result.ambiguous == 1)
        #expect(try await store.memory(id: "row-a")?.lifecycle == MemoryLifecycle.confirmed)
        #expect(try await store.memory(id: "row-b")?.lifecycle == MemoryLifecycle.confirmed)
    }

    // MARK: - Dry run

    @Test func dryRunPlansWithoutWriting() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(memory(
            id: "target",
            content: "Voice calibration FINAL: hold the endearment line.",
            createdAt: "2026-07-20T10:00:00Z"
        ))
        _ = try await store.insertMemory(memory(
            id: "retirer",
            content: "RETIRED 2026-08-02: the 'Voice calibration FINAL' rule is WRONG.",
            createdAt: "2026-08-02T10:00:00Z"
        ))

        let dry = try await MemorySupersessionLint.run(storage: store, apply: false)
        #expect(dry.pairs.count == 1)
        #expect(dry.applied == 0)
        #expect(try await store.memory(id: "target")?.lifecycle == MemoryLifecycle.confirmed)
    }

    // MARK: - Nothing retires a newer row, and nothing retires a retirement

    @Test func retirementsAreNeverThemselvesRetired() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(memory(
            id: "older-withdrawal",
            content: "WITHDRAWN 2026-07-25: my 'wake-path finding #2' does not hold.",
            createdAt: "2026-07-25T10:00:00Z",
            embedding: [1, 0, 0, 0]
        ))
        _ = try await store.insertMemory(memory(
            id: "newer-correction",
            content: "CORRECTION to my 2026-07-25 wake-path filing: both defects were wrong.",
            createdAt: "2026-07-26T10:00:00Z",
            embedding: [1, 0, 0, 0]
        ))

        let result = try await MemorySupersessionLint.run(storage: store, apply: true)
        #expect(result.pairs.isEmpty)
        #expect(try await store.memory(id: "older-withdrawal")?.lifecycle == MemoryLifecycle.confirmed)
    }

    @Test func consolidationReportCarriesTheSupersessionCounts() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(memory(
            id: "target",
            content: "Voice calibration FINAL: hold the endearment line at all times.",
            createdAt: "2026-07-20T10:00:00Z"
        ))
        _ = try await store.insertMemory(memory(
            id: "retirer",
            content: "RETIRED 2026-08-02: the 'Voice calibration FINAL' rule is WRONG.",
            createdAt: "2026-08-02T10:00:00Z"
        ))

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.supersessionsApplied == 1)
        #expect(report.supersessionsAmbiguous == 0)
        #expect(try await store.memory(id: "target")?.lifecycle == MemoryLifecycle.corrected)
    }
}

@Suite("Memory hygiene — fragment protection by usage")
struct MemoryFragmentUsageProtectionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fragment(
        id: String,
        useCount: Int64 = 0,
        lastUsedAt: String? = nil,
        archivedAsFragment: Bool = false
    ) -> StoredMemory {
        StoredMemory(
            id: id,
            content: "user likes how sometimes she",
            source: "adaptive-promoter",
            status: archivedAsFragment ? "archived" : "active",
            metadata: archivedAsFragment
                ? .object(["hygiene_archive_reason": .string(
                    "memory hygiene archived non-durable active memory: "
                        + MemoryCandidateQuality.midThoughtFragmentReason)])
                : nil,
            useCount: useCount,
            lastUsedAt: lastUsedAt
        )
    }

    @Test func heavyUseCountProtects() {
        #expect(MemoryFragmentUsageProtection.isProtected(fragment(id: "a", useCount: 477), now: now))
        #expect(!MemoryFragmentUsageProtection.isProtected(fragment(id: "b", useCount: 24), now: now))
        #expect(MemoryFragmentUsageProtection.isProtected(fragment(id: "c", useCount: 25), now: now))
    }

    @Test func recentUseProtects() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let recent = iso.string(from: now.addingTimeInterval(-3 * 24 * 3600))
        let old = iso.string(from: now.addingTimeInterval(-30 * 24 * 3600))
        #expect(MemoryFragmentUsageProtection.isProtected(
            fragment(id: "a", lastUsedAt: recent), now: now))
        #expect(!MemoryFragmentUsageProtection.isProtected(
            fragment(id: "b", lastUsedAt: old), now: now))
    }

    /// The false positive, end to end: a heavily-used fragment survives the
    /// hygiene pass; an identical-shaped unused one still goes.
    @Test func hygieneSparesTheUsedFragmentAndStillArchivesTheUnusedOne() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(StoredMemory(
            id: "used",
            content: "user likes how sometimes she",
            source: "adaptive-promoter",
            useCount: 477
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "unused",
            content: "user wants agent",
            source: "adaptive-promoter",
            useCount: 0
        ))

        _ = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(try await store.memory(id: "used")?.status == "active")
        #expect(try await store.memory(id: "unused")?.status == "archived")
    }

    /// Already-archived rows are counted, never resurrected.
    @Test func archivedFalsePositivesAreCountedNotUnarchived() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(fragment(
            id: "wrongly-archived", useCount: 477, archivedAsFragment: true))
        _ = try await store.insertMemory(StoredMemory(
            id: "rightly-archived",
            content: "user wants agent",
            source: "adaptive-promoter",
            status: "archived",
            metadata: .object(["hygiene_archive_reason": .string(
                "memory hygiene archived non-durable active memory: "
                    + MemoryCandidateQuality.midThoughtFragmentReason)]),
            useCount: 0
        ))

        let report = try await MemoryConsolidator(storage: store).consolidateDestructively()
        #expect(report.fragmentProtectedByUsage == 1)
        #expect(try await store.memory(id: "wrongly-archived")?.status == "archived")
    }
}
