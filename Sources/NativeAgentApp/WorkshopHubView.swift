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

// The Desk is the agent's one work surface. Schedule and Research are adjacent
// views over the same mind and canonical stores; the Workshop execution engine
// remains an implementation detail behind directed Desk runs.
enum DeskMode: String, CaseIterable, Identifiable {
    case desk = "Desk"
    case schedule = "Schedule"
    case research = "Research"
    var id: String { rawValue }
}

/// A route to the Desk is a route to its root, not merely to whatever Desk
/// subpage happened to be left open. ContentView advances this token for every
/// Desk selection; the hub consumes it by returning to the Desk mode.
enum DeskRootRoutePresentation {
    static func nextRootRouteVersion(current: Int, destination: SidebarItem) -> Int {
        destination.normalized == .desk ? current &+ 1 : current
    }

    static func mode(afterRootRequestFrom _: DeskMode) -> DeskMode { .desk }

    /// D9: "New Task" creates a DESK task. Mounted in every mode it was a
    /// control the Schedule and Research views do not own and cannot show the
    /// result of — a button that appears to act on what you are looking at and
    /// does not. It now exists only where its output lands.
    static func showsNewTaskAction(in mode: DeskMode) -> Bool { mode == .desk }
}

struct DeskHubView: View {
    let rootRouteVersion: Int
    @State private var mode: DeskMode = .desk

    init(rootRouteVersion: Int = 0) {
        self.rootRouteVersion = rootRouteVersion
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Desk", selection: $mode) {
                ForEach(DeskMode.allCases) { item in
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
        .navigationTitle("Desk")
        .onChange(of: rootRouteVersion) { _, _ in
            mode = DeskRootRoutePresentation.mode(afterRootRequestFrom: mode)
        }
        .toolbar {
            // The condition wraps the ToolbarItem, not its content: an item
            // whose builder resolves to nothing still reserves a blank slot.
            if DeskRootRoutePresentation.showsNewTaskAction(in: mode) {
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
}

enum NewDeskTaskPresentation {
    static let successStatus = "Desk task created"
    private static let failurePrefix = "Desk task creation failed:"

    static func failureStatus(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return failurePrefix }
        return "\(failurePrefix) \(trimmed)"
    }

    static func inlineError(from statusText: String) -> String? {
        guard statusText.hasPrefix(failurePrefix) else { return nil }
        let detail = statusText.dropFirst(failurePrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The sheet stays open on failure, so this line is the only thing the
        // person sees. A bare backend detail ("connection lost") reads as a
        // riddle without the sentence that says what it stopped.
        return detail.isEmpty
            ? "Couldn’t create this task. Try again."
            : "Couldn’t create this task. \(detail)"
    }
}

// B2.3: the single unique control salvaged from the retired Command Center —
// Title + Objective → AppModel.createWorkshopTask. The implementation keeps
// its compatibility name, but the user-facing task belongs to the Desk. We
// dismiss only when the runner did not report a creation failure.
// when the status does not indicate failure, never eating the user's text.
struct NewWorkshopTaskSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var objective = ""
    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            Text("New Desk Task")
                .font(NativeAgentFont.title)

            Form {
                TextField("Title", text: $title)
                TextField("Objective", text: $objective, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.red)
            }

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
        errorMessage = nil
        submitting = true
        Task {
            await appModel.createWorkshopTask(
                title: nextTitle,
                objective: nextObjective.isEmpty ? nextTitle : nextObjective
            )
            submitting = false
            if let inlineError = NewDeskTaskPresentation.inlineError(from: appModel.statusText) {
                errorMessage = inlineError
            } else {
                dismiss()
            }
        }
    }
}
