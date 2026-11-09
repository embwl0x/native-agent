import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `NewDeskTaskSheet.swift` | Shared task form with retained drafts, field validation and owner settlement |

enum NewDeskTaskOutcome {
    case created
    case failed(FaceActOutcome)
}

struct NewDeskTaskSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    private var session: FacePageSession { appModel.pageSessions.page("desk-task/new") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FaceView(face: page, door: door, session: session)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 420)
        .macFaceStyle()
    }

    private var page: PartFace {
        PartFace(title: "New Desk Task", sections: [
            .init(id: "task", rows: [], block: .init(kind: "form", key: "desk-task/new", fields: [
                .init(id: "title", label: "Title", kind: "line", value: .string(""), required: true),
                .init(id: "objective", label: "Objective", kind: "lines", value: .string("")),
            ], submit: [.init(id: "create", label: "Create Task", role: .primary, call: .init("desk.task.create"))])),
        ])
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "task creation", perform: { submission in
            guard !submission.checking else {
                return .interrupted(WireFailure(code: "desk_task_unconfirmed",
                    message: "Read Desk to check whether this task was created before submitting again.", cause: nil, effects: .unknown))
            }
            guard submission.action == "create", submission.expectedCall == PartFace.Call("desk.task.create"),
                  let values = submission.values, case .string(let title)? = values["title"],
                  case .string(let objective)? = values["objective"] else {
                return .interrupted(WireFailure(code: "desk_task_form_invalid",
                    message: "Open New task again; its form values are incomplete.", cause: nil, effects: .none))
            }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                return .interrupted(WireFailure(code: "desk_task_title_required",
                    message: "Enter a task title.", cause: nil, effects: .none, fields: ["title": "Enter a task title."]))
            }
            let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            switch await appModel.createDeskTask(title: trimmedTitle, objective: trimmedObjective.isEmpty ? trimmedTitle : trimmedObjective) {
            case .failed(let outcome): return outcome
            case .created:
                return .init(words: "Desk task created.", effects: .known, accepted: true, committed: [
                    .init(id: "title", value: .string(title)), .init(id: "objective", value: .string(objective)),
                ])
            }
        })
    }
}
