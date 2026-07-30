import Foundation
import Testing
@testable import Context

private func arenaEntry(
    generation: Int64,
    id: String,
    tier: ContextArenaTier,
    priority: Int = 0,
    access: Int64 = 0,
    overhead: Int = 0,
    text: String = ""
) throws -> ContextArenaEntry {
    try ContextArenaEntry(
        key: ContextArenaEntryKey(
            namespace: "atom",
            id: id,
            sourceFingerprint: "source-\(id)",
            generationID: generation
        ),
        tier: tier,
        text: text,
        retentionPriority: priority,
        lastAccessOrdinal: access,
        cacheOverheadByteCount: overhead
    )
}

private func arenaSnapshot(
    generation: Int64,
    hot: [ContextArenaEntry] = [],
    warm: [ContextArenaEntry] = []
) throws -> ContextGenerationSnapshot {
    try ContextGenerationSnapshot(
        generationID: generation,
        sourceFingerprint: "generation-\(generation)",
        hotEntries: hot,
        warmEntries: warm
    )
}

private func selectionIndexEntry(
    id: String,
    body: String
) -> (ContextAtomID, ContextSelectionIndexEntry) {
    let sourceID = ContextSourceID(rawValue: "source:\(id)")
    let atomID = ContextAtomID(rawValue: "atom:\(id)")
    let atom = ContextAtomDraft(
        id: atomID,
        sourceID: sourceID,
        kind: .memory,
        headingPath: ["Memory"],
        sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
        sourceHash: "hash:\(id)",
        body: body,
        deterministicSummary: "summary \(id)",
        authority: .approved,
        confidence: 1,
        freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 1_000)),
        privacy: .localPrivate,
        permittedSurfaces: [.chat],
        injectionPolicy: .adaptive,
        contentRole: .memory,
        triggers: [id]
    )
    return (atomID, ContextSelectionIndexEntry(atom: atom))
}

@Test func arenaSupportsOnlyApprovedBudgetsAndDefaultsTo96MiB() throws {
    #expect(ContextArenaBudget.allCases.map(\.rawValue) == [32, 64, 96, 128, 256])
    #expect(ContextArenaBudget.default == .mib96)
    #expect(ContextArenaBudget.mib96.byteLimit == 96 * 1_048_576)
    #expect(try ContextArena().budget == .mib96)
}

@Test func arenaEntryAccountsEveryPayloadComponentDeterministically() throws {
    let key = ContextArenaEntryKey(
        namespace: "memory",
        id: "entry",
        sourceFingerprint: "hash",
        generationID: 4
    )
    let text = "text-\u{1F642}"
    let summary = "sum"
    let entry = try ContextArenaEntry(
        key: key,
        tier: .warm,
        text: text,
        summary: summary,
        metadata: Data([1, 2, 3]),
        vector: [1, 2, 3, 4],
        indexBytes: Data([4, 5]),
        cacheOverheadByteCount: 17
    )
    let expected = 96
        + key.namespace.utf8.count
        + key.id.utf8.count
        + key.sourceFingerprint.utf8.count
        + text.utf8.count
        + summary.utf8.count
        + 3
        + (4 * MemoryLayout<Float>.stride)
        + 2
        + 17

    #expect(entry.logicalByteCount == expected)
}

@Test func selectionIndexIsAccountedAndSurvivesWarmPressureTrim() throws {
    let (atomID, indexEntry) = selectionIndexEntry(
        id: "resident-memory",
        body: "User values fast resident context selection."
    )
    let warm = try arenaEntry(
        generation: 1,
        id: atomID.rawValue,
        tier: .warm,
        text: "User values fast resident context selection."
    )
    let baseline = try ContextGenerationSnapshot(
        generationID: 1,
        sourceFingerprint: "generation-1",
        warmEntries: [warm]
    )
    let indexed = try ContextGenerationSnapshot(
        generationID: 1,
        sourceFingerprint: "generation-1",
        warmEntries: [warm],
        selectionIndex: [atomID: indexEntry]
    )
    #expect(indexed.hotLogicalByteCount == baseline.hotLogicalByteCount + indexEntry.logicalByteCount)

    let arena = try ContextArena(budget: .mib32)
    _ = arena.publish(indexed)
    _ = try arena.applyMemoryPressure(.critical)
    let trimmed = try #require(arena.currentSnapshot())
    #expect(trimmed.warmEntries.isEmpty)
    #expect(trimmed.selectionIndex[atomID] == indexEntry)
    #expect(trimmed.hotLogicalByteCount == indexed.hotLogicalByteCount)
}

