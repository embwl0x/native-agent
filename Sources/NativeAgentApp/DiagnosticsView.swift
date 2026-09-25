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
    /// Off when a rail page owns the tabs (DiagnosticsRailPage) and hands the
    /// mode in; on for the classic shell, which has no tab row.
    var showsModePicker: Bool = true

    init(initialMode: DiagnosticsMode = .doctor, showsModePicker: Bool = true) {
        _mode = State(initialValue: initialMode)
        self.showsModePicker = showsModePicker
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

        /// The word a person reads. The raw values are the persisted route
        /// keys, so the segment's label is spelled here in sentence case
        /// rather than taken from the stored string.
        var title: String {
            switch self {
            case .doctor: "Health checks"
            case .status: "Status"
            case .runs: "Run history"
            case .cognition: "Cognition"
            case .inspector: "Chat turn details"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EmbeddingModelDownloadRow()
            if showsModePicker {
                Picker("Diagnostics", selection: $mode) {
                    ForEach(DiagnosticsMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .hazeTinted(.segments)
                .labelsHidden()
            }

            // ui-simplify 2026-09-02 (Lane A): the two readouts that used to
            // stand between a stranger and their first message — the system
            // health / "N warnings" pill and the session token meter — live
            // here now. Nothing was deleted; they just stopped being furniture
            // in the room. Chat keeps one status dot instead.
            HStack(spacing: 12) {
                HealthPill()
                if !appModel.activeChatSessionId.isEmpty {
                    ContextFillBar(sessionId: appModel.activeChatSessionId)
                }
                Spacer(minLength: 0)
            }

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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .motionArrival(when: appModel.panelRefreshStatus[.diagnostics] != nil)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Alive glass (2026-09-23): the tabs' panels and cards wear the kit.
        .environment(\.aliveCards, true)
        .alivePageLine(Self.headerLine(appModel), id: "diagnostics.line")
        .navigationTitle("Diagnostics")
        .liveTask {
            guard mode == .status || mode == .runs else { return }
            await refreshSnapshot()
        }
        .onChange(of: mode) { _, nextMode in
            guard nextMode == .status || nextMode == .runs else { return }
            Task { await refreshSnapshot() }
        }
    }

    /// The header's one sentence, from the last health check. Nil before one
    /// has run: the frame keeps its plain subtitle rather than guess.
    @MainActor
    static func headerLine(_ appModel: AppModel) -> String? {
        guard let report = appModel.doctorReport else { return nil }
        let summary = DoctorPlainCopy.summarize(report.checks)
        let total = summary.total
        guard total > 0 else { return nil }
        let checks = total == 1 ? "check" : "checks"
        if summary.failing > 0 { return "\(summary.failing) of my \(total) health \(checks) failed." }
        if summary.warning > 0 { return "I'm running; \(summary.warning) of \(total) health \(checks) need a look." }
        if summary.unclear > 0 { return "I'm running; \(summary.unclear) of \(total) health \(checks) came back unclear." }
        return total == 1 ? "My last health check passed." : "All \(total) of my health checks passed."
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
