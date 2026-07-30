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

struct SchedulerView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isLoadingJobs = true
    @State private var isAddingReflection = false
    @State private var reflectionOutcome: NightlyReflectionJobOutcome?
    @State private var jobsLoadError: String?

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
            } else if let jobsLoadError {
                NativeEmptyState(
                    title: "Schedule unavailable",
                    detail: jobsLoadError,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    actionImage: "arrow.clockwise",
                    action: { Task { await loadJobs() } }
                )
            } else {
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
        .padding()
        .navigationTitle("Scheduler")
        .task {
            await loadJobs()
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
        jobsLoadError = nil
        if !(await appModel.refreshSchedulerJobs()) {
            jobsLoadError = appModel.statusText
        }
        isLoadingJobs = false
    }
}
