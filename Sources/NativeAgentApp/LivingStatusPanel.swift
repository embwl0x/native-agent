import SwiftUI
import ApprovalInbox
import Cognition
import CognitiveSubstrate
import NativeAgentShared
import PersistenceCore
import DeviceSync
import DreamREMCycle

struct LivingStatusPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    private var cognition: CognitionViewFacade { appModel.engine.cognitionView }
    private var snapshot: LivingStatusSnapshot? {
        get { cognition.livingSnapshot }
        nonmutating set { cognition.livingSnapshot = newValue }
    }
    private var refreshCoalescer: LivingStatusRefreshCoalescer {
        get { cognition.livingRefreshCoalescer }
        nonmutating set { cognition.livingRefreshCoalescer = newValue }
    }
    private var refreshStatus: AppModel.PanelRefreshStatus? {
        get { cognition.livingRefreshStatus }
        nonmutating set { cognition.livingRefreshStatus = newValue }
    }
    @State private var fileWatchAvailability: LivingStatusFileWatch.Availability?

    private var isRefreshing: Bool { refreshCoalescer.isRefreshing }

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
        guard refreshCoalescer.requestRefresh() else { return }
        while true {
            await refreshOnce()
            guard !Task.isCancelled else {
                refreshCoalescer.cancel()
                return
            }
            guard refreshCoalescer.completePass() else { return }
            if !refreshCoalescer.trailingPassConsumed {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    refreshCoalescer.cancel()
                    return
                }
            }
        }
    }

    @MainActor
    private func refreshOnce() async {
        let outcome = await LivingStatusRefreshOperation.run(appModel: appModel)
        snapshot = outcome.applying(to: snapshot)
        refreshStatus = outcome.status(previous: refreshStatus)
    }

}
