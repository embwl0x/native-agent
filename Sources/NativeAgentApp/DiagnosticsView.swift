// Move-only extraction (tightness Wave C) from SidebarFlattenViews.swift

import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore

// MARK: - Diagnostics (Advanced tab)

struct DiagnosticsView: View {
    @State private var mode: DiagnosticsMode

    /// Landing segment. The retired Cognition and Inspector tabs alias into
    /// Diagnostics (fence-A routing) by opening on their own segment:
    /// `DiagnosticsView(initialMode: .cognition)` / `.inspector`.
    init(initialMode: DiagnosticsMode = .doctor) {
        _mode = State(initialValue: initialMode)
    }

    enum DiagnosticsMode: String, CaseIterable, Identifiable {
        case doctor = "Doctor"
        case status = "Status"
        case runs = "Runs Log"
        // B2.4: read-only Cognition Observatory internals folded in as a segment.
        case cognition = "Cognition"
        // B2.6: Turn Inspector folded in from its own advanced tab as a segment.
        case inspector = "Inspector"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Diagnostics", selection: $mode) {
                ForEach(DiagnosticsMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top)

            Group {
                switch mode {
                case .doctor: DoctorView()
                case .status: StatusView()
                case .runs: RunsView()
                case .cognition: CognitionObservatoryView()
                case .inspector: InspectorView()
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
