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

/// The mounted Scheduler's canonical jobs-feed lifecycle. The stream arms
/// before its first read, so a job mutation racing view appearance is replayed
/// instead of leaving an enabled/paused row stale until the screen is reopened.
enum SchedulerJobsLiveRefresh {
    @MainActor
    static func observe(
        path: URL,
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        await ViewFileRefreshTask.run(
            paths: [path],
            debounceDelay: .milliseconds(100),
            refresh: refresh
        )
    }
}

struct SchedulerView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isLoadingJobs = true
    @State private var isAddingReflection = false
    @State private var reflectionOutcome: NightlyReflectionJobOutcome?
    @State private var jobsLoadResult: SchedulerJobsRefreshResult?

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

            if isLoadingJobs {
                ProgressView("Loading schedule")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = jobsLoadResult?.failureDetail, appModel.jobs.isEmpty {
                NativeEmptyState(
                    title: "Schedule unavailable",
                    detail: detail,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    actionImage: "arrow.clockwise",
                    action: { Task { await loadJobs() } }
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let detail = jobsLoadResult?.failureDetail {
                        StalePanelNotice(text: detail)
                    }
                    List(appModel.jobs) { job in
                        VStack(alignment: .leading) {
                            Text(job.name)
                            Text("\(job.kind) · \(job.enabled ? "enabled" : "paused")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Scheduler")
        .task(id: appModel.client.schedulerJobsPath) {
            let jobsPath = appModel.client.schedulerJobsPath
            await SchedulerJobsLiveRefresh.observe(path: jobsPath) {
                await loadJobs()
            }
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

    @MainActor
    private func loadJobs() async {
        isLoadingJobs = true
        jobsLoadResult = nil
        jobsLoadResult = await appModel.refreshSchedulerJobs()
        isLoadingJobs = false
    }
}
