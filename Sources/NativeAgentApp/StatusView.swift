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

struct StatusView: View {
    @Environment(AppModel.self) private var appModel

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
                        Text("Lifecycle: \(watchdog.runtimeLifecycleStatus) · active Workshop executions \(watchdog.runningExecutions) · improvements \(watchdog.runningImprovements)")
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
                    if appModel.activityEvents.isEmpty {
                        Text("No activity recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.activityEvents.prefix(8)) { event in
                            ActivityRow(event: event)
                        }
                    }
                }

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await appModel.refreshForSidebarItem(.diagnostics) }
                }
            }
            .padding()
        }
        .navigationTitle("Status")
        .task { await appModel.refreshForSidebarItem(.diagnostics) }
    }
}
