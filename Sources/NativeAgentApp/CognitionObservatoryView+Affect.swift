// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    func affect(_ affect: CognitiveAffectState) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            Text("Raw steering signals for \(appModel.agentDisplayName)'s next-turn tone and attention. Low usually means calm, not absent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NativeAgentSpacing.md)], spacing: NativeAgentSpacing.sm) {
                labeledValue("Activation", affect.arousal)
                labeledValue("Uncertainty", affect.uncertainty)
                labeledValue("Task Pressure", affect.taskPressure)
                labeledValue("Recent Warmth", affect.socialWarmth)
            }
            Text("Capsules may raise effective warmth for live chat before injection; this panel shows the decaying raw meter.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
