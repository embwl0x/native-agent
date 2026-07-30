// U3 wave-2 item 5 tests (2026-06-10):
//   - write-time kind stamping: every new write carries metadata.kind, caller
//     signals win, the default is semantics-neutral;
//   - approval-gated kind backfill: staging mutates nothing, apply-on-approve
//     writes kinds with stale guards.

import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// MARK: - Fixtures

/// Capture box for the injected approval-create closure.
private actor ApprovalCapture {
    private(set) var bodies: [JSONValue] = []
    func record(_ body: JSONValue) -> String {
        bodies.append(body)
        return "appr-test-\(bodies.count)"
    }
}

private func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("u3w2-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func readJSONLEntries(_ url: URL) throws -> [JSONValue] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let raw = try String(contentsOf: url, encoding: .utf8)
    return raw.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .compactMap { try? JSONValue.parse(Data($0.utf8)) }
}

private func str(_ obj: JSONValue, _ key: String) -> String? {
    guard case .object(let o) = obj, case .string(let s)? = o[key] else { return nil }
    return s
}

// MARK: - Item 5a: write-time kind stamping

@Suite("KindStamp")
struct KindStampTests {

    @Test func storeStampsSemanticsNeutralDefault() async throws {
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        let rec = try await memory.store(content: "kindless write")
        #expect(MemoryKindStamp.kind(of: rec.extras) == "general")
        #expect(MemoryKindStamp.kindSource(of: rec.extras) == "write_default_v1")
    }

    @Test func storeHonorsCallerKind() async throws {
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        let rec = try await memory.store(
            content: "caller-signal write",
            metadata: .object(["kind": .string("preference"), "confidence": .double(0.8)]))
        #expect(MemoryKindStamp.kind(of: rec.extras) == "preference")
        // Caller signal: untouched, no machine provenance marker.
        #expect(MemoryKindStamp.kindSource(of: rec.extras) == nil)
        // Sibling keys survive the stamp pass.
        if case .object(let obj)? = rec.extras {
            #expect(obj["confidence"] == .double(0.8))
        } else {
            Issue.record("metadata lost its object shape")
        }
    }

    @Test func acceptProposalStampsDefaultKindWhenAbsent() async throws {
        let store = try MemoryStorage()
        let p = StoredProposal(content: "proposal without any kind signal")
        _ = try await store.insertProposal(p)
        let accepted = try await store.acceptProposal(id: p.id)
        #expect(MemoryKindStamp.kind(of: accepted.metadata) == "general")
        #expect(MemoryKindStamp.kindSource(of: accepted.metadata) == "write_default_v1")
    }

    @Test func defaultKindIsSemanticsNeutral() {
        // decayFactor 1.0 — "general" must NOT be in the half-life table…
        let old = "2025-01-01T00:00:00Z"
        #expect(MemoryRecallScoring.decayFactor(kind: "general", updatedAt: old) == 1.0)
        // …and never supersedes (not single-valued).
        #expect(!memorySupersessionSingleValuedKinds.contains("general"))
    }

    @Test func classifiabilityRules() {
        #expect(MemoryKindStamp.isClassifiable(nil))
        #expect(MemoryKindStamp.isClassifiable(.object([
            "kind": .string("general"), "kind_source": .string("write_default_v1"),
        ])))
        // Deliberate kinds (caller/extractor/backfill) are never re-proposed.
        #expect(!MemoryKindStamp.isClassifiable(.object(["kind": .string("preference")])))
        #expect(!MemoryKindStamp.isClassifiable(.object([
            "kind": .string("project"), "kind_source": .string("backfill_llm_v1"),
        ])))
        #expect(!MemoryKindStamp.isClassifiable(.object(["kind": .string("general")])))
    }
}

// MARK: - Item 5b: approval-gated kind backfill

@Suite("KindBackfill")
struct KindBackfillTests {

    private static let classifier: @Sendable (String, [String]) async throws -> String = { content, _ in
        if content.contains("lives in") { return "location" }
        if content.contains("prefers") { return "preference" }
        return "project"
    }

    /// Seed: three legacy kind-less rows + one deliberately kinded row.
    private func seed(_ store: MemoryStorage) async throws -> [StoredMemory] {
        let rows = [
            StoredMemory(content: "the user lives in the canyon"),
            StoredMemory(content: "the user prefers Opus 4.8 for implementation"),
            StoredMemory(content: "NativeAgent Swift-native cutover campaign is running"),
        ]
        for r in rows { _ = try await store.insertMemory(r) }
        _ = try await store.insertMemory(StoredMemory(
            content: "already kinded row",
            metadata: .object(["kind": .string("identity")])))
        return rows
    }

    @Test func stagingStagesCardAndMutatesNothing() async throws {
        let dataRoot = try tempDir("backfill")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let store = try MemoryStorage()
        let seeded = try await seed(store)
        let capture = ApprovalCapture()

        let approvalId = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot, storage: store,
            classifier: Self.classifier,
            createApproval: { await capture.record($0) },
            listPendingBackfills: { [] })

