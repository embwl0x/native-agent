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

// Blueprint: | `WorkshopHubView.swift` | `DeskRootRoutePresentation` and `NewWorkshopTaskSheet`: root-navigation token and explicit task submission with retained draft/error state |

/// A route to the Desk is a route to its root, not merely to whatever Desk
/// fold happened to be left open. ContentView advances this token for every
/// Desk selection; DeskPageView consumes it by closing its folds.
enum DeskRootRoutePresentation {
    static func nextRootRouteVersion(current: Int, destination: SidebarItem) -> Int {
        destination.normalized == .desk ? current &+ 1 : current
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
// dismiss only when creation succeeded, never eating the user's text on failure.
struct NewWorkshopTaskSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    private struct Draft: Equatable {
        var title = ""
        var objective = ""
    }
    private let draftSubject = "desk-task/new"
    private var draft: Binding<Draft> { appModel.editBinding(draftSubject, seed: Draft()) }
    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            Text("New Desk Task")
                .font(NativeAgentFont.title)

            Form {
                TextField("Title", text: draft.title)
                TextField("Objective", text: draft.objective, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)
            .disabled(submitting)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { appModel.clearEditDraft(draftSubject); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button("Create Task", systemImage: "plus.circle") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .hazeTinted(.button)
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || draft.wrappedValue.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(minWidth: 420)
        .interactiveDismissDisabled(submitting)
    }

    private func submit() {
        let submitted = draft.wrappedValue
        let nextTitle = submitted.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextObjective = submitted.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        submitting = true
        Task {
            let succeeded = await appModel.createWorkshopTask(
                title: nextTitle,
                objective: nextObjective.isEmpty ? nextTitle : nextObjective
            )
            submitting = false
            if !succeeded {
                errorMessage = NewDeskTaskPresentation.inlineError(from: appModel.statusText)
            } else {
                if appModel.editDraft(draftSubject, seed: submitted) == submitted { appModel.clearEditDraft(draftSubject) }
                NotificationCenter.default.post(name: .deskTaskCreated, object: nil)
                dismiss()
            }
        }
    }
}
