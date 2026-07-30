import Foundation
import Testing
import CognitiveSubstrate
import PersistenceCore
@testable import NativeAgentApp

private func dreamRunResponse(
    entriesWritten: Int,
    sessionsProcessed: Int = 0,
    disabled: Bool = false,
    errors: [String] = []
) -> [String: Any] {
    [
        "entriesWritten": entriesWritten,
        "sessionsProcessed": sessionsProcessed,
        "disabled": disabled,
        "errors": errors,
    ]
}

private func organismSnapshotsAfterDreamReport(
    _ response: [String: Any]
) async -> (
    metadata: [String: JSONValue]?,
    before: OrganismSnapshot,
    after: OrganismSnapshot
) {
    let now = Date(timeIntervalSince1970: 10_000)
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(
            now: { now },
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000042")! }
        )
    )
    let before = await kernel.snapshot()
    let metadata = NativeClient.dreamCompletionMetadataIfCommitted(response, force: false)
    if let metadata {
        await kernel.ingest(SomaticSignal(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            occurredAt: now,
            intensity: 0.62,
            valence: 0.35,
            arousal: 0.12,
            metadata: metadata
        ))
    }
    return (metadata, before, await kernel.snapshot())
}

private func assertDreamReportDoesNotMoveOrganism(_ response: [String: Any]) async {
    let result = await organismSnapshotsAfterDreamReport(response)

    #expect(result.metadata == nil)
    #expect(result.after.signalCount == result.before.signalCount)
    #expect(result.after.chemicalState == result.before.chemicalState)
    #expect(result.after.dreamRepairSummary == result.before.dreamRepairSummary)
}

@Test func disabledDreamReportDoesNotEmitOrganismCompletion() async {
    await assertDreamReportDoesNotMoveOrganism(
        dreamRunResponse(entriesWritten: 0, disabled: true)
    )
}

@Test func existingDreamEntryReportDoesNotEmitOrganismCompletion() async {
    await assertDreamReportDoesNotMoveOrganism(
        dreamRunResponse(entriesWritten: 0)
    )
}

@Test func emptyDreamNoOpReportDoesNotEmitOrganismCompletion() async {
    await assertDreamReportDoesNotMoveOrganism(
        dreamRunResponse(entriesWritten: 0, sessionsProcessed: 0)
    )
}

@Test func failedDreamReportDoesNotEmitOrganismCompletion() async {
    await assertDreamReportDoesNotMoveOrganism(
        dreamRunResponse(entriesWritten: 0, sessionsProcessed: 2, errors: ["llm error: network timeout"])
    )
}

@Test func committedDreamReportEmitsOrganismCompletionAndRepair() async throws {
    let result = await organismSnapshotsAfterDreamReport(
        dreamRunResponse(entriesWritten: 1, sessionsProcessed: 2)
    )

    let metadata = try #require(result.metadata)
    #expect(metadata["entriesWritten"] == .int(1))
    #expect(metadata["sessionsProcessed"] == .int(2))
    #expect(metadata["force"] == .bool(false))
    #expect(result.after.signalCount == result.before.signalCount + 1)
    #expect(result.after.chemicalState != result.before.chemicalState)
    #expect(result.after.bodySchema.dreamHealthy)
    #expect(result.after.dreamRepairSummary.receiptCount == result.before.dreamRepairSummary.receiptCount + 1)
    #expect(result.after.dreamRepairSummary.lastReason == SomaticSignalKind.dreamCompleted.rawValue)
}
