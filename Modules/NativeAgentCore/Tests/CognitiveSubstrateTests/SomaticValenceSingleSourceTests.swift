import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger fence core.substrate.organism —
//   somatic.signalKind.canonicalValence
//   somatic.adapterSuppressesIntrinsicValence
//
// SomaticSignalValence.swift exists BECAUSE two per-kind valence tables drifted
// (audit C10: toolFailed −0.55 in the adapter vs −0.50 in the organism field).
// Nothing asserted that the adapter and the field still read the SAME table, and
// `adapterSuppressesIntrinsicValence` carries a `default: return false`, so a NEW
// SomaticSignalKind silently opts INTO having the adapter stamp an intrinsic
// valence — the exact double-counting the file was written to prevent, and the
// compiler cannot catch it.
//
// These evals assert envelope properties, not vibes:
//   1. the frozen table is EXHAUSTIVE over SomaticSignalKind.allCases in both
//      directions — a new kind fails until someone writes its row deliberately.
//   2. canonicalValence == the frozen number (the contractual table).
//   3. the suppression SET == a frozen explicit allowlist (defeats default:false).
//   4. the ADAPTER, driven through its real public entry point, stamps nil for
//      suppressed kinds and canonicalValence for the rest.
//   5. the FIELD fallback, observed BEHAVIORALLY through OrganismPlasticity,
//      lands on the same number a signal carrying canonicalValence would —
//      with a discrimination probe so the equality is not vacuous.

/// The frozen contract. Both columns are deliberate decisions, not observations:
/// changing either must be a conscious edit here as well as in the source.
private let frozenSomaticValenceTable:
    [SomaticSignalKind: (valence: Double, adapterSuppresses: Bool)] = [
        // Positive intrinsic body meaning; adapter stamps it.
        .toolSucceeded: (0.45, false),
        .deskItemClosed: (0.45, false),
        .providerSucceeded: (0.45, false),
        .providerRecovered: (0.45, false),
        .phoneDeliveryReceived: (0.45, false),
        .memoryCommitted: (0.45, false),
        .memoryHygieneCompleted: (0.45, false),
        .dreamCompleted: (0.45, false),
        .remIntegrated: (0.45, false),
        // Negative intrinsic body meaning; adapter stamps it.
        .toolFailed: (-0.55, false),
        .providerFailed: (-0.55, false),
        .phoneDeliveryFailed: (-0.55, false),
        .deskItemBlocked: (-0.55, false),
        .memoryCorrected: (-0.55, false),
        .correctionReceived: (-0.55, false),
        // Mild positive lifecycle; adapter stamps it.
        .appWake: (0.15, false),
        .iPhoneReachable: (0.15, false),
        // Field-fallback-ONLY kinds: the adapter deliberately leaves valence
        // unset, so these numbers surface only for a nil-valence signal.
        .resourcePressureChanged: (-0.5, true),
        .iPhoneStale: (-0.5, true),
        .approvalResolved: (0.4, true),
        // No intrinsic valence: chat felt-meaning is owned by the substrate's
        // semantic-appraisal path; the rest are neutral lifecycle markers.
        .userSpoke: (0, true),
        .assistantSpoke: (0, true),
        .appSleep: (0, true),
        .toolStarted: (0, true),
        .toolCancelled: (0, true),
        .providerStarted: (0, true),
        .providerCancelled: (0, true),
        .phoneDeliveryStarted: (0, true),
        .deskItemCreated: (0, true),
        .approvalRequested: (0, true),
    ]

@Test
func somaticValenceFrozenTableIsExhaustiveOverEveryKindInBothDirections() {
    let live = Set(SomaticSignalKind.allCases)
    let frozen = Set(frozenSomaticValenceTable.keys)
    let missing = live.subtracting(frozen).map(\.rawValue).sorted()
    let extra = frozen.subtracting(live).map(\.rawValue).sorted()
    #expect(
        missing.isEmpty,
        """
        New SomaticSignalKind(s) \(missing) have no frozen valence row. \
        `adapterSuppressesIntrinsicValence` has `default: return false`, so a new \
        kind silently opts INTO adapter-stamped intrinsic valence. Decide its \
        suppression deliberately, then add the row here.
        """
    )
    #expect(extra.isEmpty, "frozen rows \(extra) name kinds that no longer exist")
}

