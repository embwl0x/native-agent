import MemoryV2
import NativeAgentShared
import EngineRuntime
// Blueprint: | `AppModel+MemoryActions.swift` | `AppModel`: `pinMemory`, `deleteMemory` |

/// The row editor's claim about a pin change: made, or failed and why.
enum MemoryRowEditorPinOutcome: Equatable {
    case applied(pinned: Bool)
    case failed(String)

    var message: String {
        switch self {
        case let .applied(pinned):
            return pinned ? "Memory pinned" : "Memory unpinned"
        case let .failed(detail):
            return detail
        }
    }

    var isAdverse: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
extension AppModel {
    @MainActor
    func pinMemory(_ memory: MemoryV2.MemoryRecord, pinned: Bool) async -> MemoryRowEditorPinOutcome {
        do {
            try await engine.memory.setPinned(pinned, id: memory.id)
            let outcome = MemoryRowEditorPinOutcome.applied(pinned: pinned)
            _ = await refreshForSidebarItem(.memories)
            statusText = outcome.message
            return outcome
        } catch {
            let outcome = MemoryRowEditorPinOutcome.failed(
                UserFacingError.message(error, action: "update that memory")
            )
            statusText = outcome.message
            systemToasts.push(error: statusText)
            return outcome
        }
    }

    /// False when the memory is still there; `statusText` says why.
    @MainActor
    func deleteMemory(_ memory: MemoryV2.MemoryRecord) async -> Bool {
        do {
            try await engine.memory.delete(id: memory.id)
            _ = await refreshForSidebarItem(.memories)
            statusText = "Memory deleted"
            return true
        } catch {
            setFailureStatus(error, action: "forget that memory")
            return false
        }
    }
}
