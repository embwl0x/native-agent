import Foundation
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

private final class NonLiveIsolationUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> UUID {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return UUID(uuidString: String(format: "41000000-0000-0000-0000-%012d", index))!
    }
}

private func nonLiveIsolationSubstrate(maximumActiveNodes: Int) -> CognitiveSubstrate {
    let now = Date(timeIntervalSince1970: 20_000)
    let uuids = NonLiveIsolationUUIDs()
    return CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            affectEnabled: false,
            maximumActiveNodes: maximumActiveNodes,
            defaultDecayHalfLife: 3_600
        ),
        dependencies: CognitiveSubstrateDependencies(
            now: { now },
            makeUUID: { uuids.next() }
        )
    )
}

private func nonLiveIsolationEvent(
    id: String,
    subject: CognitiveSubjectReference,
    summary: String,
    importance: Double,
    turnKind: CognitiveTurnKind
) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: subject,
        sourceClass: .userStated,
        occurredAt: Date(timeIntervalSince1970: 20_000),
        summary: summary,
        importance: importance,
        turnKind: turnKind,
        metadata: [
            "sessionId": .string("continuity-isolation"),
            "surface": .string(turnKind == .live ? "chat" : "codex_bridge"),
        ]
    )
}

private func livedNodes(_ substrate: CognitiveSubstrate) async -> [CognitiveNode] {
    await substrate.snapshot().nodes.filter(\.turnKind.contributesToLivedState)
}

@Test func nonLiveIngestDoesNotAdvanceLivedDecayCheckpoint() throws {
    let startedAt = Date(timeIntervalSince1970: 20_000)
    let configuration = CognitiveConfiguration(
        enabled: true,
        maximumActiveNodes: 8,
        defaultDecayHalfLife: 100
    )
    let uuids = NonLiveIsolationUUIDs()
    var field = ContinuityField()
    let liveSubject = CognitiveSubjectReference(type: "project", id: "decay", label: "Decay")
    _ = field.ingest(
        nonLiveIsolationEvent(
            id: "live-decay-checkpoint",
            subject: liveSubject,
            summary: "Keep this live checkpoint unchanged by diagnostics.",
            importance: 1,
            turnKind: .live
        ),
        now: startedAt,
        makeUUID: { uuids.next() },
        configuration: configuration
    )
    let before = try #require(field.peekNodes().first { $0.turnKind == .live })

    _ = field.ingest(
        nonLiveIsolationEvent(
            id: "debug-decay-checkpoint",
            subject: CognitiveSubjectReference(type: "diagnostic", id: "decay", label: "Decay Audit"),
            summary: "[from: codex, via bridge] Inspect after one half-life.",
            importance: 1,
            turnKind: .debug
        ),
        now: startedAt.addingTimeInterval(100),
        makeUUID: { uuids.next() },
        configuration: configuration
    )

    let after = try #require(field.peekNodes().first { $0.turnKind == .live })
    #expect(after == before)
    #expect(field.peekNodes().contains { $0.turnKind == .debug })
}

@Test func debugSameSubjectCannotReactivateOrRewriteLiveContinuity() async throws {
    let substrate = nonLiveIsolationSubstrate(maximumActiveNodes: 8)
    let subject = CognitiveSubjectReference(
        type: "project",
        id: "orchid-lighthouse",
        label: "Orchid Lighthouse"
    )
    await substrate.ingest(nonLiveIsolationEvent(
        id: "live-orchid",
        subject: subject,
        summary: "Keep the orchid lighthouse calibration in active attention.",
        importance: 0.8,
        turnKind: .live
    ))
    let beforeNodes = await livedNodes(substrate)
    let beforeAttention = await substrate.attentionSignals(at: Date(timeIntervalSince1970: 20_000))

    await substrate.ingest(nonLiveIsolationEvent(
        id: "debug-orchid",
        subject: subject,
        summary: "[from: codex, via bridge] Replace the orchid focus with diagnostic prose.",
        importance: 1,
        turnKind: .debug
    ))

    let snapshot = await substrate.snapshot()
    #expect(await livedNodes(substrate) == beforeNodes)
    #expect(await substrate.attentionSignals(at: Date(timeIntervalSince1970: 20_000)) == beforeAttention)
    #expect(snapshot.nodes.count == 2)
    #expect(snapshot.nodes.contains {
        $0.turnKind == .live
            && $0.subjectReference == subject
            && $0.summary == "Keep the orchid lighthouse calibration in active attention."
    })
    #expect(snapshot.nodes.contains {
        $0.turnKind == .debug
            && $0.subjectReference == subject
            && $0.summary.contains("diagnostic prose")
    })
}

@Test func nonLiveCapacityPressureEvictsAuditBeforeLiveAttention() async throws {
    let substrate = nonLiveIsolationSubstrate(maximumActiveNodes: 3)
    let firstLive = CognitiveSubjectReference(type: "project", id: "orchid", label: "Orchid")
    let secondLive = CognitiveSubjectReference(type: "project", id: "harbor", label: "Harbor")
    await substrate.ingest(nonLiveIsolationEvent(
        id: "live-orchid-capacity",
        subject: firstLive,
        summary: "Orchid calibration remains the primary work focus.",
        importance: 0.9,
        turnKind: .live
    ))
    await substrate.ingest(nonLiveIsolationEvent(
        id: "live-harbor-capacity",
        subject: secondLive,
        summary: "Harbor telemetry remains a secondary work focus.",
        importance: 0.45,
        turnKind: .live
    ))
    let beforeNodes = await livedNodes(substrate)
    let fixedAt = Date(timeIntervalSince1970: 20_000)
    let beforeAttention = await substrate.attentionSignals(at: fixedAt)

    let oldAuditSubject = CognitiveSubjectReference(type: "diagnostic", id: "old", label: "Old Audit")
    await substrate.ingest(nonLiveIsolationEvent(
        id: "debug-old-audit",
        subject: oldAuditSubject,
        summary: "[from: codex, via bridge] Low-priority diagnostic evidence.",
        importance: 0.1,
        turnKind: .debug
    ))
    let atCapacity = await substrate.snapshot()
    #expect(atCapacity.nodes.contains { $0.turnKind == .debug && $0.subjectReference == oldAuditSubject })
    #expect(await livedNodes(substrate) == beforeNodes)
    #expect(await substrate.attentionSignals(at: fixedAt) == beforeAttention)

    let newestAuditSubject = CognitiveSubjectReference(type: "diagnostic", id: "new", label: "New Audit")
    await substrate.ingest(nonLiveIsolationEvent(
        id: "verification-new-audit",
        subject: newestAuditSubject,
        summary: "Verification ping: retain the newest bounded diagnostic evidence.",
        importance: 1,
        turnKind: .verification
    ))

    let saturated = await substrate.snapshot()
    #expect(saturated.nodes.count == 3)
    #expect(await livedNodes(substrate) == beforeNodes)
    #expect(await substrate.attentionSignals(at: fixedAt) == beforeAttention)
    #expect(saturated.nodes.contains { $0.turnKind == .verification && $0.subjectReference == newestAuditSubject })
    #expect(!saturated.nodes.contains { $0.turnKind == .debug && $0.subjectReference == oldAuditSubject })
}