@Test
func canonicalValenceMatchesTheFrozenContractForEveryKind() {
    for kind in SomaticSignalKind.allCases {
        guard let row = frozenSomaticValenceTable[kind] else { continue }
        #expect(
            kind.canonicalValence == row.valence,
            "canonicalValence drifted for \(kind.rawValue): \(kind.canonicalValence) vs frozen \(row.valence)"
        )
    }
}

@Test
func adapterSuppressionSetEqualsTheFrozenAllowlist() {
    let liveSuppressed = Set(
        SomaticSignalKind.allCases
            .filter(\.adapterSuppressesIntrinsicValence)
            .map(\.rawValue)
    )
    let frozenSuppressed = Set(
        frozenSomaticValenceTable
            .filter { $0.value.adapterSuppresses }
            .map(\.key.rawValue)
    )
    #expect(
        liveSuppressed == frozenSuppressed,
        """
        adapter suppression set changed. \
        opted-in-silently: \(liveSuppressed.subtracting(frozenSuppressed).sorted()); \
        newly-suppressed: \(frozenSuppressed.subtracting(liveSuppressed).sorted())
        """
    )
    // Envelope, not a count: every kind the adapter suppresses must be a kind
    // whose felt meaning is owned elsewhere OR carries no bodily valence — the
    // two conditions the file's header names. The observable proxy is that no
    // suppressed kind is one the adapter would otherwise stamp a POSITIVE
    // success reading onto (that is the double-count that hurts).
    #expect(!liveSuppressed.contains(SomaticSignalKind.toolSucceeded.rawValue))
    #expect(!liveSuppressed.contains(SomaticSignalKind.toolFailed.rawValue))
}

/// Drive the adapter's REAL public entry point over every SomaticSignalKind it
/// can actually produce and assert the stamped valence obeys the table.
@Test
func adapterStampsCanonicalValenceOrNilThroughItsRealEntryPoint() throws {
    // (event, expected somatic kind) — the full set of kinds reachable from a
    // CognitiveEvent. Kinds minted by other producers (memory/phone/approval/
    // resource) never traverse this adapter and are covered by the table evals.
    let cases: [(CognitiveEvent, SomaticSignalKind)] = [
        (valenceProbeEvent(kind: .userMessageReceived, turnKind: .live), .userSpoke),
        (valenceProbeEvent(kind: .assistantTurnCompleted, turnKind: .live), .assistantSpoke),
        (valenceProbeEvent(kind: .userCorrection, turnKind: .live), .correctionReceived),
        (valenceProbeEvent(kind: .toolStarted), .toolStarted),
        (valenceProbeEvent(kind: .toolSucceeded), .toolSucceeded),
        (valenceProbeEvent(kind: .toolFailed), .toolFailed),
        (valenceProbeEvent(kind: .toolCancelled), .toolCancelled),
        (valenceProbeEvent(kind: .providerFailure), .providerFailed),
        (
            valenceProbeEvent(
                kind: .providerVitalsShift,
                metadata: [
                    CognitiveSomaticSignalAdapter.vitalsDirectionMetadataKey: .string("recovering"),
                ]
            ),
            .providerRecovered
        ),
        (
            valenceProbeEvent(kind: .workshopExecutionCompleted, metadata: ["status": .string("completed")]),
            .deskItemClosed
        ),
        (
            valenceProbeEvent(kind: .workshopExecutionCompleted, metadata: ["status": .string("failed")]),
            .deskItemBlocked
        ),
        (valenceProbeEvent(kind: .appWake), .appWake),
        (valenceProbeEvent(kind: .appSleep), .appSleep),
    ]

    var observed = Set<SomaticSignalKind>()
    for (index, testCase) in cases.enumerated() {
        let signal = try #require(
            CognitiveSomaticSignalAdapter.signal(
                from: testCase.0,
                id: UUID(uuidString: String(format: "5A000000-0000-0000-0000-%012d", index))!
            ),
            "adapter refused to mint a signal for \(testCase.1.rawValue)"
        )
        #expect(signal.kind == testCase.1)
        observed.insert(signal.kind)
        if testCase.1.adapterSuppressesIntrinsicValence {
            #expect(
                signal.valence == nil,
                "\(testCase.1.rawValue) is suppressed but the adapter stamped \(String(describing: signal.valence))"
            )
        } else {
            #expect(
                signal.valence == testCase.1.canonicalValence,
                "\(testCase.1.rawValue) adapter valence \(String(describing: signal.valence)) != canonical \(testCase.1.canonicalValence)"
            )
        }
    }
    // Both halves of the contract are actually exercised — not a probe set that
    // happens to be all-suppressed or all-stamped.
    let suppressedObserved = observed.filter(\.adapterSuppressesIntrinsicValence).count
    let stampedObserved = observed.count - suppressedObserved
    #expect(suppressedObserved > 0)
    #expect(stampedObserved > 0)
}

