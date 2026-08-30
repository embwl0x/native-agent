// Move-only extraction (tightness Wave C) from SidebarFlattenViews.swift

import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore

// MARK: - Diagnostics (Advanced tab)

/// Status and Runs share one Diagnostics snapshot. Segment changes and manual
/// refresh buttons therefore share one sequential owner so an older overlapping
/// read cannot finish last and replace a newer snapshot.
struct DiagnosticsRefreshCoalescer: Equatable {
    private(set) var isRefreshing = false
    private(set) var pendingRefresh = false

    mutating func requestRefresh() -> Bool {
        guard !isRefreshing else {
            pendingRefresh = true
            return false
        }
        isRefreshing = true
        pendingRefresh = false
        return true
    }

    mutating func completeRefresh() -> Bool {
        guard isRefreshing else { return false }
        if pendingRefresh {
            pendingRefresh = false
            return true
        }
        cancel()
        return false
    }

    mutating func cancel() {
        isRefreshing = false
        pendingRefresh = false
    }
}

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var mode: DiagnosticsMode
    @State private var refreshCoalescer = DiagnosticsRefreshCoalescer()
    @State private var isRefreshingSnapshot = false

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
                case .status:
                    StatusView(
                        loadsOnAppear: false,
                        isRefreshing: isRefreshingSnapshot,
                        refreshAction: { await refreshSnapshot() }
                    )
                case .runs:
                    RunsView(
                        isRefreshing: isRefreshingSnapshot,
                        refreshAction: { await refreshSnapshot() }
                    )
                case .cognition:
                    CognitionObservatoryView(dependencies: .live(appModel: appModel))
                case .inspector: InspectorView()
                }
            }
        }
        .navigationTitle("Diagnostics")
        .task {
            guard mode == .status || mode == .runs else { return }
            await refreshSnapshot()
        }
        .onChange(of: mode) { _, nextMode in
            guard nextMode == .status || nextMode == .runs else { return }
            Task { await refreshSnapshot() }
        }
    }

    @MainActor
    private func refreshSnapshot() async {
        guard refreshCoalescer.requestRefresh() else { return }
        isRefreshingSnapshot = true
        repeat {
            _ = await appModel.refreshForSidebarItem(.diagnostics)
            guard !Task.isCancelled else {
                refreshCoalescer.cancel()
                isRefreshingSnapshot = false
                return
            }
        } while refreshCoalescer.completeRefresh()
        isRefreshingSnapshot = false
    }
}