        #expect(approvalId == "appr-test-1")

        // The approval body: right action, one row proposal per legacy row.
        let body = try #require(await capture.bodies.first)
        #expect(str(body, "action") == MemoryKindBackfill.action)
        guard case .object(let bodyObj) = body, let payload = bodyObj["payload"] else {
            Issue.record("approval body has no payload"); return
        }
        let proposals = MemoryKindBackfill.rowProposals(fromPayload: payload)
        #expect(proposals.count == 3)
        #expect(Set(proposals.map(\.id)) == Set(seeded.map(\.id)))
        #expect(Set(proposals.map(\.proposedKind)) == Set(["location", "preference", "project"]))
        #expect(proposals.allSatisfy { MemoryKindStamp.taxonomy.contains($0.proposedKind) })

        // Card staged in the inbox, id == approval id, approve/deny actions.
        let cards = try readJSONLEntries(
            dataRoot.appendingPathComponent("notifications/inbox.jsonl"))
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(str(card, "id") == "appr-test-1")
        #expect(str(card, "related_approval_id") == "appr-test-1")
        if case .object(let cardObj) = card, case .array(let actions)? = cardObj["actions"] {
            let ids = actions.compactMap { str($0, "id") }
            #expect(ids.contains("approve") && ids.contains("reject"))
        } else {
            Issue.record("card has no actions array")
        }

        // NOTHING mutated pre-approval: every legacy row is still kind-less.
        for row in seeded {
            let current = try #require(try await store.memory(id: row.id))
            #expect(MemoryKindStamp.kind(of: current.metadata) == nil)
            #expect(current.content == row.content)
        }

