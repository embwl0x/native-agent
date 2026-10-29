import SwiftUI
import ApprovalInbox
import Cognition
import CognitiveSubstrate
import NativeAgentShared
import PersistenceCore
import DeviceSync
import DreamREMCycle
// Blueprint: | `LivingStatusPanel.swift` | `LivingStatusPanel` struct |

struct LivingStatusPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    private var cognition: CognitionViewFacade { appModel.engine.cognitionView }
    private var snapshot: LivingStatusSnapshot? { cognition.livingSnapshot }
    private var refreshStatus: AppModel.PanelRefreshStatus? { cognition.livingRefreshStatus }
    @State private var fileWatchAvailability: LivingStatusFileWatch.Availability?

    private var isRefreshing: Bool { cognition.livingRefreshCoalescer.isRefreshing }

    private var refreshPresentation: AppModel.CompactReadPresentationState {
        AppModel.compactReadPresentationState(hasContent: snapshot != nil, status: refreshStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Right now", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                if let snapshot {
                    StatusBadge(text: snapshot.needsText, status: snapshot.postureStatus)
                } else if refreshPresentation == .unavailable {
                    StatusBadge(text: "Unavailable", status: "warn")
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh \(appModel.agentDisplayName)'s current state")
                .accessibilityLabel("Refresh \(appModel.agentDisplayName)'s current state")
                .disabled(isRefreshing)
            }

            if let snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: snapshot.postureStatus == "warn" ? "exclamationmark.triangle.fill" : "face.smiling")
                            .foregroundStyle(snapshot.postureStatus == "warn" ? .orange : .green)
                            .frame(width: 16)
                        Text(snapshot.homeLine)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    Text(snapshot.whyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(snapshot.carryLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    livingRow("Posture", snapshot.posture, icon: "figure.stand")
                    livingRow("Body", snapshot.bodyState, icon: "heart.text.square")
                    livingRow("Behavior", snapshot.behaviorLine, icon: "point.3.connected.trianglepath.dotted")
                    Text(snapshot.innerLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    livingRow("Desk", snapshot.deskSummary, icon: "checklist")
                    livingRow("Approvals", snapshot.approvalsSummary, icon: "checkmark.shield")
                    livingRow("Dream", snapshot.lastDreamSummary, icon: "moon.stars")
                }
                if refreshPresentation == .stale,
                   let message = refreshPresentation.livingStatusAdverseMessage {
                    // Endpoint names are internal vocabulary — plain headline,
                    // technical detail demoted to a tooltip (same pattern as
                    // DetachedChatLoadFailureCopy).
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .help((refreshStatus?.failedEndpoints.isEmpty == false)
                            ? "Did not respond: " + (refreshStatus?.failedEndpoints.joined(separator: ", ") ?? "")
                            : "The status sources did not respond.")
                }
            } else if let message = refreshPresentation.livingStatusAdverseMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(appModel.agentDisplayName)'s current state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = fileWatchAvailability?.unavailableMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .aliveCard(radius: 8)
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                fileWatchAvailability = nil
                return
            }
            await LivingStatusFileWatch.observe(dataRoot: appModel.engine.dataRoot, availabilityDidChange: { availability in
                fileWatchAvailability = availability
            }) {
                await refresh()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let changes = await cognition.changes()
            // This source is process-local and not every visible cognition
            // delta necessarily produces a file edge. Subscribe first, then
            // read once so a change racing view activation remains buffered.
            await refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private func livingRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func refresh() async {
        await cognition.refreshLivingStatus(
            desk: appModel.engine.desk,
            agentDisplayName: { appModel.agentDisplayName },
            dreamErrorDidChange: { appModel.dreamError = $0 }
        )
    }
}

extension LivingStatusFileWatch {
    @MainActor
    static func observe(
        dataRoot: URL,
        debounceDelay: Duration = .milliseconds(250),
        availabilityDidChange: @escaping @MainActor (Availability) -> Void = { _ in },
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let paths = watchedPaths(dataRoot: dataRoot)
        let events = FileChangeEvents(paths: paths, emitInitial: false)
        defer { events.cancel() }
        let armed = await events.waitUntilArmed()
        guard !Task.isCancelled else { return }
        let unavailable = Availability.unavailable("status files could not be observed")
        availabilityDidChange(armed ? .watching(inputCount: paths.count) : unavailable)
        await refresh()
        guard armed, !Task.isCancelled else { return }
        let debouncer = StoreReloadDebouncer(delay: debounceDelay, reload: refresh)
        await debouncer.setVisible(true)
        for await _ in events.stream {
            guard !Task.isCancelled else { break }
            await debouncer.signal()
        }
        await debouncer.cancel()
        if !Task.isCancelled {
            availabilityDidChange(unavailable)
        }
    }
}

extension LivingStatusFileWatch.Availability {
    var unavailableMessage: String? {
        guard case let .unavailable(detail) = self else { return nil }
        return "Live status updates are unavailable: \(detail)"
    }
}

/// A completed refresh is not silent: an unavailable read and retained last
/// known snapshot each have distinct, user-visible feedback.
private extension AppModel.CompactReadPresentationState {
    var livingStatusAdverseMessage: String? {
        switch self {
        case .stale:
            return "Refresh couldn't complete — showing the last known state."
        case .unavailable:
            return "Refresh couldn't complete — current state is unavailable; no calm or needs-nothing state was inferred."
        case .empty:
            return "Refresh completed, but no current state was available."
        case .loading, .content:
            return nil
        }
    }
}
