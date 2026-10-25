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

    private var dataRoot: URL {
        appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    private var refreshPresentation: AppModel.CompactReadPresentationState {
        AppModel.compactReadPresentationState(hasContent: snapshot != nil, status: refreshStatus)
    }

    private var livingRefreshPresentation: LivingStatusRefreshPresentation {
        LivingStatusRefreshPresentation.resolve(
            hasSnapshot: snapshot != nil,
            status: refreshStatus
        )
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
                if livingRefreshPresentation == .retainedFailure,
                   let message = livingRefreshPresentation.adverseMessage {
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
            } else if let message = livingRefreshPresentation.adverseMessage {
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
            await LivingStatusFileWatch.observe(dataRoot: dataRoot, availabilityDidChange: { availability in
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
            approvals: appModel.engine.approvals,
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
        let availability = availability(dataRoot: dataRoot)
        availabilityDidChange(availability)
        guard case .watching = availability else {
            // Preserve the one canonical read even when live observation cannot
            // be armed; the card will report both the read result and the lost
            // live-update capability instead of quietly retaining stale data.
            await refresh()
            return
        }
        await EventDeadlinePhysiology.refreshOnChanges(
            paths: watchedPaths(dataRoot: dataRoot),
            debounceDelay: debounceDelay,
            refresh: refresh
        )
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
enum LivingStatusRefreshPresentation: Equatable {
    case loading
    case current
    case retainedFailure
    case unavailable
    case empty

    static func resolve(
        hasSnapshot: Bool,
        status: AppModel.PanelRefreshStatus?
    ) -> Self {
        if status?.isStale == true { return hasSnapshot ? .retainedFailure : .unavailable }
        guard status != nil else { return .loading }
        return hasSnapshot ? .current : .empty
    }

    var adverseMessage: String? {
        switch self {
        case .retainedFailure:
            return "Refresh couldn't complete — showing the last known state."
        case .unavailable:
            return "Refresh couldn't complete — current state is unavailable; no calm or needs-nothing state was inferred."
        case .empty:
            return "Refresh completed, but no current state was available."
        case .loading, .current:
            return nil
        }
    }
}
