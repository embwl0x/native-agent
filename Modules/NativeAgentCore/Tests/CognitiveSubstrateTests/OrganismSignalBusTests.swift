import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private actor SomaticSignalCapture: SomaticSignalObserving {
    private var signals: [SomaticSignal] = []

    func observe(_ signal: SomaticSignal) async {
        signals.append(signal)
    }

    func all() -> [SomaticSignal] {
        signals
    }
}

private final class SomaticBusTestUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> UUID {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index))!
    }
}

private func cognitiveEvent(
    kind: CognitiveEventKind,
    summary: String = "event",
    importance: Double = 0.6,
    turnKind: CognitiveTurnKind? = nil,
    subject: CognitiveSubjectReference = CognitiveSubjectReference(type: "test", id: "subject", label: "subject"),
    metadata: [String: JSONValue] = [:]
) -> CognitiveEvent {
    CognitiveEvent(
        id: "event-\(kind.rawValue)-\(summary.hashValue)",
        kind: kind,
        subject: subject,
        sourceClass: .observed,
        occurredAt: Date(timeIntervalSince1970: 2_000),
        summary: summary,
        importance: importance,
        turnKind: turnKind,
        metadata: metadata
    )
}

@Test func cognitiveEventsMapToSomaticSignals() async throws {
    let cases: [(CognitiveEvent, SomaticSignalKind)] = [
        (cognitiveEvent(kind: .userMessageReceived, summary: "thank you, this is great", turnKind: .live), .userSpoke),
        (cognitiveEvent(kind: .assistantTurnCompleted, turnKind: .live), .assistantSpoke),
        (cognitiveEvent(kind: .toolStarted), .toolStarted),
        (cognitiveEvent(kind: .toolSucceeded), .toolSucceeded),
        (cognitiveEvent(kind: .toolFailed), .toolFailed),
        (cognitiveEvent(kind: .toolCancelled), .toolCancelled),
        (cognitiveEvent(kind: .userCorrection, turnKind: .live), .correctionReceived),
        (cognitiveEvent(kind: .providerFailure), .providerFailed),
        (cognitiveEvent(kind: .workshopExecutionCompleted, metadata: ["status": .string("completed")]), .deskItemClosed),
        (cognitiveEvent(kind: .workshopExecutionCompleted, metadata: ["status": .string("failed")]), .deskItemBlocked),
        (cognitiveEvent(kind: .appWake), .appWake),
        (cognitiveEvent(kind: .appSleep), .appSleep),
    ]

    for (index, testCase) in cases.enumerated() {
        let signal = try #require(CognitiveSomaticSignalAdapter.signal(
            from: testCase.0,
            id: UUID(uuidString: String(format: "31000000-0000-0000-0000-%012d", index))!
        ))
        #expect(signal.kind == testCase.1)
        #expect(signal.intensity == testCase.0.importance)
        #expect(signal.metadata["cognitiveEventKind"] == .string(testCase.0.kind.rawValue))
    }
}

@Test func canonicalMotorMetadataBecomesExactSomaticCorrelation() throws {
    let identity = String(repeating: "a", count: 64)
    let event = cognitiveEvent(
        kind: .toolStarted,
        metadata: [
            "motorDomain": .string("workshop"),
            "motorActionIdentity": .string(identity),
            "verification": .string("pending"),
        ]
    )

    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "32000000-0000-0000-0000-000000000002")!
    ))
    #expect(signal.sourceOrgan == "tool.workshop")
    #expect(signal.metadata["motorDomain"] == .string("workshop"))
    #expect(signal.metadata["motorActionIdentity"] == .string(identity))
    #expect(signal.metadata["predictionCorrelationId"] == .string(identity))
}

@Test func chatEventCarriesTopologyWithoutReappraisingRawText() async throws {
    let event = cognitiveEvent(
        kind: .userMessageReceived,
        summary: "I love this, thank you",
        turnKind: .live,
        metadata: ["surface": .string("telegram"), "sessionId": .string("session-1")]
    )

    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "32000000-0000-0000-0000-000000000001")!
    ))

    #expect(signal.kind == .userSpoke)
    #expect(signal.valence == nil)
    #expect(signal.sourceOrgan == "chat.telegram")
    #expect(signal.metadata["summary"] == nil)
    #expect(signal.metadata["summaryCharacters"] == .int(Int64(event.summary.count)))
}

@Test func assistantCompletionDoesNotManufacturePositiveSomaticValence() throws {
    let event = cognitiveEvent(
        kind: .assistantTurnCompleted,
        summary: "Everything is great and complete",
        turnKind: .live
    )

    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "32000000-0000-0000-0000-000000000002")!
    ))

    #expect(signal.valence == nil)
}

@Test func debugAndVerificationEventsDoNotBecomeSomaticSignals() async throws {
    let debug = cognitiveEvent(kind: .userMessageReceived, summary: "debug probe", turnKind: .debug)
    let verification = cognitiveEvent(kind: .assistantTurnCompleted, summary: "verification ping", turnKind: .verification)

    #expect(CognitiveSomaticSignalAdapter.signal(
        from: debug,
        id: UUID(uuidString: "33000000-0000-0000-0000-000000000001")!
    ) == nil)
    #expect(CognitiveSomaticSignalAdapter.signal(
        from: verification,
        id: UUID(uuidString: "33000000-0000-0000-0000-000000000002")!
    ) == nil)
}