@Test func generationLeasePinsImmutableSnapshotAcrossPublication() throws {
    let arena = try ContextArena(budget: .mib32)
    let firstEntry = try arenaEntry(generation: 1, id: "first", tier: .warm)
    let secondEntry = try arenaEntry(generation: 2, id: "second", tier: .warm)
    let first = try arenaSnapshot(generation: 1, warm: [firstEntry])
    let second = try arenaSnapshot(generation: 2, warm: [secondEntry])

    #expect(arena.publish(first) == .published(generationID: 1, previousGenerationID: nil))
    let lease = try arena.acquireSnapshot()
    #expect(arena.publish(second) == .published(generationID: 2, previousGenerationID: 1))

    #expect(lease.snapshot.generationID == 1)
    #expect(lease.snapshot.entry(for: firstEntry.key) == firstEntry)
    #expect(arena.currentSnapshot()?.generationID == 2)
    #expect(arena.metrics().pinnedGenerations == [1: 1])
    #expect(arena.metrics().retainedLeaseLogicalBytes == first.logicalByteCount)

    lease.release()
    lease.release()
    #expect(lease.isReleased)
    #expect(arena.metrics().activeLeaseCount == 0)
    #expect(arena.metrics().retainedLeaseLogicalBytes == 0)
}

@Test func failedPublicationRetainsLastGoodSnapshot() throws {
    let arena = try ContextArena(budget: .mib32)
    let good = try arenaSnapshot(generation: 1)
    #expect(arena.publish(good) == .published(generationID: 1, previousGenerationID: nil))

    let oversizedEntry = try arenaEntry(
        generation: 2,
        id: "oversized",
        tier: .warm,
        overhead: ContextArenaBudget.mib32.byteLimit
    )
    let oversized = try arenaSnapshot(generation: 2, warm: [oversizedEntry])
    let outcome = arena.publish(oversized)

    guard case .retainedLastGood(
        failure: .logicalBudgetExceeded(let actual, let limit),
        generationID: 1
    ) = outcome else {
        Issue.record("expected oversized candidate to retain generation 1")
        return
    }
    #expect(actual > limit)
    #expect(limit == ContextArenaBudget.mib32.byteLimit)
    #expect(arena.currentSnapshot() == good)

    let staleOutcome = arena.publish(try arenaSnapshot(generation: 1))
    #expect(
        staleOutcome == .retainedLastGood(
            failure: .generationNotNewer(candidate: 1, current: 1),
            generationID: 1
        )
    )

    enum BuildFailure: Error { case malformed }
    let buildOutcome = arena.attemptPublication { () -> ContextGenerationSnapshot in
        throw BuildFailure.malformed
    }
    guard case .retainedLastGood(failure: .buildFailed, generationID: 1) = buildOutcome else {
        Issue.record("expected build failure to retain generation 1")
        return
    }
    #expect(arena.currentSnapshot() == good)
}

@Test func warningTrimIsDeterministicAndTargetsHalfBudget() throws {
    let arena = try ContextArena(budget: .mib32)
    let tenMiB = 10 * 1_048_576
    let first = try arenaEntry(
        generation: 1,
        id: "first",
        tier: .warm,
        priority: 0,
        access: 20,
        overhead: tenMiB
    )
    let second = try arenaEntry(
        generation: 1,
        id: "second",
        tier: .warm,
        priority: 1,
        access: 10,
        overhead: tenMiB
    )
    let retained = try arenaEntry(
        generation: 1,
        id: "retained",
        tier: .warm,
        priority: 2,
        access: 0,
        overhead: tenMiB
    )
    let snapshot = try arenaSnapshot(generation: 1, warm: [retained, second, first])
    #expect(snapshot.logicalByteCount < ContextArenaBudget.mib32.byteLimit)
    _ = arena.publish(snapshot)

    let receipt = try arena.applyMemoryPressure(.warning)
    let current = try #require(arena.currentSnapshot())

    #expect(receipt.targetLogicalBytes == ContextArenaBudget.mib32.byteLimit / 2)
    #expect(receipt.evictedWarmEntryKeys == [first.key, second.key])
    #expect(current.warmEntries.map(\.key) == [retained.key])
    #expect(current.logicalByteCount <= receipt.targetLogicalBytes)
    #expect(current.hotLogicalByteCount == snapshot.hotLogicalByteCount)
    #expect(!arena.metrics().prewarmingAllowed)
}

