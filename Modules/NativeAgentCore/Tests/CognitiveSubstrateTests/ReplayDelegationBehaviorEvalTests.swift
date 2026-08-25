import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// EVAL FENCE: core.substrate.field
// Ledger row: substrate.runReplay

private func replayEvalRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cognitive-replay-eval-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func replayEvalConfiguration(persistenceEnabled: Bool = true) -> CognitiveConfiguration {
    CognitiveConfiguration(
        enabled: true,
        persistenceEnabled: persistenceEnabled,
        replayEnabled: true
    )
}

private func replayEvidence(_ now: Date) -> CognitiveEvent {
    CognitiveEvent(
        id: "replay-evidence",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "topic", id: "replay", label: "replay"),
        sourceClass: .userStated,
        occurredAt: now,
        summary: "bounded replay evidence",
        importance: 0.9
    )
}

@Test func runReplay_requiresDurableDelegationReceiptAndReportsEveryNonSuccessState() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let root = try replayEvalRoot("durable")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CognitiveSQLiteStore(dataRoot: root)
    let substrate = CognitiveSubstrate(
        configuration: replayEvalConfiguration(),
        dependencies: CognitiveSubstrateDependencies(now: { now }),
        store: store
    )
    await substrate.ingest(replayEvidence(now))

    let delegated = await substrate.runReplay(reason: "dream/rem handoff")
    guard case .delegatedToDreamREMOwner(let evidenceNodeIDs) = delegated else {
        Issue.record("expected a durable Dream/REM delegation, got \(delegated)")
        return
    }
    #expect(!evidenceNodeIDs.isEmpty)
    let receipt = try #require((await substrate.receiptSnapshot(limit: 8)).first { $0.kind == "replay" })
    #expect(receipt.kind == "replay")
    guard case .object(let payload) = receipt.payload else {
        Issue.record("replay handoff receipt payload was not an object")
        return
    }
    #expect(payload["status"] == .string("delegated-to-dream-rem-owner"))
    #expect(payload["evidenceNodeIds"] == .array(evidenceNodeIDs.map { .string($0.uuidString) }))

    let disabled = CognitiveSubstrate(configuration: .disabled)
    #expect(await disabled.runReplay(reason: "disabled") == .disabled)

    let noEvidence = CognitiveSubstrate(
        configuration: replayEvalConfiguration(),
        store: store
    )
    #expect(await noEvidence.runReplay(reason: "empty") == .unavailable(.noReplayEvidence))

    let persistenceDisabled = CognitiveSubstrate(configuration: replayEvalConfiguration(persistenceEnabled: false))
    await persistenceDisabled.ingest(replayEvidence(now))
    #expect(await persistenceDisabled.runReplay(reason: "no-persistence") == .unavailable(.persistenceDisabled))

    let missingStore = CognitiveSubstrate(configuration: replayEvalConfiguration())
    await missingStore.ingest(replayEvidence(now))
    #expect(await missingStore.runReplay(reason: "missing-store") == .unavailable(.storeUnavailable))

    await substrate.markRestoreFailedForTesting()
    #expect(await substrate.runReplay(reason: "writes-blocked") == .adverse(.persistenceWritesBlocked))
    #expect((await substrate.receiptSnapshot(limit: 8)).filter { $0.kind == "replay" }.count == 1)
}
