import SwiftUI
import AppKit
import NativeAgentShared
import PersistenceCore

// Blueprint: | `WorkshopHubView.swift` | `DeskRootRoutePresentation` and `NewWorkshopTaskSheet`: root-navigation token and explicit task submission with retained draft/error state |

/// A route to the Desk is a route to its root, not merely to whatever Desk
/// fold happened to be left open. ContentView advances this token for every
/// Desk selection; DeskPageView consumes it by closing its folds.
enum DeskRootRoutePresentation {
    static func nextRootRouteVersion(current: Int, destination: SidebarItem) -> Int {
        destination.normalized == .desk ? current &+ 1 : current
    }
}

enum NewDeskTaskOutcome {
    case created
    case failed(String)
}

/// Retains the task draft until creation succeeds.
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
            let outcome = await appModel.createWorkshopTask(
                title: nextTitle,
                objective: nextObjective.isEmpty ? nextTitle : nextObjective
            )
            submitting = false
            switch outcome {
            case .failed(let message):
                errorMessage = message
            case .created:
                if appModel.editDraft(draftSubject, seed: submitted) == submitted { appModel.clearEditDraft(draftSubject) }
                NotificationCenter.default.post(name: .deskTaskCreated, object: nil)
                dismiss()
            }
        }
    }
}
