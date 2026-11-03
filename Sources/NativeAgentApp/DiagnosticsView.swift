import DoctorChecks

// Blueprint: | `DiagnosticsView.swift` | `DiagnosticsView` and refresh coalescer: latest-run availability and measured-check header; one sequential shared snapshot across status/runs segments, with legacy tab routing; each mind's door predictions and their records (`Expansion.summary`) |

import SwiftUI
import ChatTurnRuntime
import Context
import NativeAgentCore

// MARK: - Diagnostics (Advanced tab)

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var appModel
    let mode: DiagnosticsMode
    @State private var refreshCoalescer = LivingStatusRefreshCoalescer()
    @State private var showsModelCalls = false
    @State private var showsExpansion = false
    @State private var expansion = ""

    init(mode: DiagnosticsMode = .doctor) {
        self.mode = mode
    }

    enum DiagnosticsMode: String, CaseIterable, Identifiable {
        case doctor = "Doctor"
        case status = "Status"
        case runs = "Runs Log"
        case cognition = "Cognition"
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
            // Diagnostics owns health and token readouts; Chat shows one status dot.
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
                        isRefreshing: refreshCoalescer.isRefreshing,
                        refreshAction: { await refreshSnapshot() }
                    )
                case .runs:
                    RunsView(
                        isRefreshing: refreshCoalescer.isRefreshing,
                        refreshAction: { await refreshSnapshot() }
                    )
                case .cognition:
                    if let runtime = appModel.engine.cognitionView.runtime {
                        CognitionObservatoryView(cognition: appModel.engine.cognitionView, runtime: runtime, dependencies: .live(appModel: appModel))
                    } else {
                        Text("Unavailable").foregroundStyle(.secondary)
                    }
                case .inspector: InspectorView(feed: appModel.engine.trace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            DisclosureGroup("Model calls", isExpanded: $showsModelCalls) {
                Text(appModel.engine.cognitionView.modelCalls).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Refresh") { Task { await appModel.engine.cognitionView.refreshModelCalls() } }
            }
            .onChange(of: showsModelCalls) { _, expanded in
                if expanded { Task { await appModel.engine.cognitionView.refreshModelCalls() } }
            }
            // Each mind's predictions at the door: what rides inside a result, with its record.
            DisclosureGroup("Expansion", isExpanded: $showsExpansion) {
                Text(expansion).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Refresh") { Task { expansion = await Expansion.shared.summary() } }
            }
            .onChange(of: showsExpansion) { _, expanded in
                if expanded { Task { expansion = await Expansion.shared.summary() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alivePageLine(Self.headerLine(appModel), id: "diagnostics.line")
        .navigationTitle("Diagnostics")
        .liveTask {
            guard mode == .status || mode == .runs else { return }
            await refreshSnapshot()
        }
    }

    /// Latest-run availability comes before retained checks; only measured,
    /// passing rows can establish that every check passed.
    @MainActor
    static func headerLine(_ appModel: AppModel) -> String? {
        let doctor = appModel.engine.doctor
        if let issue = doctor.reportAvailabilityIssue {
            return "My latest health checks are unavailable. \(issue)"
        }
        guard let report = doctor.report else { return nil }
        let summary = DoctorPlainCopy.summarize(report.checks)
        let total = summary.total
        guard total > 0 else { return "My health checks are incomplete; no checks were measured." }
        let checks = total == 1 ? "check" : "checks"
        if summary.failing > 0 { return "\(summary.failing) of my \(total) health \(checks) failed." }
        if summary.warning > 0 { return "I'm running; \(summary.warning) of \(total) health \(checks) need a look." }
        let incomplete = summary.unclear + summary.reading
        if incomplete > 0 { return "My health checks are incomplete; \(incomplete) of \(total) are unmeasured or unclear." }
        if summary.healthy == total {
            return total == 1 ? "My last health check passed." : "All \(total) of my health checks passed."
        }
        return "My health checks finished; \(summary.off + summary.notNeeded) were off or not needed."
    }

    @MainActor
    private func refreshSnapshot() async {
        guard refreshCoalescer.requestRefresh() else { return }
        repeat {
            _ = await appModel.refreshForSidebarItem(.diagnostics)
            guard !Task.isCancelled else {
                refreshCoalescer.cancel()
                return
            }
        } while refreshCoalescer.completePass()
    }
}
