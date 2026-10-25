import Cognition
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
import TriggerScheduler
import EngineRuntime
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// Blueprint: | `SchedulerView.swift` | `SchedulerView`: scheduled job controls and explicit accepted/refused toggle receipts |

/// What the Scheduler screen says after a pause/resume settles. The switch is a
/// control now (item 36), so every outcome gets a line: a refused write must
/// never read like an accepted one.
enum SchedulerJobToggleOutcome: Equatable {
    case verified(ScheduledJob)
    case failed(String)
}

enum SchedulerJobTogglePresentation {
    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    static func receipt(
        jobName: String,
        requestedEnabled: Bool,
        outcome: SchedulerJobToggleOutcome
    ) -> Message {
        switch outcome {
        case .verified(let job):
            let name = nonempty(job.name, fallback: jobName)
            return Message(
                text: "\(name) is \(job.enabled ? "enabled" : "paused").",
                isError: false
            )
        case .failed(let detail):
            return Message(
                text: "Could not \(requestedEnabled ? "enable" : "pause") "
                    + "\(nonempty(jobName, fallback: "job")): "
                    + nonempty(detail, fallback: "the scheduler did not confirm the change"),
                isError: true
            )
        }
    }

    private static func nonempty(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

struct SchedulerView: View {
    @Environment(AppModel.self) private var appModel
    private var isLoadingJobs: Bool { appModel.engine.desk.jobsFeedState == nil || appModel.engine.desk.isRefreshingJobs }
    @State private var isAddingReflection = false
    @State private var reflectionOutcome: NightlyReflectionJobOutcome?
    private var jobsLoadResult: SchedulerJobsFeedState? { appModel.engine.desk.jobsFeedState }
    @State private var togglingJobIDs: Set<String> = []
    @State private var toggleMessage: SchedulerJobTogglePresentation.Message?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                addNightlyReflection()
            } label: {
                if isAddingReflection {
                    Label("Adding Nightly Reflection", systemImage: "hourglass")
                } else {
                    Label("Add Nightly Reflection", systemImage: "moon.stars")
                }
            }
            .disabled(isAddingReflection || isLoadingJobs)

            if let reflectionOutcome {
                Label(
                    reflectionOutcome.message,
                    systemImage: reflectionOutcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(reflectionOutcome.succeeded ? Color.secondary : Color.red)
            }

            if isLoadingJobs, appModel.engine.desk.jobs.isEmpty {
                ProgressView("Loading schedule")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = jobsLoadResult?.failureDetail, appModel.engine.desk.jobs.isEmpty {
                NativeEmptyState(
                    title: "Schedule unavailable",
                    detail: detail,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    actionImage: "arrow.clockwise",
                    action: { Task { await appModel.refreshSchedulerJobs() } }
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if isLoadingJobs {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing schedule…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let detail = jobsLoadResult?.failureDetail {
                        StalePanelNotice(text: detail)
                    }
                    if let toggleMessage {
                        Text(toggleMessage.text)
                            .font(.caption)
                            .foregroundStyle(toggleMessage.isError ? Color.red : Color.secondary)
                    }
                    List(appModel.engine.desk.jobs) { job in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading) {
                                Text(job.name)
                                Text(job.kind)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let once = job.onceScheduleDescription {
                                    Text(once)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            // Item 36: this used to be a plain Text reading
                            // "enabled"/"paused" beside a write nothing called.
                            // It is the control now — the state User reads and
                            // the state he sets are the same thing.
                            Toggle("", isOn: Binding(
                                get: { job.enabled },
                                set: { setEnabled(job, $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .hazeTinted()
                            .disabled(togglingJobIDs.contains(job.id))
                            .accessibilityLabel("\(job.name) enabled")
                        }
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Scheduler")
        .task(id: appModel.engine.desk.jobsPath) {
            await appModel.engine.desk.watchJobs()
        }
    }

    /// One pause/resume per job in flight. The row is repainted from
    /// `engine.desk.jobs` after the write settles, so the switch always shows the
    /// store's truth rather than the click's.
    private func setEnabled(_ job: ScheduledJob, _ enabled: Bool) {
        guard !togglingJobIDs.contains(job.id) else { return }
        togglingJobIDs.insert(job.id)
        toggleMessage = nil
        Task { @MainActor in
            let outcome = await appModel.setSchedulerJobEnabled(id: job.id, enabled: enabled)
            togglingJobIDs.remove(job.id)
            toggleMessage = SchedulerJobTogglePresentation.receipt(
                jobName: job.name,
                requestedEnabled: enabled,
                outcome: outcome
            )
        }
    }

    private func addNightlyReflection() {
        guard !isAddingReflection else { return }
        isAddingReflection = true
        reflectionOutcome = nil
        Task {
            reflectionOutcome = await appModel.createDreamJob()
            isAddingReflection = false
        }
    }


}