        // Idempotent: the stamp short-circuits a second pass.
        let again = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot, storage: store,
            classifier: Self.classifier,
            createApproval: { await capture.record($0) },
            listPendingBackfills: { [] })
        #expect(again == "appr-test-1")
        #expect(await capture.bodies.count == 1)
    }

    @Test func applyWritesKindsThroughStorePath() async throws {
        let dataRoot = try tempDir("backfill-apply")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let store = try MemoryStorage()
        let seeded = try await seed(store)
        let capture = ApprovalCapture()
        _ = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot, storage: store,
            classifier: Self.classifier,
            createApproval: { await capture.record($0) },
            listPendingBackfills: { [] })
        let body = try #require(await capture.bodies.first)
        guard case .object(let bodyObj) = body, let payload = bodyObj["payload"] else {
            Issue.record("no payload"); return
        }

        let outcome = try await MemoryKindBackfill.apply(
            MemoryKindBackfill.rowProposals(fromPayload: payload), storage: store)

        #expect(Set(outcome.applied) == Set(seeded.map(\.id)))
        #expect(outcome.skippedStale.isEmpty)
        #expect(outcome.failed.isEmpty)
        for row in seeded {
            let current = try #require(try await store.memory(id: row.id))
            #expect(MemoryKindStamp.kind(of: current.metadata) != nil)
            #expect(MemoryKindStamp.kindSource(of: current.metadata) == "backfill_llm_v1")
            #expect(current.content == row.content)   // metadata-only mutation
        }
        // The deliberately kinded row was never on the card and is untouched.
        let kinded = try await store.listMemories()
            .first { MemoryKindStamp.kind(of: $0.metadata) == "identity" }
        #expect(kinded != nil)
    }

    @Test func applyGuardsStaleAndJunkRows() async throws {
        let store = try MemoryStorage()
        let a = StoredMemory(content: "row that will drift")
        let b = StoredMemory(content: "row that gets a deliberate kind meanwhile")
        let c = StoredMemory(content: "row with junk proposal")
        for r in [a, b, c] { _ = try await store.insertMemory(r) }
        let proposals = [
            MemoryKindBackfill.RowProposal(
                id: a.id, contentHash: MemoryStorage.contentHash(a.content),
                contentPreview: a.content, proposedKind: "project"),
            MemoryKindBackfill.RowProposal(
                id: b.id, contentHash: MemoryStorage.contentHash(b.content),
                contentPreview: b.content, proposedKind: "project"),
            MemoryKindBackfill.RowProposal(
                id: c.id, contentHash: MemoryStorage.contentHash(c.content),
                contentPreview: c.content, proposedKind: "not_a_real_kind"),
            MemoryKindBackfill.RowProposal(
                id: "ghost", contentHash: "x", contentPreview: "", proposedKind: "project"),
        ]
        // Drift row a's content; give row b a deliberate kind.
        _ = try await store.updateMemory(id: a.id, patch: MemoryPatch(content: "drifted content"))
        _ = try await store.updateMemory(
            id: b.id, patch: MemoryPatch(metadata: .object(["kind": .string("preference")])))

        let outcome = try await MemoryKindBackfill.apply(proposals, storage: store)

        #expect(outcome.applied.isEmpty)
        #expect(Set(outcome.skippedStale) == Set([a.id, b.id]))
        #expect(outcome.failed[c.id]?.contains("taxonomy") == true)
        #expect(outcome.failed["ghost"] == "row not found")
        // Guarded rows untouched: a still kind-less, b keeps its deliberate kind.
        let aNow = try #require(try await store.memory(id: a.id))
        #expect(MemoryKindStamp.kind(of: aNow.metadata) == nil)
        let bNow = try #require(try await store.memory(id: b.id))
        #expect(MemoryKindStamp.kind(of: bNow.metadata) == "preference")
        let cNow = try #require(try await store.memory(id: c.id))
        #expect(MemoryKindStamp.kind(of: cNow.metadata) == nil)
    }

    @Test func outOfTaxonomyClassifierReplyDropsRowFromCard() async throws {
        // Fix-round finding 1: a classifier reply outside the taxonomy (the
        // shape AppleFoundationModelsAdapter.classify used to coerce to the
        // first taxonomy entry, "identity") must DROP that row from the
        // proposal set — never surface a fabricated label on the card.
        let dataRoot = try tempDir("backfill-junk")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let store = try MemoryStorage()
        let seeded = try await seed(store)
        let capture = ApprovalCapture()

        let approvalId = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot, storage: store,
            classifier: { content, _ in
                content.contains("lives in") ? "banana" : "project"
            },
            createApproval: { await capture.record($0) },
            listPendingBackfills: { [] })

        // Card still stages — for the two trustworthy rows only.
        #expect(approvalId == "appr-test-1")
        let body = try #require(await capture.bodies.first)
        guard case .object(let bodyObj) = body, let payload = bodyObj["payload"] else {
            Issue.record("approval body has no payload"); return
        }
        let proposals = MemoryKindBackfill.rowProposals(fromPayload: payload)
        #expect(proposals.count == 2)
        #expect(proposals.allSatisfy { $0.proposedKind == "project" })
        // The junk-reply row is absent — and in particular NOT "identity".
        let junkRow = try #require(seeded.first { $0.content.contains("lives in") })
        #expect(!proposals.contains { $0.id == junkRow.id })
        // It stays kind-less and classifiable for a later pass.
        let current = try #require(try await store.memory(id: junkRow.id))
        #expect(MemoryKindStamp.kind(of: current.metadata) == nil)
        #expect(MemoryKindStamp.isClassifiable(current.metadata))
    }

    @Test func classifierFailureStagesNothing() async throws {
        let dataRoot = try tempDir("backfill-fail")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let store = try MemoryStorage()
        _ = try await seed(store)
        let capture = ApprovalCapture()

        let approvalId = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot, storage: store,
            classifier: { _, _ in throw MemoryV2Error.underlying("FM unavailable") },
            createApproval: { await capture.record($0) },
            listPendingBackfills: { [] })

        // Fail-safe: no approval, no card, no stamp — retried on a later pass.
        #expect(approvalId == nil)
        #expect(await capture.bodies.isEmpty)
        #expect(MemoryKindBackfill.readStamp(dataRoot: dataRoot) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("notifications/inbox.jsonl").path))
    }

    @Test func crashRetryReusesPendingApproval() async throws {
        // A prior launch created the approval but died before the stamp:
        // the pending-scan must adopt it instead of double-staging.
        let dataRoot = try tempDir("backfill-crash")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let store = try MemoryStorage()
        _ = try await seed(store)
        let orphanPayload = MemoryKindBackfill.payload(rows: [
            MemoryKindBackfill.RowProposal(
                id: "row-1", contentHash: "h", contentPreview: "p", proposedKind: "project"),
        ])
        let capture = ApprovalCapture()

        let approvalId = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot, storage: store,
            classifier: Self.classifier,
            createApproval: { await capture.record($0) },
            listPendingBackfills: { [("appr-orphan", orphanPayload)] })

        #expect(approvalId == "appr-orphan")
        #expect(await capture.bodies.isEmpty)   // no fresh approval created
        #expect(MemoryKindBackfill.readStamp(dataRoot: dataRoot) == "appr-orphan")
        let cards = try readJSONLEntries(
            dataRoot.appendingPathComponent("notifications/inbox.jsonl"))
        #expect(cards.count == 1)
        #expect(str(try #require(cards.first), "id") == "appr-orphan")
    }

    @Test func payloadRoundTrips() {
        let rows = [
            MemoryKindBackfill.RowProposal(
                id: "id-1", contentHash: "hash-1", contentPreview: "preview-1",
                proposedKind: "identity"),
            MemoryKindBackfill.RowProposal(
                id: "id-2", contentHash: "hash-2", contentPreview: "preview-2",
                proposedKind: "volatile"),
        ]
        let payload = MemoryKindBackfill.payload(rows: rows)
        #expect(MemoryKindBackfill.payloadKind(payload) == MemoryKindBackfill.payloadKindValue)
        #expect(MemoryKindBackfill.rowProposals(fromPayload: payload) == rows)
    }
}
