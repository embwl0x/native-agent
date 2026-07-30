import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// INTEROCEPTION — proof that the graded `.providerVitalsShift` CognitiveEvent
// rides the EXISTING provider somatic axis (no new SomaticSignalKind, no new
// capsule slot). Worsening → `.providerFailed` (its grade carried by intensity);
// recovering → `.providerRecovered`.

private func vitalsShift(
    direction: String,
    importance: Double,
    providerId: String = "moonshot",
    band: String = "degraded"
) -> CognitiveEvent {
    CognitiveEvent(
        id: "vitals-\(direction)-\(band)-\(providerId)",
        kind: .providerVitalsShift,
        subject: CognitiveSubjectReference(type: "provider", id: providerId, label: providerId),
        sourceClass: .observed,
        occurredAt: Date(timeIntervalSince1970: 3_000),
        summary: "\(providerId) provider band \(band)",
        importance: importance,
        metadata: [
            "vitalsDirection": .string(direction),
            "band": .string(band),
            "providerId": .string(providerId),
        ]
    )
}

@Test func vitalsShiftWorseningRidesProviderFailedAxis() throws {
    let event = vitalsShift(direction: "worsening", importance: 0.75)
    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
    ))
    // Existing axis — NOT a new somatic kind.
    #expect(signal.kind == .providerFailed)
    // Grade rides intensity (degraded importance > sluggish importance).
    #expect(signal.intensity == 0.75)
    // Source names the specific provider so the felt state is per-provider.
    #expect(signal.sourceOrgan == "provider.moonshot")
    #expect(signal.metadata["cognitiveEventKind"] == .string("providerVitalsShift"))
}

@Test func vitalsShiftSluggishGradesBelowDegraded() throws {
    let sluggish = try #require(CognitiveSomaticSignalAdapter.signal(
        from: vitalsShift(direction: "worsening", importance: 0.5, band: "sluggish"),
        id: UUID(uuidString: "41000000-0000-0000-0000-000000000002")!
    ))
    let degraded = try #require(CognitiveSomaticSignalAdapter.signal(
        from: vitalsShift(direction: "worsening", importance: 0.75, band: "degraded"),
        id: UUID(uuidString: "41000000-0000-0000-0000-000000000003")!
    ))
    #expect(sluggish.kind == .providerFailed)
    #expect(degraded.kind == .providerFailed)
    // Same axis, graded value: sluggishness is felt more mildly than degradation.
    #expect(sluggish.intensity < degraded.intensity)
}

@Test func vitalsShiftRecoveringReadsAsRelief() throws {
    let event = vitalsShift(direction: "recovering", importance: 0.4, band: "nominal")
    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "41000000-0000-0000-0000-000000000004")!
    ))
    #expect(signal.kind == .providerRecovered)
    #expect((signal.valence ?? 0) > 0)
}

@Test func vitalsShiftAbsentDirectionFailsLoudToWorsening() throws {
    // A shift with no legible direction is treated as the concerning case.
    let event = CognitiveEvent(
        id: "vitals-nodir",
        kind: .providerVitalsShift,
        subject: CognitiveSubjectReference(type: "provider", id: "anthropic", label: "anthropic"),
        sourceClass: .observed,
        occurredAt: Date(timeIntervalSince1970: 3_000),
        summary: "band shift",
        importance: 0.6,
        metadata: ["providerId": .string("anthropic")]
    )
    let signal = try #require(CognitiveSomaticSignalAdapter.signal(
        from: event,
        id: UUID(uuidString: "41000000-0000-0000-0000-000000000005")!
    ))
    #expect(signal.kind == .providerFailed)
}
