import Foundation
import CognitiveSubstrate

/// Read-only presentation contract for the Observatory's Affect Signals panel.
/// The substrate owns the axes; this layer only prevents a missing or disabled
/// read from being rendered as a calm-looking zero.
struct CognitionObservatoryAffectPresentation: Equatable, Sendable {
    struct Axis: Equatable, Sendable {
        let label: String
        let value: Double
    }

    enum State: Equatable, Sendable {
        case live
        case disabled(String)
        case unavailable(String)
        case absent(String)
    }

    enum CapsuleWarmthContext: Equatable, Sendable {
        case liveInjected
        case previewOnly
        case absent
    }

    let state: State
    let axes: [Axis]
    let capsuleWarmthContext: CapsuleWarmthContext

    init(
        configuration: CognitiveConfiguration?,
        affect: CognitiveAffectState?,
        capsulePreviewInfo: CapsulePreviewInfo?
    ) {
        capsuleWarmthContext = Self.capsuleWarmthContext(capsulePreviewInfo)
        guard let configuration, let affect else {
            state = .absent("No affect snapshot has arrived yet.")
            axes = []
            return
        }
        guard configuration.enabled else {
            state = .disabled("Cognitive substrate is off, so affect signals are not active.")
            axes = []
            return
        }
        guard configuration.observatoryEnabled else {
            state = .unavailable("Observatory readout is disabled. Affect values are not being shown.")
            axes = []
            return
        }
        guard configuration.affectEnabled else {
            state = .disabled("Affect signals are off, so a zero readout would be misleading.")
            axes = []
            return
        }

        let axes = [
            Axis(label: "Activation", value: affect.arousal),
            Axis(label: "Uncertainty", value: affect.uncertainty),
            Axis(label: "Task Pressure", value: affect.taskPressure),
            Axis(label: "Recent Warmth", value: affect.socialWarmth),
        ]
        guard axes.allSatisfy({ $0.value.isFinite && (0...1).contains($0.value) }) else {
            state = .unavailable("Affect snapshot contains an invalid value and is withheld.")
            self.axes = []
            return
        }

        state = .live
        self.axes = axes
    }

    var collapsedHint: String {
        switch state {
        case .live:
            let activation = axes.first(where: { $0.label == "Activation" })?.value ?? 0
            let warmth = axes.first(where: { $0.label == "Recent Warmth" })?.value ?? 0
            return String(format: "act %.2f · raw warm %.2f", activation, warmth)
        case .disabled:
            return "off"
        case .unavailable:
            return "unavailable"
        case .absent:
            return "waiting"
        }
    }

    var capsuleWarmthNote: String {
        switch capsuleWarmthContext {
        case .liveInjected:
            return "Raw social warmth is shown. The last live capsule uses a separately remapped felt-warmth signal."
        case .previewOnly:
            return "Raw social warmth is shown. The visible capsule is preview-only and was not injected into chat."
        case .absent:
            return "Raw social warmth is shown. No capsule preview is available yet."
        }
    }

    private static func capsuleWarmthContext(_ info: CapsulePreviewInfo?) -> CapsuleWarmthContext {
        guard let info else { return .absent }
        switch info.source {
        case .liveInjected:
            return .liveInjected
        case .synthetic:
            return .previewOnly
        }
    }
}
