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

// PATCH-2026-05-19: ui-pull-together — Executions keeps execution-adjacent
// operational pages only. Self-Improvement owns harness proposals separately.
private enum WorkshopMode: String, CaseIterable, Identifiable {
    case desk = "Bench"
    case schedule = "Schedule"
    case research = "Research"
    var id: String { rawValue }
}

struct WorkshopHubView: View {
    @State private var mode: WorkshopMode = .desk

    var body: some View {
        VStack(spacing: 12) {
            Picker("Workshop", selection: $mode) {
                ForEach(WorkshopMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top)

            Group {
                switch mode {
                case .desk: DeskView()
                case .schedule: SchedulerView()
                case .research: ResearchView()
                }
            }
        }
        .navigationTitle("Workshop")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Task", systemImage: "plus.circle") {
                    // B2.3 follow-up: the sheet itself is presented by ContentView.
                    // A `.sheet` attached here (NavigationSplitView detail content)
                    // presents exactly once on macOS — after the first dismiss the
                    // window never honors a re-present from this attachment point.
                    // Same notification→ContentView pattern as the command palette.
                    NotificationCenter.default.post(name: .newWorkshopTaskRequest, object: nil)
                }
            }
        }
    }
}

// B2.3: the single unique control salvaged from the retired Command Center —
// Title + Objective → AppModel.createWorkshopTask. Behavior mirrors the old
// panel: createWorkshopTask reports via statusText ("Workshop task created" on
// success, "Workshop task creation failed: …" on error), so we dismiss only
// when the status does not indicate failure, never eating the user's text.
struct NewWorkshopTaskSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var objective = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            Text("New Workshop Task")
                .font(NativeAgentFont.title)

            Form {
                TextField("Title", text: $title)
                TextField("Objective", text: $objective, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Task", systemImage: "plus.circle") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(minWidth: 420)
    }

    private func submit() {
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        Task {
            await appModel.createWorkshopTask(
                title: nextTitle,
                objective: nextObjective.isEmpty ? nextTitle : nextObjective
            )
            submitting = false
            if !appModel.statusText.hasPrefix("Workshop task creation failed") {
                dismiss()
            }
        }
    }
}
