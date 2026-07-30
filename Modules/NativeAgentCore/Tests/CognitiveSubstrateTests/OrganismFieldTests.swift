import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private func fieldSignal(
    _ kind: SomaticSignalKind,
    sourceOrgan: String = "test",
    id: UUID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
    at date: Date = Date(timeIntervalSince1970: 2_000),
    intensity: Double = 1,
    valence: Double? = nil,
    arousal: Double? = nil,
    metadata: [String: JSONValue] = [:]
) -> SomaticSignal {
    SomaticSignal(
        id: id,
        kind: kind,
        sourceOrgan: sourceOrgan,
        occurredAt: date,
        intensity: intensity,
        valence: valence,
        arousal: arousal,
        metadata: metadata
    )
}

private func applyToField(
    _ signal: SomaticSignal,
    field: OrganismField,
    bodySchema: BodySchema = .neutral,
    limits: OrganismFieldLimits = .defaults
) -> OrganismField {
    let chemistry = OrganismChemistry.applying(
        signal: signal,
        to: .neutral,
        bodySchema: bodySchema
    )
    return OrganismPlasticity.applying(
        signal: signal,
        chemicalState: chemistry.chemicalState,
        bodySchema: chemistry.bodySchema,
        to: field,
        limits: limits
    )
}

@Test func repeatedCoActivationStrengthensEdge() async throws {
    let firstSignal = fieldSignal(.toolSucceeded, at: Date(timeIntervalSince1970: 2_000))
    let secondSignal = fieldSignal(.toolSucceeded, at: Date(timeIntervalSince1970: 2_010))

    let firstField = applyToField(firstSignal, field: .empty)
    let secondField = applyToField(secondSignal, field: firstField)

    let firstEdge = try #require(firstField.edge(sourceID: "organ:test", targetID: "signal:toolSucceeded"))
    let secondEdge = try #require(secondField.edge(sourceID: "organ:test", targetID: "signal:toolSucceeded"))
    #expect(secondEdge.weight > firstEdge.weight)
    #expect(secondEdge.coActivations == firstEdge.coActivations + 1)
}

@Test func edgeCapIsDeterministic() async throws {
    let baseDate = Date(timeIntervalSince1970: 2_000)
    let signals: [SomaticSignal] = [
        fieldSignal(.providerFailed, sourceOrgan: "provider", at: baseDate),
        fieldSignal(.toolSucceeded, sourceOrgan: "tools", at: baseDate.addingTimeInterval(1)),
        fieldSignal(.memoryCommitted, sourceOrgan: "memory", at: baseDate.addingTimeInterval(2)),
        fieldSignal(.iPhoneStale, sourceOrgan: "phone", at: baseDate.addingTimeInterval(3)),
    ]
    let limits = OrganismFieldLimits(maximumNodes: 64, maximumEdges: 3)

    func build() -> OrganismField {
        signals.reduce(OrganismField.empty) { field, signal in
            applyToField(signal, field: field, limits: limits)
        }
    }

    let first = build()
    let second = build()
    #expect(first.edges.count == 3)
    #expect(first.edges.keys.sorted() == second.edges.keys.sorted())
}

@Test func correctionLeavesBoundedTraceInsteadOfDeletingEdge() async throws {
    let first = fieldSignal(.correctionReceived, at: Date(timeIntervalSince1970: 2_000))
    let second = fieldSignal(.correctionReceived, at: Date(timeIntervalSince1970: 2_010))

    let firstField = applyToField(first, field: .empty)
    let secondField = applyToField(second, field: firstField)

    let firstEdge = try #require(firstField.edge(sourceID: "organ:test", targetID: "signal:correctionReceived"))
    let secondEdge = try #require(secondField.edge(sourceID: "organ:test", targetID: "signal:correctionReceived"))
    #expect(secondEdge.weight > 0)
    #expect(secondEdge.coActivations == firstEdge.coActivations + 1)
    #expect(secondEdge.uncertainty > firstEdge.uncertainty)
}

@Test func sleepSignalSoftensHighCharge() async throws {
    let date = Date(timeIntervalSince1970: 2_000)
    let failure = fieldSignal(.providerFailed, at: date, intensity: 1)
    let charged = applyToField(failure, field: .empty)
    let chargedSummary = charged.summary()

    let sleep = fieldSignal(.appSleep, at: date.addingTimeInterval(30), intensity: 1)
    let repaired = applyToField(sleep, field: charged)

    #expect(repaired.summary().totalCharge < chargedSummary.totalCharge)
}

@Test func kernelSignalsUpdateFieldSummary() async throws {
    let kernel = OrganismKernel(configuration: .enabled)

    await kernel.ingest(fieldSignal(.toolSucceeded, at: Date(timeIntervalSince1970: 2_000)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.fieldSummary.nodeCount > 0)
    #expect(snapshot.fieldSummary.edgeCount > 0)
    #expect(snapshot.fieldSummary.strongestEdgeWeight > 0)
}

@Test func disabledKernelKeepsFieldSummaryEmpty() async throws {
    let kernel = OrganismKernel(configuration: .disabled)

    await kernel.ingest(fieldSignal(.toolSucceeded, at: Date(timeIntervalSince1970: 2_000)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.enabled == false)
    #expect(snapshot.fieldSummary == .empty)
}

@Test func clearTransientStateClearsPlasticField() async throws {
    let kernel = OrganismKernel(configuration: .enabled)

    await kernel.ingest(fieldSignal(.toolSucceeded, at: Date(timeIntervalSince1970: 2_000)))
    await kernel.clearTransientState()
    let snapshot = await kernel.snapshot()

    #expect(snapshot.fieldSummary == .empty)
    #expect(snapshot.signalCount == 0)
}
