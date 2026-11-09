import NativeAgentShared
// Blueprint: | `AppModel+MemoryActions.swift` | Memory pin/forget acts carry identities and await committed body outcomes |

enum MemoryRowEditorPinOutcome: Equatable {
    case applied(pinned: Bool)
    case failed(String)

    var message: String {
        switch self {
        case .applied(let pinned): return pinned ? "Memory pinned" : "Memory unpinned"
        case .failed(let detail): return detail
        }
    }

    var isAdverse: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
extension AppModel {
    func pinMemory(id: String, pinned: Bool) async -> MemoryRowEditorPinOutcome {
        do {
            try await client.act(.pinMemory(id: id, pinned: pinned)).checkedAcknowledgement()
            let outcome = MemoryRowEditorPinOutcome.applied(pinned: pinned)
            statusText = outcome.message
            return outcome
        } catch {
            let outcome = MemoryRowEditorPinOutcome.failed(FaceActionFeedback.message(error, action: "update that memory"))
            statusText = outcome.message
            systemToasts.push(error: statusText)
            return outcome
        }
    }

    func deleteMemory(id: String) async -> Bool {
        do {
            try await client.act(.forgetMemory(id: id)).checkedAcknowledgement()
            statusText = "Memory deleted"
            return true
        } catch {
            statusText = FaceActionFeedback.message(error, action: "forget that memory")
            systemToasts.push(error: statusText)
            return false
        }
    }
}
