// U3 wave-2 item 7: gated consolidation — candidate store, probe gate,
// approval card, swap-on-approve, crash-window reconcile.

import Foundation
import Testing
import ApprovalInbox
import GRDB
import KnowledgeGraph
@testable import MemoryV2
import NativeAgentCore

private actor ConsolidationInvalidationRecorder {
    private(set) var changes: [DerivedSourceChange] = []
    func record(_ change: DerivedSourceChange) { changes.append(change) }
}

private actor FailOnceSpotlightClient: SpotlightIndexClient {
    enum Failure: Error { case injected }
    private var failuresRemaining = 1
    private(set) var indexed: [String: SpotlightItem] = [:]

    func index(_ items: [SpotlightItem]) async throws {
        for item in items { indexed[item.id] = item }
    }

    func delete(ids: [String]) async throws {
        for id in ids { indexed.removeValue(forKey: id) }
    }

    func deleteAll(domainIdentifier: String) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Failure.injected
        }
        indexed.removeAll()
    }
}

@Suite("MemoryConsolidationGate", .serialized)
struct MemoryConsolidationGateTests {

    // MARK: - Fixture

    struct Fixture {
        let root: URL
        let storage: MemoryStorage
        let memA: StoredMemory      // "teal blue" row
        let memB: StoredMemory      // "NativeAgent macOS app" row
        let proposal: StoredProposal // high-durability → candidate accepts
        let embedder: KeyedEmbedder
        let probes: MemoryProbeSet
        let consolidator: MemoryConsolidator
    }

    private func makeFixture(extraProbes: [MemoryProbe] = []) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("consolidation-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = try MemoryStorage(dataRoot: root)
        let memA = StoredMemory(
            content: "the user's favorite color is teal blue",
            embedding: [1, 0, 0, 0]
        )
        let memB = StoredMemory(
            content: "Agent runs on the NativeAgent macOS app",
            embedding: [0, 1, 0, 0]
        )
        _ = try await storage.insertMemory(memA)
        _ = try await storage.insertMemory(memB)
        let proposal = StoredProposal(
            content: "the user ships fast and verifies empirically",
            source: "gate-test",
            embedding: [0, 0, 1, 0],
            metadata: .object(["durability_score": .double(0.91)])
        )
        _ = try await storage.insertProposal(proposal)

        let probes = MemoryProbeSet(topK: 5, probes: [
            MemoryProbe(id: "q1", question: "What is the user's favorite color?",
                        expectAnySubstring: ["favorite color is teal"]),
            MemoryProbe(id: "q2", question: "Where does Agent run?",
                        expectAnySubstring: ["NativeAgent macOS app"]),
        ] + extraProbes)
        let embedder = KeyedEmbedder(table: [
            "What is the user's favorite color?": [1, 0, 0, 0],
            "Where does Agent run?": [0, 1, 0, 0],
            "Did the user ever train homing pigeons?": [0, 0, 0, 1],
        ])
        let consolidator = MemoryConsolidator(
            storage: storage, embedder: embedder, probeSet: probes)
        return Fixture(
            root: root, storage: storage, memA: memA, memB: memB,
            proposal: proposal, embedder: embedder, probes: probes,
            consolidator: consolidator
        )
    }

    private func approvals(root: URL) -> SwiftNativeApprovalInbox {
        SwiftNativeApprovalInbox(root: root)
    }

