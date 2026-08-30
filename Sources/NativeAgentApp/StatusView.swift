import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

enum StatusActivityPresentation {
    enum State: Equatable {
        case loading
        case unavailable
        case empty
        case current([ActivityEvent])
        case stale([ActivityEvent])
    }

    /// The activity ledger is chronological. Status intentionally shows the
    /// latest eight in reverse chronological order, never the oldest entries
    /// in its retained tail.
    static func recentEvents(from events: [ActivityEvent], limit: Int = 8) -> [ActivityEvent] {
        Array(events.suffix(limit).reversed())
    }

    static func state(
        events: [ActivityEvent],
        refresh: AppModel.PanelRefreshStatus?
    ) -> State {
        let activityReadFailed = refresh?.failedEndpoints.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "activity"
        } ?? false
        if activityReadFailed {
            return events.isEmpty ? .unavailable : .stale(events)
        }
        guard refresh != nil else { return .loading }
        return events.isEmpty ? .empty : .current(events)
    }

    /// Status exposes the ledger's time through the shared user formatter.
    /// A malformed timestamp deliberately remains visible as raw evidence
    /// rather than becoming a plausible relative time.
    static func timestamp(for event: ActivityEvent) -> String {
        UserDisplayFormatters.humanizeISOTimestamp(event.createdAt)
    }
}

struct StatusView: View {
    @Environment(AppModel.self) private var appModel
    private let loadsOnAppear: Bool
    private let isRefreshing: Bool
    private let refreshAction: (@MainActor () async -> Void)?

    init(
        loadsOnAppear: Bool = true,
        isRefreshing: Bool = false,
        refreshAction: (@MainActor () async -> Void)? = nil
    ) {
        self.loadsOnAppear = loadsOnAppear
        self.isRefreshing = isRefreshing
        self.refreshAction = refreshAction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NativePanel(title: "Runtime", systemImage: "server.rack") {
                    Label(appModel.statusText, systemImage: appModel.health?.ok == true ? "checkmark.circle.fill" : "xmark.octagon")
                        .foregroundStyle(appModel.health?.ok == true ? .green : .red)
                    if let health = appModel.health {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            MetricTile(title: "Version", value: health.version, systemImage: "number")
                            MetricTile(title: "Uptime", value: "\(Int(health.uptimeSeconds))s", systemImage: "timer")
                            MetricTile(title: "Runs", value: "\(appModel.runs.count)", systemImage: "play.rectangle")
                            MetricTile(title: "Sessions", value: "\(appModel.chatSessions.count)", systemImage: "bubble.left.and.bubble.right")
                        }
                        Text(UserDisplayFormatters.tildifyPath(health.dataDir))
                            .font(NativeAgentFont.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if let watchdog = appModel.watchdogStatus {
                    NativePanel(title: "Watchdog", systemImage: "waveform.path.ecg") {
                        HStack {
                            StatusBadge(text: watchdog.runtimeBadgeText, status: watchdog.runtimeBadgeStatus)
                            Text(watchdog.runtimeLifecycleDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text("Lifecycle: \(watchdog.runtimeLifecycleStatus) · active Desk executions \(watchdog.runningExecutions) · improvements \(watchdog.runningImprovements)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !watchdog.launchAgentStatus.isEmpty {
                            Text("Legacy launch agent: \(watchdog.launchAgentStatus) · \(watchdog.launchAgentDetail)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                NativePanel(title: "Recent Activity", systemImage: "clock.arrow.circlepath") {
                    switch StatusActivityPresentation.state(
                        events: appModel.activityEvents,
                        refresh: appModel.panelRefreshStatus[.diagnostics]
                    ) {
                    case .loading:
                        ProgressView("Loading activity…")
                            .font(.caption)
                    case .unavailable:
                        Label("Activity history is unavailable. Refresh to retry.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .empty:
                        Text("No activity recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .current(let events):
                        // NEWEST first. `getActivity` returns the tail of events.jsonl in
                        // file (chronological) order, so `.prefix` showed the OLDEST 8 of
                        // the last 200 — on a 5,400-event feed that was a week stale while
                        // today's entries sat just below (2026-08-02).
                        ForEach(StatusActivityPresentation.recentEvents(from: events)) { event in
                            ActivityRow(event: event)
                        }
                    case .stale(let events):
                        Label("Showing previously loaded activity; refresh could not reach the ledger.", systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        ForEach(StatusActivityPresentation.recentEvents(from: events)) { event in
                            ActivityRow(event: event)
                        }
                    }
                }

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)
            }
            .padding()
        }
        .navigationTitle("Status")
        .task {
            guard loadsOnAppear else { return }
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        if let refreshAction {
            await refreshAction()
        } else {
            _ = await appModel.refreshForSidebarItem(.diagnostics)
        }
    }
}
