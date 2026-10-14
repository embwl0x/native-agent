import Cognition
import Foundation
// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    @ViewBuilder
    func affect(_ presentation: CognitionObservatoryAffectPresentation) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            switch presentation.state {
            case .live:
                Text("What is nudging \(dependencies.agentDisplayName)'s tone and attention on the next message. Low usually means calm, not missing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                    ForEach(presentation.axes, id: \.label) { axis in
                        labeledValue(axis.label, axis.value)
                    }
                }
                Text(presentation.capsuleWarmthNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case let .disabled(reason), let .unavailable(reason), let .absent(reason):
                ObservatoryNoticeRow(
                    icon: "eye.slash",
                    tint: .secondary,
                    title: "Mood readout unavailable",
                    detail: reason
                )
            }
        }
    }
}

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
            state = .disabled("My inner life is off, so there are no mood signals.")
            axes = []
            return
        }
        guard configuration.observatoryEnabled else {
            state = .unavailable("This readout is off, so mood values are not being shown.")
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
            Axis(label: "Task pressure", value: affect.taskPressure),
            Axis(label: "Recent warmth", value: affect.socialWarmth),
        ]
        guard affect.observatoryValuesAreValid else {
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
            let warmth = axes.first(where: { $0.label == "Recent warmth" })?.value ?? 0
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
