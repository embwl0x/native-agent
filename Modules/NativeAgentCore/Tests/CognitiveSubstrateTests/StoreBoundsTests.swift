import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Every table in cognition.sqlite is BOUNDED (User, 2026-07-02: the subconscious
// must never become "a huge pile of saved memories and files"). Nodes cap at 256
// (field capacity + prune), artifacts at artifactCap, and — the one that was
// unbounded until caught — receipts trim to the newest maxReceipts on prune.
@Suite("StoreBounds")
struct StoreBoundsTests {
    private let protectedReceiptKinds = [
        "reflection.persona_context",
        "emotional_consolidation",
        "replay.integration",
        "workshop.pursuit_proposed",
        "workshop.pursuit_proposal_refused",
    ]

    private func tempDataRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-storebounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func appendReceipts(
        _ store: CognitiveSQLiteStore,
        kind: String,
        count: Int,
        startingAt base: Date
    ) async throws {
        for i in 0..<count {
            try await store.appendReceipt(
                kind: kind,
                payload: .object([
                    "kind": .string(kind),
                    "n": .int(Int64(i)),
                ]),
                at: base.addingTimeInterval(Double(i)),
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i + Int(base.timeIntervalSince1970))) ?? UUID()
            )
        }
    }

    private func appendArtifacts(
        _ store: CognitiveSQLiteStore,
        kind: String,
        count: Int,
        startingAt base: Date
    ) async throws {
        for i in 0..<count {
            try await store.upsertArtifact(
                kind: kind,
                id: UUID(),
                status: "current",
                score: 0.5,
                payload: .object([
                    "kind": .string(kind),
                    "n": .int(Int64(i)),
                ]),
                at: base.addingTimeInterval(Double(i))
            )
        }
    }

    @Test func checkedReplayDoesNotConsumeEvidenceWhenPersistenceIsBlocked() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                replayEnabled: true
            ),
            store: store
        )
        await substrate.markRestoreFailedForTesting()
        let input = CognitiveReplayIntegrationInput(
            reason: "blocked persistence",
            dreamEntries: [
                CognitiveDreamReplayReference(
                    id: "dream-blocked",
                    date: "2026-07-12",
                    filename: "2026-07-12.md",
                    content: "This evidence must remain retryable."
                ),
            ]
        )

        await #expect(throws: CognitivePersistenceError.self) {
            _ = try await substrate.integrateReplayChecked(input)
        }

        #expect(await substrate.episodeSnapshot().isEmpty)
        #expect(await substrate.developmentalTimelineSnapshot().isEmpty)
        #expect(try await store.loadArtifacts(kindPrefix: "episode", limit: 10).isEmpty)
    }

    @Test func checkedMicrocyclePreservesDirtyRetryAfterPersistenceFailure() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                workspaceEnabled: true,
                backgroundMicrocyclesEnabled: true
            ),
            store: store
        )
        await substrate.ingest(CognitiveEvent(
            id: "microcycle-retry",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "conversation", id: "retry"),
            sourceClass: .userStated,
            occurredAt: Date(),
            summary: "This dirty state must survive a failed checkpoint.",
            importance: 0.8
        ))
        await substrate.markRestoreFailedForTesting()

        await #expect(throws: CognitivePersistenceError.self) {
            _ = try await substrate.runMicrocycleChecked(reason: "first attempt")
        }
        await #expect(throws: CognitivePersistenceError.self) {
            _ = try await substrate.runMicrocycleChecked(reason: "retry proves dirty survived")
        }
    }

    @Test func replayReceiptsTrackRealTransitionsButDuplicateInputIsDurableNoOp() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                replayEnabled: true
            ),
            store: store
        )
        let pending = CognitiveReplayIntegrationInput(
            reason: "first",
            remProposals: [
                CognitiveREMProposalReference(
                    id: "rem-status",
                    target: "GROWTH.md",
                    text: "Verify before claiming completion.",
                    evidenceDates: ["2026-07-12"],
                    status: "pending",
                    confidence: 0.8,
                    createdAt: "2026-07-12T00:00:00Z"
                ),
            ]
        )
        _ = try await substrate.integrateReplayChecked(pending)
        #expect(try await store.loadReceiptRecords(kindPrefix: "replay.integration", limit: 10).count == 1)

        let duplicate = try await substrate.integrateReplayChecked(pending)
        #expect(duplicate.schemaProposalIds.isEmpty)
        #expect(duplicate.timelineEventIds.isEmpty)
        #expect(try await store.loadReceiptRecords(kindPrefix: "replay.integration", limit: 10).count == 1)

        let accepted = CognitiveReplayIntegrationInput(
            reason: "status changed",
            remProposals: [
                CognitiveREMProposalReference(
                    id: "rem-status",
                    target: "GROWTH.md",
                    text: "Verify before claiming completion.",
                    evidenceDates: ["2026-07-12"],
                    status: "accepted",
                    confidence: 0.8,
                    createdAt: "2026-07-12T00:00:00Z"
                ),
            ]
        )
        let transition = try await substrate.integrateReplayChecked(accepted)
        #expect(transition.schemaProposalIds.isEmpty)
        #expect(transition.timelineEventIds.count == 1)
        #expect(try await store.loadReceiptRecords(kindPrefix: "replay.integration", limit: 10).count == 2)

        let rejected = CognitiveReplayIntegrationInput(
            reason: "status changed again",
            remProposals: [
                CognitiveREMProposalReference(
                    id: "rem-status",
                    target: "GROWTH.md",
                    text: "Verify before claiming completion.",
                    evidenceDates: ["2026-07-12"],
                    status: "rejected",
                    confidence: 0.8,
                    createdAt: "2026-07-12T00:00:00Z"
                ),
            ]
        )
        let secondTransition = try await substrate.integrateReplayChecked(rejected)
        #expect(secondTransition.timelineEventIds.count == 1)
        #expect(secondTransition.timelineEventIds.first != transition.timelineEventIds.first)
        #expect(try await store.loadReceiptRecords(kindPrefix: "replay.integration", limit: 10).count == 3)
    }

    /// Receipts beyond the cap are trimmed OLDEST-FIRST down to cap − slack
    /// (hysteresis: the prune receipt + the caller's own receipt land after the trim,
    /// so trimming exactly to cap would churn on every subsequent prune). Cap 50 →
    /// slack 12 → keep 38.
    @Test func pruneTrimsReceiptsOldestFirstWithHysteresis() async throws {
        let store = try CognitiveSQLiteStore(dataRoot: try tempDataRoot())
        let base = Date(timeIntervalSince1970: 30_000_000)
        for i in 0..<60 {
            try await store.appendReceipt(
                kind: "tick",
                payload: .object(["n": .int(Int64(i))]),
                at: base.addingTimeInterval(Double(i))
            )
        }

        let result = try await store.prune(maxNodes: 256, maxArtifacts: 600, maxReceipts: 50)
        // 60 appended − keep(50 − 50/4 = 38) = 22 trimmed.
        #expect(result.deletedReceipts == 22, "expected 22 oldest trimmed: \(result.deletedReceipts)")

        let kept = try await store.loadReceiptRecords(kindPrefix: "tick", limit: 100)
        #expect(kept.count == 38, "newest 38 must survive: \(kept.count)")
        // loadReceiptRecords returns newest-first; n 0–21 must be gone.
        let ns = kept.compactMap { record -> Int64? in
            guard case .object(let o) = record.payload, case .int(let n)? = o["n"] else { return nil }
            return n
        }
        #expect(ns.min() == 22, "oldest surviving receipt should be n=22: \(String(describing: ns.min()))")
        #expect(ns.max() == 59)

        // Hysteresis: an immediate second prune (population 38 + 1 prune receipt = 39,
        // under the cap) must be a pure no-op — no churn, no new prune receipt.
        let again = try await store.prune(maxNodes: 256, maxArtifacts: 600, maxReceipts: 50)
        #expect(again.deletedReceipts == 0, "second prune must not churn: \(again.deletedReceipts)")
        let pruneReceipts = try await store.loadReceiptRecords(kindPrefix: "prune", limit: 100)
        #expect(pruneReceipts.count == 1, "no second prune receipt: \(pruneReceipts.count)")
    }

    /// The default cap (10k) leaves normal populations untouched — no accidental
    /// trimming on every persistSnapshot.
    @Test func defaultReceiptCapIsANoOpForNormalPopulations() async throws {
        let store = try CognitiveSQLiteStore(dataRoot: try tempDataRoot())
        let base = Date(timeIntervalSince1970: 31_000_000)
        for i in 0..<20 {
            try await store.appendReceipt(kind: "tick", payload: .object([:]), at: base.addingTimeInterval(Double(i)))
        }
        let result = try await store.prune(maxNodes: 256, maxArtifacts: 600)
        #expect(result.deletedReceipts == 0)
        #expect(try await store.loadReceiptRecords(kindPrefix: "tick", limit: 100).count == 20)
    }

    @Test func pruneProtectsCriticalReceiptFloorsBeforeGenericFIFO() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)

        try await appendReceipts(store, kind: "generic.verification_eviction", count: 32, startingAt: Date(timeIntervalSince1970: 39_999_000))
        try await appendReceipts(store, kind: "reflection.persona_context", count: 32, startingAt: Date(timeIntervalSince1970: 40_000_000))
        try await appendReceipts(store, kind: "emotional_consolidation", count: 32, startingAt: Date(timeIntervalSince1970: 40_001_000))
        try await appendReceipts(store, kind: "replay.integration", count: 32, startingAt: Date(timeIntervalSince1970: 40_002_000))
        try await appendReceipts(store, kind: "workshop.pursuit_proposed", count: 32, startingAt: Date(timeIntervalSince1970: 40_003_000))
        try await appendReceipts(store, kind: "workshop.pursuit_proposal_refused", count: 32, startingAt: Date(timeIntervalSince1970: 40_004_000))
        try await appendReceipts(store, kind: "tick", count: 80, startingAt: Date(timeIntervalSince1970: 40_005_000))

        let result = try await store.prune(maxNodes: 256, maxArtifacts: 600, maxReceipts: 256)
        #expect(result.deletedReceipts == 80, "cap 256 trims to 192 with slack 64")

        for kind in protectedReceiptKinds {
            #expect(try await store.loadReceiptRecords(kindPrefix: kind, limit: 64).count == 32, "\(kind) floor must survive")
        }
        #expect(try await store.loadReceiptRecords(kindPrefix: "generic.verification_eviction", limit: 64).isEmpty)
        #expect(try await store.loadReceiptRecords(kindPrefix: "tick", limit: 100).count == 32)
    }

    /// The reflection/replay families do not end at their happy-path kind. A
    /// pending reconciliation is UNFINISHED replay work and a persona-load
    /// failure is the only trace of a reflection that could not run — FIFO used
    /// to spend both as generic noise. Fills past the cap and pins that the
    /// floors survive while the unprotected tail is still trimmed to cap − slack.
    @Test func pruneProtectsPendingAndFailureReceiptsInTheNamedFamilies() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)

        try await appendReceipts(store, kind: "reflection.persona_load_failed", count: 32, startingAt: Date(timeIntervalSince1970: 45_000_000))
        try await appendReceipts(store, kind: "reflection.skipped", count: 32, startingAt: Date(timeIntervalSince1970: 45_001_000))
        try await appendReceipts(store, kind: "replay.reconciliation_pending", count: 32, startingAt: Date(timeIntervalSince1970: 45_002_000))
        // Newer than every protected row: a kind-blind FIFO would keep these.
        try await appendReceipts(store, kind: "tick", count: 80, startingAt: Date(timeIntervalSince1970: 45_003_000))

        // 176 rows, cap 128 → slack 32 → target 96 → 80 trimmed.
        let result = try await store.prune(maxNodes: 256, maxArtifacts: 600, maxReceipts: 128)
        #expect(result.deletedReceipts == 80, "cap 128 trims to 96 with slack 32: \(result.deletedReceipts)")

        for kind in ["reflection.persona_load_failed", "reflection.skipped", "replay.reconciliation_pending"] {
            #expect(try await store.loadReceiptRecords(kindPrefix: kind, limit: 64).count == 32, "\(kind) floor must survive")
        }
        #expect(try await store.loadReceiptRecords(kindPrefix: "tick", limit: 200).isEmpty, "unprotected FIFO must still be spent")
        // Cap enforced overall: 96 retained + the single prune receipt.
        #expect(try await store.loadReceiptRecords(limit: 400).count == 97)
    }

    @Test func pruneSpendsMicrocycleReceiptsBeforeOtherUnprotectedKinds() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)

        try await appendReceipts(store, kind: "reflection.persona_context", count: 32, startingAt: Date(timeIntervalSince1970: 40_999_000))
        try await appendReceipts(store, kind: "emotional_consolidation", count: 32, startingAt: Date(timeIntervalSince1970: 41_000_000))
        try await appendReceipts(store, kind: "replay.integration", count: 32, startingAt: Date(timeIntervalSince1970: 41_001_000))
        try await appendReceipts(store, kind: "workshop.pursuit_proposed", count: 32, startingAt: Date(timeIntervalSince1970: 41_002_000))
        try await appendReceipts(store, kind: "workshop.pursuit_proposal_refused", count: 32, startingAt: Date(timeIntervalSince1970: 41_003_000))
        try await appendReceipts(store, kind: "tick", count: 20, startingAt: Date(timeIntervalSince1970: 41_004_000))
        try await appendReceipts(store, kind: "microcycle", count: 80, startingAt: Date(timeIntervalSince1970: 41_005_000))

        let result = try await store.prune(maxNodes: 256, maxArtifacts: 600, maxReceipts: 240)
        #expect(result.deletedReceipts == 80, "cap 240 trims to 180 with slack 60")
        #expect(try await store.loadReceiptRecords(kindPrefix: "microcycle", limit: 100).isEmpty)
        #expect(try await store.loadReceiptRecords(kindPrefix: "tick", limit: 100).count == 20)
        for kind in protectedReceiptKinds {
            #expect(try await store.loadReceiptRecords(kindPrefix: kind, limit: 64).count == 32, "\(kind) floor must survive")
        }
    }

    @Test func protectedReceiptFloorsNeverEscapeTheHardCap() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)

        try await appendReceipts(store, kind: "reflection.persona_context", count: 32, startingAt: Date(timeIntervalSince1970: 42_000_000))
        try await appendReceipts(store, kind: "emotional_consolidation", count: 32, startingAt: Date(timeIntervalSince1970: 42_001_000))
        try await appendReceipts(store, kind: "replay.integration", count: 32, startingAt: Date(timeIntervalSince1970: 42_002_000))
        try await appendReceipts(store, kind: "workshop.pursuit_proposed", count: 32, startingAt: Date(timeIntervalSince1970: 42_003_000))
        try await appendReceipts(store, kind: "workshop.pursuit_proposal_refused", count: 32, startingAt: Date(timeIntervalSince1970: 42_004_000))

        let result = try await store.prune(maxNodes: 256, maxArtifacts: 600, maxReceipts: 96)
        #expect(result.deletedReceipts == 88, "cap 96 trims to 72 with slack 24")

        let all = try await store.loadReceiptRecords(limit: 200)
        #expect(all.count == 73, "72 retained rows plus one prune receipt")
        #expect(all.filter { $0.kind == "prune" }.count == 1)
        #expect(all.filter { $0.kind == "reflection.persona_context" }.isEmpty)
        #expect(all.filter { $0.kind == "emotional_consolidation" }.isEmpty)
        #expect(all.filter { $0.kind == "replay.integration" }.count == 8)
        #expect(all.filter { $0.kind == "workshop.pursuit_proposed" }.count == 32)
        #expect(all.filter { $0.kind == "workshop.pursuit_proposal_refused" }.count == 32)
    }

    // MARK: - R2-C (2026-07-09): the receipt-mirror flood that amputated her inner life

    /// Receipts must NOT be mirrored into cognitive_artifacts. The old double-write
    /// flooded the artifact cap with high-frequency noise (510/516 rows in the live
    /// store were "receipt.*"), and the kind-blind prune then evicted the RARE
    /// artifacts restorePersistentState depends on — standing views, thought seeds,
    /// episodes, proposals, timeline. One copy, in cognitive_receipts, is the design.
    @Test func appendReceiptWritesNoArtifactMirror() async throws {
        let store = try CognitiveSQLiteStore(dataRoot: try tempDataRoot())
        let now = Date(timeIntervalSince1970: 32_000_000)
        try await store.appendReceipt(kind: "cognition.resource_skip", payload: .object([:]), at: now)
        try await store.appendReceipt(kind: "prune", payload: .object([:]), at: now)

        let mirrors = try await store.loadArtifacts(kindPrefix: "receipt.", limit: 100)
        #expect(mirrors.isEmpty, "receipts must not mirror into artifacts: \(mirrors.count)")
        // The receipt itself still lands.
        #expect(try await store.loadReceiptRecords(kindPrefix: "cognition.resource_skip", limit: 10).count == 1)
    }

    /// Audit C1 (2026-07-09): after a FAILED restore, persistSnapshot must refuse to
    /// write — saveNodes deletes the whole table first, so persisting the near-empty
    /// in-memory field would destroy everything the restore couldn't load. One bad
    /// launch must never amputate her store. (The set-on-throw path is a 3-line
    /// do/catch in restorePersistentState; this pins the guard's behavior.)
    @Test func failedRestoreFreezesDestructivePersist() async throws {
        let root = try tempDataRoot()
        let now = Date(timeIntervalSince1970: 34_000_000)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        // Her existing life on disk.
        let node = CognitiveNode(
            id: UUID(), kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(type: "topic", id: "life", label: "life"),
            activation: 0.8, salience: 0.8, confidence: 0.8, sourceClass: .userStated,
            createdAt: now, lastActivatedAt: now, decayHalfLife: 10_000,
            summary: "a memory that must survive a bad launch", metadata: [:],
            emotionalValence: 0.4, emotionalArousal: 0.2, emotionalWarmth: 0.5)
        try await store.saveNodes([node], at: now)

        // A launch whose restore threw: the field is near-empty, the flag is set.
        let substrate = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { now }, makeUUID: { UUID() }),
            store: store)
        await substrate.markRestoreFailedForTesting()

        // The exact event flow that used to destroy the store on this path.
        await substrate.ingest(CognitiveEvent(
            id: "wake", kind: .appWake,
            subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
            sourceClass: .observed, occurredAt: now, summary: "app woke", importance: 0.3))
        await #expect(throws: CognitivePersistenceError.self) {
            try await substrate.persistSnapshot()
        }

        let survived = try await store.loadNodes()
        #expect(survived.contains { $0.summary.contains("must survive") },
                "a failed restore must never wipe the store: \(survived.map(\.summary))")

        // And a CLEAN restore resets the freeze: persistence works again.
        try await substrate.restorePersistentState()
        await substrate.ingest(CognitiveEvent(
            id: "hello", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "s:1", label: "t"),
            sourceClass: .userStated, occurredAt: now, summary: "hello there", importance: 0.7))
        try await substrate.persistSnapshot()
        let after = try await store.loadNodes()
        #expect(after.count >= 2, "clean restore must re-enable persistence: \(after.count)")
    }

    /// Legacy stores still carry the flood — prune must purge every "receipt.*"
    /// artifact (their twins live in cognitive_receipts; zero data loss) while her
    /// durable artifacts SURVIVE, even when the mirror noise has pushed the table
    /// far past the cap. This is the exact scenario that erased her standing views.
    @Test func prunePurgesLegacyReceiptMirrorsAndPreservesDurableArtifacts() async throws {
        let store = try CognitiveSQLiteStore(dataRoot: try tempDataRoot())
        let base = Date(timeIntervalSince1970: 33_000_000)

        // Her durable inner life — OLDER than the noise (worst case for a
        // kind-blind oldest-first trim).
        let precious: [(String, UUID)] = [
            ("standing_view", UUID()), ("schema_proposal", UUID()),
            ("thought_seed", UUID()), ("episode", UUID()),
            ("identity_proposal", UUID()), ("developmental_timeline", UUID()),
        ]
        for (i, (kind, id)) in precious.enumerated() {
            try await store.upsertArtifact(
                kind: kind, id: id, status: "active", score: 0.5,
                payload: .object(["kind": .string(kind)]), at: base.addingTimeInterval(Double(i)))
        }
        // The legacy flood: 200 receipt mirrors, all NEWER than her artifacts.
        for i in 0..<200 {
            try await store.upsertArtifact(
                kind: "receipt.cognition.resource_skip", id: UUID(), status: "recorded", score: 0,
                payload: .object([:]), at: base.addingTimeInterval(1_000 + Double(i)))
        }

        // Cap far below the flood: pre-fix, oldest-first would delete ALL 6 precious rows.
        _ = try await store.prune(maxNodes: 256, maxArtifacts: 50)

        #expect(try await store.loadArtifacts(kindPrefix: "receipt.", limit: 300).isEmpty,
                "legacy mirrors must be purged")
        for (kind, _) in precious {
            let survived = try await store.loadArtifacts(kindPrefix: kind, limit: 10)
            #expect(!survived.isEmpty, "\(kind) must survive the prune — this is her inner life")
        }
    }

    /// New generic artifacts can no longer crowd every old durable family out of
    /// the global cap. Each protected family keeps its newest/durable quota before
    /// generic age-based pruning spends any of those rows.
    @Test func globalPruneProtectsEveryDurableArtifactFamilyFromNewerNoise() async throws {
        let store = try CognitiveSQLiteStore(dataRoot: try tempDataRoot())
        let old = Date(timeIntervalSince1970: 40_000_000)
        let precious: [(kind: String, status: String)] = [
            ("episode", "recorded"),
            ("schema_proposal", "proposed"),
            ("standing_view", "active"),
            ("identity_proposal", "accepted"),
            ("developmental_timeline", "recorded"),
            ("thought_seed", "open"),
        ]
        for (index, artifact) in precious.enumerated() {
            try await store.upsertArtifact(
                kind: artifact.kind,
                id: UUID(),
                status: artifact.status,
                score: 0.5,
                payload: .object(["family": .string(artifact.kind)]),
                at: old.addingTimeInterval(Double(index))
            )
        }
        for index in 0..<20 {
            try await store.upsertArtifact(
                kind: "temporary_noise",
                id: UUID(),
                status: "recorded",
                score: 0,
                payload: .object(["index": .int(Int64(index))]),
                at: old.addingTimeInterval(1_000 + Double(index))
            )
        }

        let result = try await store.prune(maxNodes: 256, maxArtifacts: 8)

        #expect(result.deletedArtifacts == 18)
        for artifact in precious {
            #expect(
                try await !store.loadArtifacts(kindPrefix: artifact.kind, limit: 10).isEmpty,
                "protected family \(artifact.kind) must survive generic noise"
            )
        }
        #expect(try await store.loadArtifacts(kindPrefix: "temporary_noise", limit: 100).count == 2)
    }

    @Test func globalPruneKeepsThirtyTwoFeltStateArtifactsPerNamedFamilyBeforeNoise() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let base = Date(timeIntervalSince1970: 43_000_000)

        try await appendArtifacts(store, kind: "affect", count: 32, startingAt: base)
        try await appendArtifacts(store, kind: "disposition", count: 32, startingAt: base.addingTimeInterval(1_000))
        try await appendArtifacts(store, kind: "emotional_consolidation", count: 32, startingAt: base.addingTimeInterval(2_000))
        try await appendArtifacts(store, kind: "temporary_noise", count: 80, startingAt: base.addingTimeInterval(3_000))

        let result = try await store.prune(maxNodes: 256, maxArtifacts: 128)
        #expect(result.deletedArtifacts == 48)
        #expect(try await store.loadArtifacts(kindPrefix: "affect", limit: 64).count == 32)
        #expect(try await store.loadArtifacts(kindPrefix: "disposition", limit: 64).count == 32)
        #expect(try await store.loadArtifacts(kindPrefix: "emotional_consolidation", limit: 64).count == 32)
        #expect(try await store.loadArtifacts(kindPrefix: "temporary_noise", limit: 100).count == 32)
    }

    @Test func feltStateArtifactFloorsNeverEscapeTheHardCap() async throws {
        let root = try tempDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let base = Date(timeIntervalSince1970: 44_000_000)

        try await appendArtifacts(store, kind: "affect", count: 32, startingAt: base)
        try await appendArtifacts(store, kind: "disposition", count: 32, startingAt: base.addingTimeInterval(1_000))
        try await appendArtifacts(store, kind: "emotional_consolidation", count: 32, startingAt: base.addingTimeInterval(2_000))

        let result = try await store.prune(maxNodes: 256, maxArtifacts: 64)
        #expect(result.deletedArtifacts == 32)
        #expect(try await store.loadArtifacts(kindPrefix: "affect", limit: 64).isEmpty)
        #expect(try await store.loadArtifacts(kindPrefix: "disposition", limit: 64).count == 32)
        #expect(try await store.loadArtifacts(kindPrefix: "emotional_consolidation", limit: 64).count == 32)
        let total = try await store.loadArtifacts(limit: 100)
        #expect(total.count == 64)
    }
}
