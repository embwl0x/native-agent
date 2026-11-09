import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `MacControlWorkbenchView.swift` | Shared Mac control forms, policy availability and retained owner outcomes |

struct MacControlWorkbenchView: View {
    @Environment(AppModel.self) private var appModel
    var policy: MacControlPolicyWireSnapshot
    var policySaved: Bool = true
    @State private var resultTitle = "Mac control receipt"
    @State private var resultBody: String?
    @State private var resultRevision = UUID()
    private var session: FacePageSession { appModel.pageSessions.page("mac-control/workbench") }

    var body: some View {
        FaceView(face: page, door: door, session: session).macFaceStyle()
    }

    private func submit(_ action: MacControlWorkbenchAction) -> PartFace.Action {
        let availability = action.availability(policy: policy, policySaved: policySaved)
        let anotherOperation = session.operations.values.contains { $0.outcome == nil || $0.outcome?.unresolved == true }
        return .init(id: action.rawValue, label: action.title, call: .init("workbench", ["action": .string(action.rawValue)]),
                     unavailable: availability.message ?? (anotherOperation ? "Waiting on the current Mac control action." : nil))
    }

    private var page: PartFace {
        var sections: [PartFace.Section] = [
            .init(id: "shell", title: "Terminal command", rows: [], block: .init(kind: "form", key: "workbench-shell", fields: [
                .init(id: "cwd", label: "Working directory", value: .string(NSHomeDirectory())),
                .init(id: "command", label: "Command", kind: "lines", value: .string("pwd"), required: true),
            ], submit: [submit(.shell)])),
            .init(id: "files", title: "Files", rows: [], block: .init(kind: "form", key: "workbench-files", fields: [
                .init(id: "path", label: "Path", value: .string(NSHomeDirectory()), required: true),
                .init(id: "content", label: "Write content", kind: "lines", value: .string("")),
                .init(id: "append", label: "Append instead of replace", kind: "switch", value: .bool(false)),
            ], submit: [submit(.fileRead), submit(.fileWrite)])),
            .init(id: "notification", title: "Notification", rows: [], block: .init(kind: "form", key: "workbench-notify", fields: [
                .init(id: "title", label: "Notification title", value: .string("NativeAgent")),
                .init(id: "message", label: "Notification message", value: .string("Mac Control workbench test"), required: true),
            ], submit: [submit(.notify)])),
        ]
        if let resultBody {
            sections.append(.init(id: "receipt", title: resultTitle, rows: [], block: .init(key: "workbench-receipt",
                text: resultBody.utf8.count <= PartFace.Block.inlineByteLimit ? resultBody : nil, format: "code",
                revision: resultRevision.uuidString)))
        }
        return PartFace(title: "Workbench", line: "Run one Mac control action and read its owner's receipt.", sections: sections)
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "Mac control", read: { request in
            guard request.key == "workbench-receipt", request.revision == resultRevision.uuidString, let resultBody else {
                throw PartCallError(code: "workbench_receipt_changed", message: "The Mac control receipt changed. Read the current receipt.")
            }
            return resultBody
        }, perform: { submission in
            if submission.checking {
                return await readOperation(submission)
            }
            guard let action = MacControlWorkbenchAction(rawValue: submission.action),
                  submission.expectedCall == PartFace.Call("workbench", ["action": .string(action.rawValue)]),
                  let values = submission.values else {
                return .interrupted(WireFailure(code: "workbench_form_invalid",
                    message: "Open the workbench again; the submitted action does not match its form.", cause: nil, effects: .none))
            }
            if let issue = action.availability(policy: policy, policySaved: policySaved).message {
                return .interrupted(WireFailure(code: "workbench_policy_unavailable", message: issue, cause: nil, effects: .none))
            }
            guard !session.operations.values.contains(where: {
                $0.submission.id != submission.id && ($0.outcome == nil || $0.outcome?.unresolved == true)
            }) else {
                return .interrupted(WireFailure(code: "workbench_in_use",
                    message: "Wait for the current Mac control action's outcome.", cause: nil, effects: .none))
            }
            var body: [String: PartFace.Value]
            switch action {
            case .shell:
                guard case .string(let command)? = values["command"], case .string(let cwd)? = values["cwd"] else {
                    return invalidValues()
                }
                body = ["command": .string(command), "cwd": .string(cwd), "timeout": .int(60), "trigger": .string("user")]
            case .fileRead:
                guard case .string(let path)? = values["path"] else { return invalidValues() }
                body = ["path": .string(path), "max_bytes": .int(200_000), "trigger": .string("user")]
            case .fileWrite:
                guard case .string(let path)? = values["path"], case .string(let content)? = values["content"],
                      case .bool(let append)? = values["append"] else { return invalidValues() }
                guard !content.isEmpty else {
                    return .interrupted(WireFailure(code: "workbench_content_required", message: "Enter write content.", cause: nil, effects: .none,
                                                    fields: ["content": "Enter write content."]))
                }
                body = ["path": .string(path), "content": .string(content), "append": .bool(append), "trigger": .string("user")]
            case .notify:
                guard case .string(let title)? = values["title"], case .string(let message)? = values["message"] else { return invalidValues() }
                body = ["title": .string(title), "message": .string(message), "trigger": .string("user")]
            }
            body["operationId"] = .string(submission.id.uuidString)
            do {
                defer { resultRevision = UUID() }
                let result = try await appModel.macControlRun(action: action.rawValue, body: body)
                resultBody = String(decoding: try JSONEncoder().encode(result.value), as: UTF8.self)
                let outcome = action.settlement(result.value, fields: values, publicationFailure: result.publicationFailure)
                resultTitle = outcome.unresolved ? "Outcome unconfirmed" : outcome.failure == nil ? "Done" : "Failed"
                return outcome
            } catch {
                resultTitle = "Reply unavailable"
                resultBody = error.localizedDescription
                resultRevision = UUID()
                if action == .fileRead {
                    return .interrupted(WireFailure(code: "workbench_read_failed", message: "The file could not be read.",
                        cause: error.localizedDescription, effects: .none))
                }
                return .interrupted(error)
            }
        })
    }

    private func readOperation(_ submission: FaceActSubmission) async -> FaceActOutcome {
        guard let action = MacControlWorkbenchAction(rawValue: submission.action) else { return invalidValues() }
        do {
            let result = try await appModel.macControlRead(action: action.rawValue, operation: submission.id)
            resultBody = String(decoding: try JSONEncoder().encode(result.value), as: UTF8.self)
            resultRevision = UUID()
            var outcome = action.settlement(result.value, fields: submission.values ?? [:], publicationFailure: result.publicationFailure)
            // Acceptance here is the successful read of the original operation, even when that operation failed.
            outcome.accepted = !outcome.unresolved
            resultTitle = outcome.unresolved ? "Outcome unconfirmed" : outcome.failure == nil ? "Done" : "Failed"
            return outcome
        } catch { return .interrupted(error) }
    }

    private func invalidValues() -> FaceActOutcome {
        .interrupted(WireFailure(code: "workbench_fields_invalid",
            message: "The workbench action is missing required form values. Open its form again.", cause: nil, effects: .none))
    }
}

extension MacControlWorkbenchAction {
    var title: String {
        switch self {
        case .shell: "Run Shell"
        case .fileRead: "Read File"
        case .fileWrite: "Write File"
        case .notify: "Notify"
        }
    }
}