    private func candidateRunIds(root: URL) -> [String] {
        let dir = MemoryConsolidationGate.candidatesDir(dataRoot: root)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func liveFingerprint(_ fixture: Fixture) async throws -> String {
        let path = await fixture.storage.path
        return try MemoryConsolidationGate.fingerprint(ofDatabaseAt: path)
    }

    private func stagedApprovalId(_ outcome: GatedConsolidationOutcome) -> String? {
        if case .staged(let id, _, _, _) = outcome { return id }
        return nil
    }

    private func sqlCount(
        _ path: URL,
        _ sql: String,
        _ arguments: StatementArguments = StatementArguments()
    ) throws -> Int {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.readonly = true
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    // MARK: - Staging

    @Test func stagesCardAndNeverTouchesLive() async throws {
        let fx = try await makeFixture()
        let before = try await liveFingerprint(fx)

        let outcome = try await fx.consolidator.consolidateGated()
        guard case .staged(let approvalId, let scores, let diff, let plan) = outcome else {
            Issue.record("expected .staged, got \(outcome)")
            return
        }
        // Live store untouched — fingerprint identical, proposal still pending.
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == before)
        let pendingProposals = try await fx.storage.listProposals(status: "pending")
        #expect(pendingProposals.contains { $0.id == fx.proposal.id })
        let liveActives = try await fx.storage.listMemories()
        #expect(liveActives.count == 2)

        // Scores + plan describe the candidate run.
        #expect(scores.live.hits == 2 && scores.live.total == 2)
        #expect(scores.candidate.hits == 2)
        #expect(diff.accepted == 1)
        #expect(plan.autoAccepted == 1)

        // Approval record exists with the right payload.
        let record = try await approvals(root: fx.root).get(approvalId)
        #expect(record.action == MemoryConsolidationGate.approvalAction)
        #expect(record.status == "pending")
        #expect(MemoryConsolidationGate.payloadKind(of: record.payload)
                == MemoryConsolidationGate.payloadKind)
        let runId = try #require(MemoryConsolidationGate.runId(of: record.payload))

        // Candidate db + manifest on disk.
        #expect(FileManager.default.fileExists(
            atPath: MemoryConsolidationGate.candidateDBPath(dataRoot: fx.root, runId: runId).path))
        #expect(FileManager.default.fileExists(
            atPath: MemoryConsolidationGate.manifestPath(dataRoot: fx.root, runId: runId).path))

        // Inbox card filed with id == approval id.
        let inboxPath = fx.root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let cardData = try String(contentsOf: inboxPath, encoding: .utf8)
        #expect(cardData.contains(approvalId))

        // Idempotent: a second run stages nothing new.
        let second = try await fx.consolidator.consolidateGated()
        guard case .alreadyStaged(let existingId) = second else {
            Issue.record("expected .alreadyStaged, got \(second)")
            return
        }
        #expect(existingId == approvalId)
        #expect(candidateRunIds(root: fx.root).count == 1)
    }

    @Test func refusesToStageWhenCandidateScoresBelowLive() async throws {
        let fx = try await makeFixture(extraProbes: [
            MemoryProbe(id: "q3", question: "Did the user ever train homing pigeons?",
                        expectAnySubstring: ["homing pigeons"]),
        ])
        // A 2-year-stale, never-used memory the probe set depends on — the
        // candidate run archives it, costing the candidate the q3 probe.
        let staleDate = "2024-01-01T00:00:00.000Z"
        let stale = StoredMemory(
            content: "the user once trained homing pigeons for fun",
            createdAt: staleDate,
            updatedAt: staleDate,
            embedding: [0, 0, 0, 1]
        )
        _ = try await fx.storage.insertMemory(stale)
        let before = try await liveFingerprint(fx)

        let outcome = try await fx.consolidator.consolidateGated()
        guard case .refusedRegression(let scores, _) = outcome else {
            Issue.record("expected .refusedRegression, got \(outcome)")
            return
        }
        #expect(scores.live.hits == 3)
        #expect(scores.candidate.hits == 2)
        #expect(scores.candidate.misses.contains { $0.probeId == "q3" })
        #expect(scores.lostProbeIds == ["q3"])

        // Nothing staged, candidate discarded, live untouched.
        let pending = try await approvals(root: fx.root).list(
            filter: ApprovalFilter(status: "pending", action: MemoryConsolidationGate.approvalAction))
        #expect(pending.isEmpty)
        #expect(candidateRunIds(root: fx.root).isEmpty)
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == before)
        let staleRow = try await fx.storage.memory(id: stale.id)
        #expect(staleRow?.status == "active")
    }

    @Test func noChangesStagesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("consolidation-nochange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(
            StoredMemory(content: "fresh row, nothing to consolidate", embedding: [1, 0, 0, 0]))
        let consolidator = MemoryConsolidator(
            storage: storage,
            embedder: KeyedEmbedder(table: [:]),
            probeSet: MemoryProbeSet(topK: 3, probes: [
                MemoryProbe(id: "q1", question: "anything?", expectAnySubstring: ["fresh row"]),
            ])
        )
        let outcome = try await consolidator.consolidateGated()
        guard case .noChanges = outcome else {
            Issue.record("expected .noChanges, got \(outcome)")
            return
        }
        let pending = try await approvals(root: root).list(
            filter: ApprovalFilter(status: "pending", action: MemoryConsolidationGate.approvalAction))
        #expect(pending.isEmpty)
        #expect(candidateRunIds(root: root).isEmpty)
    }

    @Test func embedderFailureFailsClosed() async throws {
        let fx = try await makeFixture()
        let consolidator = MemoryConsolidator(
            storage: fx.storage, embedder: ThrowingEmbedder(), probeSet: fx.probes)
        let before = try await liveFingerprint(fx)
        await #expect(throws: MemoryConsolidationGateError.self) {
            _ = try await consolidator.consolidateGated()
        }
        // Fail closed: no card, no candidate residue, live untouched.
        let pending = try await approvals(root: fx.root).list(
            filter: ApprovalFilter(status: "pending", action: MemoryConsolidationGate.approvalAction))
        #expect(pending.isEmpty)
        #expect(candidateRunIds(root: fx.root).isEmpty)
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == before)
    }

    // MARK: - Swap on approve

    @Test func swapOnApproveAppliesAtomicallyAndCarriesUseCounts() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))

        // Access signal lands on live AFTER staging — must not stale the
        // card and must survive the swap.
        try await fx.storage.recordRecallHits(ids: [fx.memA.id])

        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .approved, decidedBy: "gate-test")
        let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: fx.root)
        #expect(outcomes.contains { if case .applied = $0 { return true }; return false })

        // The accepted proposal is now an active live memory.
        let actives = try await fx.storage.listMemories()
        #expect(actives.count == 3)
        #expect(actives.contains { $0.content == fx.proposal.content })
        let pendingProposals = try await fx.storage.listProposals(status: "pending")
        #expect(pendingProposals.isEmpty)

        // use_count carried over (MAX of live/candidate).
        let memAAfter = try await fx.storage.memory(id: fx.memA.id)
        #expect(memAAfter?.useCount == 1)

        // Receipt written, candidate cleaned up, backup exists — and the
        // approval record carries the executedAction annotation (an applied
        // swap must never read as silently executed).
        let resolvedRecord = try await approvals(root: fx.root).get(approvalId)
        #expect(resolvedRecord.executedAction != nil)
        #expect(resolvedRecord.detail?.contains("applied") == true)
        let resolvedPayload = resolvedRecord.payload
        let runId = try #require(MemoryConsolidationGate.runId(of: resolvedPayload))
        let receiptData = try Data(contentsOf:
            MemoryConsolidationGate.receiptPath(dataRoot: fx.root, runId: runId))
        #expect(String(decoding: receiptData, as: UTF8.self).contains("\"applied\""))
        #expect(candidateRunIds(root: fx.root).isEmpty)
        let backupsDir = fx.root
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        #expect(backups.contains { $0.hasPrefix("pre-consolidation-") })
    }

    /// Lifecycle regression (blueprint R1): the swap's INSERT INTO memories must
    /// carry the `lifecycle` column. It previously listed only 12 columns and
    /// omitted lifecycle, so every row reset to the schema default 'confirmed'
    /// on swap — silently resurrecting corrected/contradicted/deleted facts back
    /// into recall (recall filters + ranks on lifecycle). A non-default lifecycle
    /// on a kept live row must survive the approved swap.
    @Test func swapPreservesLifecycleColumn() async throws {
        let fx = try await makeFixture()
        // A kept, durable live memory carrying a NON-default lifecycle.
        // Embedding is orthogonal to memA/memB AND the proposal so it neither
        // becomes a probe hit nor dedups the accepted proposal.
        let inferred = StoredMemory(
            content: "the user prefers to review diffs before merging",
            embedding: [0, 0, 0, 1],
            lifecycle: MemoryLifecycle.inferred
        )
        _ = try await fx.storage.insertMemory(inferred)

        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .approved, decidedBy: "gate-test")
        let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: fx.root)
        #expect(outcomes.contains { if case .applied = $0 { return true }; return false })

        // The swap applied (accepted proposal is now live)...
        let actives = try await fx.storage.listMemories()
        #expect(actives.contains { $0.content == fx.proposal.content })
        // ...and the non-default lifecycle SURVIVED (pre-fix: reset to confirmed).
        let inferredAfter = try await fx.storage.memory(id: inferred.id)
        #expect(inferredAfter?.lifecycle == MemoryLifecycle.inferred)
        // Control: a default-confirmed kept row stays confirmed.
        let memAAfter = try await fx.storage.memory(id: fx.memA.id)
        #expect(memAAfter?.lifecycle == MemoryLifecycle.confirmed)
    }

    @Test func swapOnApproveRebuildsEveryDerivedMemoryProjection() async throws {
        let fx = try await makeFixture()
        let personaRoot = fx.root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        // Consolidation only ever runs on an install that finished onboarding,
        // and USER.md regeneration is gated on that (fix-blank-install-
        // onboarding, 2026-08-02). Model the sentinel the wizard publishes.
        try Data("completed_at=test\n".utf8).write(to: fx.root.appendingPathComponent(".onboarded"))
        let spotlightClient = MockSpotlightIndexClient()
        let invalidations = ConsolidationInvalidationRecorder()
        let environment = MemoryConsolidationProjectionEnvironment(
            personaRoot: personaRoot,
            spotlightClient: spotlightClient,
            publishInvalidation: { change in await invalidations.record(change) }
        )
        let bad = StoredMemory(
            id: "semantic-fragment-kg",
            content: "user likes TradingView interfaces to feel",
            source: "adaptive-promoter:test",
            confidence: 0.8,
            embedding: [0, 0, 0, 1],
            status: "active",
            metadata: .object(["kind": .string("preference")])
        )
        _ = try await fx.storage.insertMemory(bad)
        let livePath = await fx.storage.path
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: livePath)
        try await indexer.indexMemory(KnowledgeGraphMemoryFact(
            id: bad.id,
            content: bad.content,
            source: bad.source,
            status: bad.status,
            createdAt: bad.createdAt,
            updatedAt: bad.updatedAt,
            metadata: bad.metadata
        ))
        #expect(try sqlCount(
            livePath,
            "SELECT COUNT(*) FROM kg_memory_index WHERE memory_id = ?",
            [bad.id]
        ) == 1)
        #expect(try sqlCount(
            livePath,
            "SELECT COUNT(*) FROM kg_entities WHERE metadata_json LIKE ?",
            ["%\(bad.id)%"]
        ) > 0)

        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .approved, decidedBy: "gate-test")
        let outcomes = await MemoryConsolidationGate.reconcile(
            dataRoot: fx.root,
            projectionEnvironment: environment
        )
        #expect(outcomes.contains { if case .applied = $0 { return true }; return false })

        let archived = try await fx.storage.memory(id: bad.id)
        #expect(archived?.status == "archived")
        #expect(try sqlCount(
            livePath,
            "SELECT COUNT(*) FROM kg_memory_index WHERE memory_id = ?",
            [bad.id]
        ) == 0)
        #expect(try sqlCount(
            livePath,
            """
            SELECT COUNT(*) FROM kg_entities
            WHERE name = 'TradingView'
               OR name LIKE 'Preference: user likes TradingView%'
            """
        ) == 0)

        let userMD = try String(
            contentsOf: personaRoot.appendingPathComponent("USER.md"),
            encoding: .utf8
        )
        #expect(userMD.contains(fx.proposal.content))
        #expect(!userMD.contains(bad.content))

        let spotlight = await spotlightClient.snapshot()
        #expect(spotlight[fx.memA.id] != nil)
        #expect(spotlight[fx.memB.id] != nil)
        #expect(spotlight[fx.proposal.id] != nil)
        #expect(spotlight[bad.id] == nil)

        let changes = await invalidations.changes
        #expect(changes.count == 1)
        #expect(changes.first?.namespace == "memory-v2")
        #expect(changes.first?.operation == .reconcile)
        #expect(changes.first?.reason == "memory_consolidation_projection_rebuild")

        let resolvedRecord = try await approvals(root: fx.root).get(approvalId)
        #expect(resolvedRecord.detail?.contains("memory projections reconciled") == true)
        guard case .object(let action)? = resolvedRecord.executedAction,
              case .object(let projections)? = action["memory_projections"],
              case .object(let kg)? = projections["knowledge_graph"],
              case .int(let factsIndexed)? = kg["facts_indexed"],
              case .bool(true)? = projections["fluid_context_invalidation"] else {
            Issue.record("expected complete memory projection receipt on executedAction")
            return
        }
        #expect(factsIndexed >= 3)
    }

    @Test func staleLiveRefusesSwap() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))

        // A NEW memory lands on live after staging — content drift, not
        // just an access bump. The swap must refuse rather than clobber it.
        let lateRow = StoredMemory(
            content: "the user adopted a corgi after the card was staged",
            embedding: [0, 0, 1, 0]
        )
        _ = try await fx.storage.insertMemory(lateRow)
        let driftedFingerprint = try await liveFingerprint(fx)

        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .approved, decidedBy: "gate-test")
        let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: fx.root)
        #expect(outcomes.contains { if case .staleRefused = $0 { return true }; return false })

        // Stale refusal is annotated on the approval record (finding 7).
        let staleRecord = try await approvals(root: fx.root).get(approvalId)
        #expect(staleRecord.executedAction != nil)
        #expect(staleRecord.detail?.contains("STALE") == true)

        // Live untouched (late row intact, proposal still pending).
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == driftedFingerprint)
        let late = try await fx.storage.memory(id: lateRow.id)
        #expect(late?.status == "active")
        let pendingProposals = try await fx.storage.listProposals(status: "pending")
        #expect(pendingProposals.contains { $0.id == fx.proposal.id })
        #expect(candidateRunIds(root: fx.root).isEmpty)
    }

    @Test func deniedDecisionCleansUpCandidate() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        let before = try await liveFingerprint(fx)

        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .denied, decidedBy: "gate-test")
        let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: fx.root)
        #expect(outcomes.contains { if case .cleanedUpDenied = $0 { return true }; return false })
        #expect(candidateRunIds(root: fx.root).isEmpty)
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == before)

        // Denied cleanup is annotated on the approval record (finding 7).
        let deniedRecord = try await approvals(root: fx.root).get(approvalId)
        #expect(deniedRecord.executedAction != nil)
        #expect(deniedRecord.detail?.contains("denied") == true)
    }

    @Test func crashAfterCommitReconcilesAsAlreadyApplied() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        let stagedPayload = try await approvals(root: fx.root).get(approvalId).payload
        let runId = try #require(MemoryConsolidationGate.runId(of: stagedPayload))

        // Keep a copy of the candidate dir to restore post-apply.
        let candidateDir = MemoryConsolidationGate.candidateRoot(dataRoot: fx.root, runId: runId)
        let sideCopy = fx.root.appendingPathComponent("crash-sim-copy", isDirectory: true)
        try FileManager.default.copyItem(at: candidateDir, to: sideCopy)

        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .approved, decidedBy: "gate-test")
        let first = await MemoryConsolidationGate.reconcile(dataRoot: fx.root)
        #expect(first.contains { if case .applied = $0 { return true }; return false })
        let appliedFingerprint = try await liveFingerprint(fx)

        // Simulate "crash after commit, before cleanup": candidate +
        // manifest back on disk, receipt gone.
        try FileManager.default.copyItem(at: sideCopy, to: candidateDir)
        try? FileManager.default.removeItem(
            at: MemoryConsolidationGate.receiptPath(dataRoot: fx.root, runId: runId))

        let second = await MemoryConsolidationGate.reconcile(dataRoot: fx.root)
        #expect(second.contains { if case .alreadyApplied = $0 { return true }; return false })
        // Live unchanged by the re-drive; candidate cleaned again.
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == appliedFingerprint)
        #expect(candidateRunIds(root: fx.root).isEmpty)
    }

    @Test func projectionFailureAfterSwapKeepsCandidateAndRetriesToConvergence() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        let payload = try await approvals(root: fx.root).get(approvalId).payload
        let runId = try #require(MemoryConsolidationGate.runId(of: payload))
        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .approved, decidedBy: "gate-test")

        let spotlight = FailOnceSpotlightClient()
        let invalidations = ConsolidationInvalidationRecorder()
        let environment = MemoryConsolidationProjectionEnvironment(
            personaRoot: fx.root.appendingPathComponent("persona", isDirectory: true),
            spotlightClient: spotlight,
            publishInvalidation: { change in await invalidations.record(change) }
        )

        let first = await MemoryConsolidationGate.reconcile(
            dataRoot: fx.root,
            projectionEnvironment: environment
        )
        #expect(first.contains { if case .failed = $0 { return true }; return false })
        #expect((try await fx.storage.listMemories()).contains { $0.content == fx.proposal.content })
        #expect(candidateRunIds(root: fx.root) == [runId])
        #expect(!FileManager.default.fileExists(
            atPath: MemoryConsolidationGate.receiptPath(dataRoot: fx.root, runId: runId).path
        ))
        let failedRecord = try await approvals(root: fx.root).get(approvalId)
        #expect(failedRecord.detail?.contains("COMMITTED") == true)
        #expect(failedRecord.detail?.contains("retries") == true)

        let second = await MemoryConsolidationGate.reconcile(
            dataRoot: fx.root,
            projectionEnvironment: environment
        )
        #expect(second.contains { if case .alreadyApplied = $0 { return true }; return false })
        #expect(candidateRunIds(root: fx.root).isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: MemoryConsolidationGate.receiptPath(dataRoot: fx.root, runId: runId).path
        ))
        #expect(await invalidations.changes.count == 1)
        #expect(await spotlight.indexed.count == 3)
    }

    @Test func applySwapRefusesUnapprovedRecord() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        let record = try await approvals(root: fx.root).get(approvalId)
        let runId = try #require(MemoryConsolidationGate.runId(of: record.payload))
        let before = try await liveFingerprint(fx)

        // Still pending — the executor must refuse no matter who calls it.
        let result = await MemoryConsolidationGate.applySwap(
            dataRoot: fx.root, runId: runId, approval: record)
        guard case .failed = result else {
            Issue.record("expected .failed for unapproved record, got \(result)")
            return
        }
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == before)
    }

    /// SECURITY (review finding 1): a FORGED in-memory ApprovalRecord —
    /// decision/status flipped to approved/resolved without touching the
    /// inbox — must not move the executor. applySwap re-reads the record
    /// from the inbox and the inbox still says pending.
    @Test func forgedApprovedRecordRefusedBySwapExecutor() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        var forged = try await approvals(root: fx.root).get(approvalId)
        let runId = try #require(MemoryConsolidationGate.runId(of: forged.payload))
        let before = try await liveFingerprint(fx)

        forged.status = "resolved"
        forged.decision = "approved"
        let result = await MemoryConsolidationGate.applySwap(
            dataRoot: fx.root, runId: runId, approval: forged)
        guard case .failed = result else {
            Issue.record("expected .failed for forged record, got \(result)")
            return
        }
        // Live untouched; the legitimately staged run survives the forgery
        // attempt (candidate + pending card intact, no annotation).
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == before)
        #expect(candidateRunIds(root: fx.root).count == 1)
        let real = try await approvals(root: fx.root).get(approvalId)
        #expect(real.status == "pending")
        #expect(real.executedAction == nil)

        // And a GENUINELY approved record cannot be replayed against a
        // different run id: payload run_id must match the run being applied.
        _ = try await approvals(root: fx.root).resolve(
            approvalId, decision: .approved, decidedBy: "gate-test")
        let approved = try await approvals(root: fx.root).get(approvalId)
        let crossRun = await MemoryConsolidationGate.applySwap(
            dataRoot: fx.root, runId: "some-other-run", approval: approved)
        guard case .failed = crossRun else {
            Issue.record("expected .failed for run-id mismatch, got \(crossRun)")
            return
        }
        let fpCheck2 = try await liveFingerprint(fx)
        #expect(fpCheck2 == before)
    }

    /// TOCTOU (review finding 2): the authoritative staleness check lives
    /// INSIDE the swap's immediate transaction. A mismatched fingerprint at
    /// transaction time throws SwapStaleError and the table replacement
    /// rolls back completely.
    @Test func staleCheckInsideTransactionRollsBack() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        let payload = try await approvals(root: fx.root).get(approvalId).payload
        let runId = try #require(MemoryConsolidationGate.runId(of: payload))
        let livePath = await fx.storage.path
        let candidatePath = MemoryConsolidationGate.candidateDBPath(
            dataRoot: fx.root, runId: runId)
        let before = try MemoryConsolidationGate.fingerprint(ofDatabaseAt: livePath)

        #expect(throws: MemoryConsolidationGate.SwapStaleError.self) {
            try MemoryConsolidationGate.transactionalTableSwap(
                livePath: livePath, candidatePath: candidatePath,
                expectedLiveFingerprint: "not-the-staged-fingerprint")
        }
        // Rollback proof: live store byte-identical in content terms.
        let after = try MemoryConsolidationGate.fingerprint(ofDatabaseAt: livePath)
        #expect(after == before)
        let actives = try await fx.storage.listMemories()
        #expect(actives.count == 2)
    }

    @Test func tableSwapEnforcesHardMemoryBoundInsideTransaction() async throws {
        let fx = try await makeFixture()
        let outcome = try await fx.consolidator.consolidateGated()
        let approvalId = try #require(stagedApprovalId(outcome))
        let payload = try await approvals(root: fx.root).get(approvalId).payload
        let runId = try #require(MemoryConsolidationGate.runId(of: payload))
        let livePath = await fx.storage.path
        let candidatePath = MemoryConsolidationGate.candidateDBPath(
            dataRoot: fx.root,
            runId: runId
        )
        let fingerprint = try MemoryConsolidationGate.fingerprint(ofDatabaseAt: livePath)

        let evicted = try MemoryConsolidationGate.transactionalTableSwap(
            livePath: livePath,
            candidatePath: candidatePath,
            expectedLiveFingerprint: fingerprint,
            memoryLimit: 2
        )

        #expect(evicted.count == 1)
        #expect(try await fx.storage.listMemories(status: nil).count == 2)
    }

    /// Per-probe regression (review finding 3): candidate loses one probe
    /// live answered (stale row archived) while GAINING another (accepted
    /// proposal) — equal hit counts, still a regression, refuses to stage.
    @Test func lostProbeOffsetByGainedProbeStillRefuses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("consolidation-lostgain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            content: "the user's favorite color is teal blue", embedding: [1, 0, 0, 0]))
        // Stale, never-recalled row the candidate run will archive — live
        // answers qStale through it.
        let staleDate = "2024-01-01T00:00:00.000Z"
        _ = try await storage.insertMemory(StoredMemory(
            content: "the user once trained homing pigeons for fun",
            createdAt: staleDate, updatedAt: staleDate, embedding: [0, 0, 0, 1]))
        // High-durability proposal the candidate run will accept — the
        // candidate answers qGain through it; live cannot (proposals are
        // not recalled).
        _ = try await storage.insertProposal(StoredProposal(
            content: "the user ships fast and verifies empirically",
            source: "gate-test", embedding: [0, 0, 1, 0],
            metadata: .object(["durability_score": .double(0.91)])))

        let probes = MemoryProbeSet(topK: 5, probes: [
            MemoryProbe(id: "qColor", question: "What is the user's favorite color?",
                        expectAnySubstring: ["favorite color is teal"]),
            MemoryProbe(id: "qStale", question: "Did the user ever train homing pigeons?",
                        expectAnySubstring: ["homing pigeons"]),
            MemoryProbe(id: "qGain", question: "How does the user work?",
                        expectAnySubstring: ["ships fast and verifies"]),
        ])
        let embedder = KeyedEmbedder(table: [
            "What is the user's favorite color?": [1, 0, 0, 0],
            "Did the user ever train homing pigeons?": [0, 0, 0, 1],
            "How does the user work?": [0, 0, 1, 0],
        ])
        let consolidator = MemoryConsolidator(
            storage: storage, embedder: embedder, probeSet: probes)

        let outcome = try await consolidator.consolidateGated()
        guard case .refusedRegression(let scores, _) = outcome else {
            Issue.record("expected .refusedRegression, got \(outcome)")
            return
        }
        // THE case the count rule missed: equal hits, lost probe.
        #expect(scores.live.hits == scores.candidate.hits)
        #expect(scores.lostProbeIds == ["qStale"])
        #expect(!scores.candidateIsAtLeastLive)
        // Nothing staged, live untouched.
        let pending = try await approvals(root: root).list(
            filter: ApprovalFilter(status: "pending", action: MemoryConsolidationGate.approvalAction))
        #expect(pending.isEmpty)
        #expect(candidateRunIds(root: root).isEmpty)
    }

    /// Staging race (review finding 4): two CONCURRENT gated runs on the
    /// same store — the gate flock makes pending-scan + approval-create one
    /// critical section, so exactly one stages and the other reports
    /// alreadyStaged. Never two cards, never two candidates.
    @Test func concurrentGatedRunsStageExactlyOnce() async throws {
        let fx = try await makeFixture()
        let secondConsolidator = MemoryConsolidator(
            storage: fx.storage, embedder: fx.embedder, probeSet: fx.probes)

        async let firstRun = fx.consolidator.consolidateGated()
        async let secondRun = secondConsolidator.consolidateGated()
        let outcomes = try await [firstRun, secondRun]

        let stagedCount = outcomes.filter {
            if case .staged = $0 { return true }; return false
        }.count
        let alreadyCount = outcomes.filter {
            if case .alreadyStaged = $0 { return true }; return false
        }.count
        #expect(stagedCount == 1)
        #expect(alreadyCount == 1)
        let pending = try await approvals(root: fx.root).list(
            filter: ApprovalFilter(status: "pending", action: MemoryConsolidationGate.approvalAction))
        #expect(pending.count == 1)
        #expect(candidateRunIds(root: fx.root).count == 1)
    }

    /// Card-create failure (review finding 5): when the inbox card cannot
    /// be written, the just-created approval is resolved as canceled before
    /// the candidate is deleted — no orphan pending approval survives.
    @Test func cardCreateFailureCancelsApproval() async throws {
        let fx = try await makeFixture()
        // Block ensureInboxCard: a regular FILE where the notifications
        // directory should be makes the inbox.jsonl flock unopenable.
        let notificationsPath = fx.root.appendingPathComponent("notifications")
        try Data("blocker".utf8).write(to: notificationsPath)

        await #expect(throws: MemoryConsolidationGateError.self) {
            _ = try await fx.consolidator.consolidateGated()
        }
        // No pending approval left behind; the record is canceled + annotated.
        let pending = try await approvals(root: fx.root).list(
            filter: ApprovalFilter(status: "pending", action: MemoryConsolidationGate.approvalAction))
        #expect(pending.isEmpty)
        let all = try await approvals(root: fx.root).list(
            filter: ApprovalFilter(status: nil, action: MemoryConsolidationGate.approvalAction))
        let record = try #require(all.first)
        #expect(record.status == "resolved")
        #expect(record.decision == "canceled")
        #expect(record.executedAction != nil)
        // Candidate cleaned up; live untouched.
        #expect(candidateRunIds(root: fx.root).isEmpty)
        let actives = try await fx.storage.listMemories()
        #expect(actives.count == 2)
    }

    /// Fail closed (review finding 6): when the pre-stage reconcile cannot
    /// scan the approval queue, the gated run ABORTS — no candidate is
    /// built, nothing stages on top of an unknown swap state.
    @Test func reconcileScanFailureAbortsStaging() async throws {
        let fx = try await makeFixture()
        // Make the approvals flock unopenable: a DIRECTORY at the lock path
        // fails Darwin.open(O_CREAT|O_WRONLY) with EISDIR.
        let lockBlocker = fx.root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockBlocker, withIntermediateDirectories: true)

        do {
            _ = try await fx.consolidator.consolidateGated()
            Issue.record("expected reconcileFailed throw")
        } catch let err as MemoryConsolidationGateError {
            guard case .reconcileFailed = err else {
                Issue.record("expected .reconcileFailed, got \(err)")
                return
            }
        }
        // Nothing staged, no candidate residue.
        #expect(candidateRunIds(root: fx.root).isEmpty)
    }

    // MARK: - Legacy adapter

    @Test func legacyConsolidateReportsPlanWithoutMutating() async throws {
        let fx = try await makeFixture()
        let before = try await liveFingerprint(fx)

        let report = try await fx.consolidator.consolidate()
        #expect(report.autoAccepted == 1)
        #expect(report.errors.isEmpty)
        let fpCheck = try await liveFingerprint(fx)
        #expect(fpCheck == before)

        // Second legacy run surfaces the already-staged state in errors.
        let second = try await fx.consolidator.consolidate()
        #expect(second.errors.contains { $0.contains("already staged") })
    }
}
