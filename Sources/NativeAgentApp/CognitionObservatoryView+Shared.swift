// Move-only extraction (tightness Wave C) from CognitionObservatoryView.swift

import SwiftUI
import CognitiveSubstrate
import Context
import PersistenceCore

extension CognitionObservatoryView {

    func labeledValue(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.2f", value))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