@Test func criticalPressureRetainsHotTierAndActiveLease() throws {
    let arena = try ContextArena(budget: .mib32)
    let hot = try arenaEntry(generation: 1, id: "identity", tier: .hot, text: "required")
    let warm = try arenaEntry(
        generation: 1,
        id: "project",
        tier: .warm,
        overhead: 2 * 1_048_576
    )
    let snapshot = try arenaSnapshot(generation: 1, hot: [hot], warm: [warm])
    _ = arena.publish(snapshot)
    let lease = try arena.acquireSnapshot()

    let receipt = try arena.applyMemoryPressure(.critical)
    let current = try #require(arena.currentSnapshot())
    let metrics = arena.metrics()

    #expect(receipt.evictedWarmEntryKeys == [warm.key])
    #expect(current.hotEntries == [hot])
    #expect(current.warmEntries.isEmpty)
    #expect(current.logicalByteCount == current.hotLogicalByteCount)
    #expect(lease.snapshot.warmEntries == [warm])
    #expect(metrics.pinnedGenerations == [1: 1])
    #expect(metrics.retainedLeaseLogicalBytes == snapshot.logicalByteCount)
    #expect(metrics.residentLogicalBytes == current.logicalByteCount + snapshot.logicalByteCount)
    #expect(!metrics.prewarmingAllowed)

    lease.release()
    let recovery = try arena.applyMemoryPressure(.normal)
    #expect(recovery.evictedWarmEntryKeys.isEmpty)
    #expect(arena.metrics().prewarmingAllowed)
    #expect(arena.currentSnapshot()?.warmEntries.isEmpty == true)
}

@Test func normalPressureRehydratesSameGenerationWithoutInvalidatingLease() throws {
    let arena = try ContextArena(budget: .mib32)
    let hot = try arenaEntry(generation: 1, id: "identity", tier: .hot, text: "required")
    let warm = try arenaEntry(generation: 1, id: "project", tier: .warm, text: "working set")
    let full = try arenaSnapshot(generation: 1, hot: [hot], warm: [warm])
    _ = arena.publish(full)
    let lease = try arena.acquireSnapshot()

    _ = try arena.applyMemoryPressure(.critical)
    #expect(arena.currentSnapshot()?.warmEntries.isEmpty == true)
    _ = try arena.applyMemoryPressure(.normal)
    #expect(arena.rehydrate(full) == .rehydrated(generationID: 1))
    #expect(arena.currentSnapshot() == full)
    #expect(lease.snapshot == full)
    #expect(arena.metrics().pinnedGenerations == [1: 1])
    lease.release()
}

@Test func rehydrationRejectsMismatchedFingerprintAndPressure() throws {
    let arena = try ContextArena(budget: .mib32)
    let full = try arenaSnapshot(generation: 1)
    _ = arena.publish(full)

    let mismatched = try ContextGenerationSnapshot(
        generationID: 1,
        sourceFingerprint: "different"
    )
    #expect(
        arena.rehydrate(mismatched) == .retainedLastGood(
            failure: .rehydrationFingerprintMismatch(
                candidate: "different",
                current: full.sourceFingerprint
            ),
            generationID: 1
        )
    )

    _ = try arena.applyMemoryPressure(.warning)
    #expect(
        arena.rehydrate(full) == .retainedLastGood(
            failure: .prewarmingDisabled(.warning),
            generationID: 1
        )
    )
}

@Test func hotTierLimitRejectsCandidateWithoutDisplacingLastGood() throws {
    let arena = try ContextArena(budget: .mib32, hotTierByteLimit: 512)
    let good = try arenaSnapshot(generation: 1)
    _ = arena.publish(good)
    let hot = try arenaEntry(
        generation: 2,
        id: "large-hot",
        tier: .hot,
        overhead: 512
    )
    let candidate = try arenaSnapshot(generation: 2, hot: [hot])
    let outcome = arena.publish(candidate)

    guard case .retainedLastGood(
        failure: .hotTierLimitExceeded(let actual, let limit),
        generationID: 1
    ) = outcome else {
        Issue.record("expected hot tier rejection")
        return
    }
    #expect(actual > limit)
    #expect(limit == 512)
    #expect(arena.currentSnapshot() == good)
}
