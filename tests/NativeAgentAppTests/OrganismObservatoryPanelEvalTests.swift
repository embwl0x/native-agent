import Foundation
import Testing
import CognitiveSubstrate
@testable import NativeAgentApp

// EVAL FENCE: core.substrate.organism / ui.observatory.organismBodyPanel
//
// The production renderer consumes CognitionObservatoryOrganismPresentation
// directly. The panel contract must preserve the distinction between a real
// empty live body and a body that is off, stale, missing, or malformed. Zero
// is a valid measured value only in the live state.

private func organismPanelSnapshot(
    enabled: Bool,
    generatedAt: Date,
    lastSignalAt: Date? = nil
) -> OrganismSnapshot {
    OrganismSnapshot(
        generatedAt: generatedAt,
        enabled: enabled,
        chemicalState: .neutral,
        bodySchema: .neutral,
        fieldSummary: .empty,
        predictionSummary: .empty,
        dreamRepairSummary: .empty,
        reflexSummary: .empty,
        signalCount: 0,
        lastSignalAt: lastSignalAt
    )
}

@Test("organism panel distinguishes live zeroes from unavailable body states")
func organismObservatoryBodyPanelNamesAvailabilityInsteadOfCalmZeroes() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let liveSnapshot = organismPanelSnapshot(enabled: true, generatedAt: now)
    let live = CognitionObservatoryOrganismPresentation(snapshot: liveSnapshot, now: now)
    #expect(live.state == .live)
    #expect(live.collapsedHint == "no body line")
    #expect(live.renderedRowText.contains("Field nodes: 0"))
    #expect(live.renderedRowText.contains("Predictions pending: 0"))
    #expect(live.renderedRowText.contains("Last signal: absent"))
    for optionalRow in [
        "Provider belief: absent",
        "Provider belief estimate: absent",
        "Provider belief uncertainty: absent",
        "Provider evidence freshness: absent",
    ] {
        #expect(live.renderedRowText.contains(optionalRow), "optional row lost its absent state: \(optionalRow)")
    }

    let offSnapshot = organismPanelSnapshot(enabled: false, generatedAt: now)
    let off = CognitionObservatoryOrganismPresentation(snapshot: offSnapshot, now: now)
    guard case .disabled(let offReason) = off.state else {
        Issue.record("disabled kernel must not render a live-looking body")
        return
    }
    #expect(off.collapsedHint == "off")
    #expect(offReason.contains("off"))
    #expect(off.renderedRowText.isEmpty)
    #expect(live.renderedRowText != off.renderedRowText)

    let stale = CognitionObservatoryOrganismPresentation(
        snapshot: liveSnapshot,
        now: now.addingTimeInterval(301)
    )
    guard case .unavailable(let staleReason) = stale.state else {
        Issue.record("a stale sample must not keep rendering measured zeroes")
        return
    }
    #expect(stale.collapsedHint == "unavailable")
    #expect(staleReason.contains("stale"))
    #expect(stale.renderedRowText.isEmpty)

    let absent = CognitionObservatoryOrganismPresentation(snapshot: nil, now: now)
    guard case .absent(let absentReason) = absent.state else {
        Issue.record("a missing snapshot must remain visibly absent")
        return
    }
    #expect(absent.collapsedHint == "waiting")
    #expect(absentReason.contains("No organism body snapshot"))
    #expect(absent.renderedRowText.isEmpty)

    var invalidSnapshot = liveSnapshot
    invalidSnapshot.chemicalState.warmth = .nan
    let invalid = CognitionObservatoryOrganismPresentation(snapshot: invalidSnapshot, now: now)
    guard case .unavailable(let invalidReason) = invalid.state else {
        Issue.record("invalid body values must be withheld")
        return
    }
    #expect(invalidReason.contains("invalid value"))
    #expect(invalid.renderedRowText.isEmpty)

    // The shared production mapping is the sole input to the panel: live
    // zeroes have rows, while off bodies carry only an explicit reason.
    #expect(live.statusText == "Enabled")
    #expect(live.statusKind == "ok")
    #expect(off.statusText == "Off")
    #expect(off.statusKind == "warn")
    #expect(off.unavailableReason?.contains("kernel is off") == true)
    #expect(!off.renderedRowText.contains { $0.hasPrefix("Field nodes:") })
}
