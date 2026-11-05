import SwiftUI
import AppKit
import NativeAgentShared
import PersistenceCore

// Blueprint: | `NewDeskTaskSheet.swift` | `NewDeskTaskSheet`: retained task draft opened by the Desk face's new-task action |

enum NewDeskTaskOutcome {
    case created
    case failed(String)
}

/// Retain the draft on failure so task creation cannot lose the user's words.
struct NewDeskTaskSheet: View {
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
            let outcome = await appModel.createDeskTask(
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