@Test func cognitiveProviderFailurePreservesUncorrelatedBodyEvidence() {
    let failure = cognitiveEvent(kind: .providerFailure)
    #expect(CognitiveSomaticSignalAdapter.signal(
        from: failure,
        id: UUID(uuidString: "33000000-0000-0000-0000-000000000003")!
    )?.kind == .providerFailed)
}

@Test func providerLifecycleOwnedCognitiveFailureDoesNotDuplicateSomaticEvidence() {
    let failure = cognitiveEvent(
        kind: .providerFailure,
        metadata: [
            CognitiveSomaticSignalAdapter.somaticOwnerMetadataKey: .string(
                CognitiveSomaticSignalAdapter.providerLifecycleSomaticOwner
            ),
        ]
    )
    #expect(CognitiveSomaticSignalAdapter.signal(
        from: failure,
        id: UUID(uuidString: "33000000-0000-0000-0000-000000000004")!
    ) == nil)
}

@Test func adapterBoundsAndRedactsSignalMetadata() async throws {
    let event = cognitiveEvent(
        kind: .toolStarted,
        summary: String(repeating: "secret ", count: 200),
        subject: CognitiveSubjectReference(type: "tool", id: "Bearer secret-token", label: "sk-test-secret"),
        metadata: [
            "toolName": .string("sk-test-secret"),
            "surface": .string("telegram"),
            "sessionId": .string(String(repeating: "a", count: 60)),
        ]
    )

    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "34000000-0000-0000-0000-000000000001")!,
        bounds: OrganismMetadataBounds(maximumKeys: 20, maximumStringCharacters: 12, maximumArrayItems: 2, maximumDepth: 2)
    ))

    #expect(signal.metadata["subjectId"] == .string("[redacted]"))
    #expect(signal.metadata["subjectLabel"] == .string("[redacted]"))
    #expect(signal.metadata["toolName"] == .string("[redacted]"))
    #expect(signal.metadata["sessionId"] == .string("aaaaaaaaaaaa"))
    #expect(signal.metadata["summary"] == nil)
}

@Test func disabledSignalBusDoesNotForward() async throws {
    let capture = SomaticSignalCapture()
    let uuids = SomaticBusTestUUIDs()
    let bus = SomaticSignalBus(
        configuration: .disabled,
        observer: capture,
        dependencies: SomaticSignalBusDependencies(makeUUID: { uuids.next() })
    )

    let returned = await bus.observe(cognitiveEvent(kind: .toolSucceeded))

    #expect(returned == nil)
    #expect(await capture.all().isEmpty)
}

@Test func enabledSignalBusForwardsOneBoundedSignal() async throws {
    let capture = SomaticSignalCapture()
    let uuids = SomaticBusTestUUIDs()
    let bus = SomaticSignalBus(
        configuration: .enabled,
        observer: capture,
        dependencies: SomaticSignalBusDependencies(makeUUID: { uuids.next() })
    )

    let returned = try #require(await bus.observe(cognitiveEvent(
        kind: .toolFailed,
        metadata: ["toolName": .string("shell")]
    )))
    let signals = await capture.all()

    #expect(signals == [returned])
    #expect(returned.kind == .toolFailed)
    #expect(returned.id == UUID(uuidString: "30000000-0000-0000-0000-000000000000")!)
    #expect(returned.metadata["toolName"] == .string("shell"))
}

@Test func duplicateCognitiveEventIsForwardedExactlyOnce() async throws {
    let capture = SomaticSignalCapture()
    let uuids = SomaticBusTestUUIDs()
    let bus = SomaticSignalBus(
        configuration: .enabled,
        observer: capture,
        dependencies: SomaticSignalBusDependencies(makeUUID: { uuids.next() })
    )
    let event = cognitiveEvent(
        kind: .toolFailed,
        summary: "same canonical failure receipt",
        metadata: ["toolName": .string("shell")]
    )

    let first = try #require(await bus.observe(event))
    let duplicate = await bus.observe(event)

    #expect(duplicate == nil)
    #expect(await capture.all() == [first])
}

@Test func signalBusCanFeedKernelWithoutOtherSideEffects() async throws {
    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { Date(timeIntervalSince1970: 2_000) })
    )
    let bus = SomaticSignalBus(
        configuration: .enabled,
        observer: kernel,
        dependencies: SomaticSignalBusDependencies(makeUUID: {
            UUID(uuidString: "35000000-0000-0000-0000-000000000001")!
        })
    )

    _ = await bus.observe(cognitiveEvent(
        kind: .toolFailed,
        importance: 0.8,
        metadata: ["toolName": .string("shell")]
    ))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.signalCount == 1)
    #expect(snapshot.chemicalState.vigilance > ChemicalState.neutral.vigilance)
}