/// The FIELD half of the seam, observed behaviorally: a signal that reaches the
/// organism field with nil valence must land exactly where a signal carrying
/// `canonicalValence` lands. A re-introduced local fallback table with different
/// numbers breaks this for every kind whose canonical valence is negative.
@Test
func organismFieldNilValenceFallbackLandsOnCanonicalValenceForEveryKind() {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    for kind in SomaticSignalKind.allCases {
        let implicit = fieldCharge(kind: kind, valence: nil, at: at)
        let explicit = fieldCharge(kind: kind, valence: kind.canonicalValence, at: at)
        #expect(
            abs(implicit - explicit) < 1e-12,
            "\(kind.rawValue): nil-valence charge \(implicit) != canonical-valence charge \(explicit)"
        )
    }
}

/// Discrimination probe — proves the equality above is NOT vacuous. Charge only
/// responds to NEGATIVE valence (`max(0, -valence)`), so for the negatively-
/// valenced kinds a nil-valence signal must differ measurably from a zero-valence
/// one. If the fallback stopped being consulted, this is what catches it.
@Test
func organismFieldValenceFallbackIsActuallyConsultedNotIgnored() {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let negativeKinds = SomaticSignalKind.allCases.filter { $0.canonicalValence < 0 }
    #expect(!negativeKinds.isEmpty, "no negatively-valenced kinds — the probe would prove nothing")
    for kind in negativeKinds {
        let fallback = fieldCharge(kind: kind, valence: nil, at: at)
        let neutralised = fieldCharge(kind: kind, valence: 0, at: at)
        #expect(
            fallback > neutralised,
            "\(kind.rawValue): nil valence produced the same charge as an explicit 0 — the fallback is not being read"
        )
    }
}

// MARK: - Probes

private func valenceProbeEvent(
    kind: CognitiveEventKind,
    turnKind: CognitiveTurnKind? = .system,
    metadata: [String: JSONValue] = [:]
) -> CognitiveEvent {
    CognitiveEvent(
        id: "valence-probe-\(kind.rawValue)-\(metadata.count)",
        kind: kind,
        subject: CognitiveSubjectReference(type: "test", id: "valence-probe", label: "valence probe"),
        sourceClass: .observed,
        occurredAt: Date(timeIntervalSince1970: 2_000),
        summary: "valence probe",
        importance: 0.6,
        turnKind: turnKind,
        metadata: metadata
    )
}

/// Push one signal through the real plasticity path and read the total charge it
/// deposited. Charge is the only field the valence term feeds, so it is the
/// observable the fallback table actually moves.
private func fieldCharge(kind: SomaticSignalKind, valence: Double?, at: Date) -> Double {
    let signal = SomaticSignal(
        id: UUID(uuidString: "5B000000-0000-0000-0000-000000000001")!,
        kind: kind,
        sourceOrgan: "probe",
        occurredAt: at,
        intensity: 0.9,
        valence: valence,
        arousal: nil
    )
    let field = OrganismPlasticity.applying(
        signal: signal,
        chemicalState: .neutral,
        bodySchema: .neutral,
        to: .empty
    )
    return field.nodes.values.reduce(0) { $0 + $1.charge }
}
