import SwiftUI
import EngineRuntime
import AppKit
import NativeAgentShared
import PersistenceCore

// Blueprint: | `StatusView.swift` | `StatusView`: living system status and latest chronological activity projection with raw malformed-time evidence retained |

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
                // The living status card — posture, body, behaviour, and the
                // Desk, approvals and dream it reads — first, above the app's.
                LivingStatusPanel()
                NativePanel(title: "The app") {
                    let status = appModel.engine.doctor.runtimeStatus(lastRefreshError: appModel.lastRefreshError)
                    Label(status.text, systemImage: status.systemImage)
                        .foregroundStyle(status.tone == .success ? .green : status.tone == .warning ? .orange : status.tone == .failure ? .red : .secondary)
                    if let detail = status.detail {
                        Text(detail).font(.caption).foregroundStyle(.orange)
                    }
                    if let health = appModel.engine.doctor.health {
                        let uptime = Int(exactly: health.uptimeSeconds.rounded(.towardZero))
                            .flatMap { $0 >= 0 ? "\($0)s" : nil } ?? "Unavailable"
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            MetricTile(title: "Version", value: health.version, systemImage: "number")
                            MetricTile(title: "Uptime", value: uptime, systemImage: "timer")
                            MetricTile(title: "Runs", value: "\(appModel.engine.runs.rows.count)", systemImage: "play.rectangle")
                            MetricTile(title: "Sessions", value: "\(appModel.engine.transcripts.sessions.count)", systemImage: "bubble.left.and.bubble.right")
                        }
                        Text(UserDisplayFormatters.tildifyPath(health.dataDir))
                            .font(NativeAgentFont.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if let watchdog = appModel.engine.doctor.watchdog {
                    NativePanel(title: "Background work") {
                        HStack {
                            StatusBadge(text: "SWIFT", status: watchdog.runtimeBadgeStatus)
                            Text(watchdog.runtimeLifecycleDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text("Status: \(watchdog.runtimeLifecycleStatus) · Desk tasks running \(watchdog.runningExecutions) · improvements \(watchdog.runningImprovements)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NativePanel(title: "Recent activity") {
                    let state = StatusActivityPresentation.state(
                        events: appModel.engine.doctor.activityEvents,
                        refresh: appModel.engine.doctor.activityRefresh
                    )
                    switch state {
                    case .loading:
                        ProgressView("Loading activity…")
                            .font(.caption)
                    case .unavailable:
                        Label("Recent activity is unavailable. Refresh to try again.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .empty:
                        Text("No activity recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .current(let events), .stale(let events):
                        if case .stale = state {
                            Label("Showing the activity that loaded last time; the refresh could not read the activity log.", systemImage: "clock.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        // Show newest first; getActivity returns chronological file order.
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

private struct ActivityRow: View {
    var event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(NativeAgentFont.section)
                    .lineLimit(1)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(StatusActivityPresentation.timestamp(for: event))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .textSelection(.enabled)
    }

    private var icon: String {
        switch event.kind {
        case "mission": "target"
        case "trust": "lock.shield"
        case "backup": "externaldrive.badge.timemachine"
        case "eval": "checklist"
        case "connector": "point.3.connected.trianglepath.dotted"
        case "chat": "bubble.left.and.bubble.right"
        default: "circle"
        }
    }

    private var color: Color {
        switch event.status {
        case "ok": .green
        case "warn": .orange
        case "fail": .red
        default: .secondary
        }
    }
}
