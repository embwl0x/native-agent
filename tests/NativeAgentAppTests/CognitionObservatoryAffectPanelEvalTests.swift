import Foundation
import Testing
@testable import NativeAgentApp
import CognitiveSubstrate

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.substrate.affect
// Ledger row: ui.observatory.affectPanel
//
// The observable path is the mounted Cognition Observatory disclosure, not a
// duplicate formatting helper. This eval pins the raw runtime axes, the
// collapsed hint, the capsule-vs-raw warmth distinction, and every honest
// non-live state that otherwise reads as a calm-looking zero.
// ─────────────────────────────────────────────────────────────────────────────

private func affectAxisValues(_ presentation: CognitionObservatoryAffectPresentation) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: presentation.axes.map { ($0.label, $0.value) })
}

@Test func cognitionObservatoryAffectPanel_projectsTheRuntimeAxesAndNamesRawWarmth() {
    let affect = CognitiveAffectState(
        arousal: 0.31,
        uncertainty: 0.47,
        taskPressure: 0.62,
        socialWarmth: 0.28,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    let presentation = CognitionObservatoryAffectPresentation(
        configuration: .allPhasesEnabled,
        affect: affect,
        capsulePreviewInfo: CapsulePreviewInfo(
            source: .liveInjected,
            userMessage: "real conversation",
            at: Date(timeIntervalSince1970: 1_000)
        )
    )

    #expect(presentation.state == .live)
    #expect(affectAxisValues(presentation) == [
        "Activation": 0.31,
        "Uncertainty": 0.47,
        "Task Pressure": 0.62,
        "Recent Warmth": 0.28,
    ])
    #expect(presentation.collapsedHint == "act 0.31 · raw warm 0.28")
    #expect(presentation.capsuleWarmthContext == .liveInjected)
    #expect(presentation.capsuleWarmthNote.contains("Raw social warmth"))
    #expect(presentation.capsuleWarmthNote.contains("separately remapped felt-warmth"))
}

@Test func cognitionObservatoryAffectPanel_neverPresentsOffOrMissingStateAsZero() {
    var affectOff = CognitiveConfiguration.allPhasesEnabled
    affectOff.affectEnabled = false
    let disabled = CognitionObservatoryAffectPresentation(
        configuration: affectOff,
        affect: CognitiveAffectState(socialWarmth: 0.8),
        capsulePreviewInfo: nil
    )
    #expect(disabled.collapsedHint == "off")
    #expect(disabled.axes.isEmpty)
    guard case .disabled(let disabledReason) = disabled.state else {
        Issue.record("affect-off state must be visibly disabled")
        return
    }
    #expect(disabledReason.contains("zero readout would be misleading"))

    var observatoryOff = CognitiveConfiguration.allPhasesEnabled
    observatoryOff.observatoryEnabled = false
    let unavailable = CognitionObservatoryAffectPresentation(
        configuration: observatoryOff,
        affect: CognitiveAffectState(arousal: 0.6),
        capsulePreviewInfo: nil
    )
    #expect(unavailable.collapsedHint == "unavailable")
    #expect(unavailable.axes.isEmpty)
    guard case .unavailable(let unavailableReason) = unavailable.state else {
        Issue.record("observatory-off state must be visibly unavailable")
        return
    }
    #expect(unavailableReason.contains("readout is disabled"))

    var invalidAffect = CognitiveAffectState(arousal: 0.4)
    invalidAffect.arousal = .nan
    let adverse = CognitionObservatoryAffectPresentation(
        configuration: .allPhasesEnabled,
        affect: invalidAffect,
        capsulePreviewInfo: nil
    )
    #expect(adverse.collapsedHint == "unavailable")
    #expect(adverse.axes.isEmpty)
    guard case .unavailable(let adverseReason) = adverse.state else {
        Issue.record("invalid affect data must be visibly unavailable")
        return
    }
    #expect(adverseReason.contains("invalid value"))

    let absent = CognitionObservatoryAffectPresentation(
        configuration: nil,
        affect: nil,
        capsulePreviewInfo: nil
    )
    #expect(absent.collapsedHint == "waiting")
    #expect(absent.axes.isEmpty)
    guard case .absent(let absentReason) = absent.state else {
        Issue.record("missing snapshot must be visibly waiting")
        return
    }
    #expect(absentReason.contains("No affect snapshot"))
}

@Test func cognitionObservatoryAffectPanel_isMountedThroughTheRealDisclosureAndRenderer() throws {
    let observatory = try AppSourceScraping.appSource("CognitionObservatoryView.swift")
    let renderer = try AppSourceScraping.appSource("CognitionObservatoryView+Affect.swift")
    let presentation = try AppSourceScraping.appSource("CognitionObservatoryAffectPresentation.swift")

    #expect(observatory.contains("affect: detail?.summary.affect"))
    #expect(observatory.contains("hint: affectPresentation.collapsedHint"))
    #expect(observatory.contains("affect(affectPresentation)"))
    #expect(renderer.contains("ForEach(presentation.axes, id: \\.label)"))
    #expect(renderer.contains("presentation.capsuleWarmthNote"))
    for label in ["Activation", "Uncertainty", "Task Pressure", "Recent Warmth"] {
        #expect(presentation.contains("label: \"\(label)\""), "missing affect axis label: \(label)")
    }
}
