// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    @ViewBuilder
    func thoughtSeeds(_ seeds: [CognitiveThoughtSeed]) -> some View {
        if seeds.isEmpty {
            Text("No active thought seeds.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(Array(seeds.prefix(8)), id: \.id) { seed in
                    Text("\(CognitionThoughtSeedPresentation.thoughtKindLabel(seed.kind)): \(seed.text)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let overflow = CognitionThoughtSeedPresentation.thoughtSeedOverflowLabel(total: seeds.count) {
                    Text(overflow)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    func thoughtSuggestions(_ suggestions: [CognitiveThoughtSuggestion]) -> some View {
        if suggestions.isEmpty {
            Text("No thought seeds currently clear the interruption threshold.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(Array(suggestions.prefix(6)), id: \.id) { suggestion in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(CognitionThoughtSeedPresentation.thoughtKindLabel(suggestion.kind))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.2f", suggestion.interruptionScore))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(suggestion.text)
                            .font(.caption)
                            .textSelection(.enabled)
                        Text(suggestion.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }
}

enum CognitionThoughtSeedPresentation {
    static func thoughtKindLabel(_ kind: CognitiveThoughtSeedKind) -> String {
        switch kind {
        case .openQuestion: "Open question"
        case .anomaly: "Something unexpected"
        case .followUp: "Follow-up"
        case .reflectionTakeaway: "Reflection takeaway"
        }
    }

    static func thoughtSeedOverflowLabel(total: Int, visibleLimit: Int = 8) -> String? {
        guard total > visibleLimit else { return nil }
        return "Showing \(visibleLimit) of \(total) thought seeds."
    }

}
