import Foundation

/// Presentation state for the Knowledge Graph opt-out action. A policy
/// write is not a graph read: success means the canonical Memory Policy
/// committed, even if the follow-up graph load later has no rows or fails.
enum KnowledgeGraphEnableActionPresentation: Equatable {
    case idle
    case enabling
    case enabled
    case disabling
    case disabled
    case failed(String)

    struct ButtonControl: Equatable {
        let title: String
        let systemImage: String
        let isDisabled: Bool
    }

    static func buttonControl(isEnabling: Bool, isEnabled: Bool = false) -> ButtonControl {
        ButtonControl(
            title: isEnabling
                ? (isEnabled ? "Disabling..." : "Enabling...")
                : (isEnabled ? "Disable Knowledge Graph" : "Enable Knowledge Graph"),
            systemImage: isEnabling ? "hourglass" : (isEnabled ? "pause.circle" : "checkmark.circle"),
            isDisabled: isEnabling
        )
    }

    static func failure(statusText: String, enabling: Bool = false) -> Self {
        let detail = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = enabling ? "enabled" : "disabled"
        return .failed(
            detail.isEmpty
                ? "Knowledge Graph could not be \(action) because the memory settings could not be saved."
                : "Knowledge Graph could not be \(action). \(detail)"
        )
    }

    var completionMessage: String? {
        if case .disabled = self {
            return "Knowledge Graph disabled. New conversations will no longer contribute entity links."
        }
        if case .enabled = self {
            return "Knowledge Graph enabled. New conversations can now contribute entity links."
        }
        return nil
    }

    var failureMessage: String? {
        if case let .failed(detail) = self {
            return detail
        }
        return nil
    }
}

/// The policy operation is separate from graph loading: its durable success
/// condition is the checked Memory Policy write. Keeping the action here lets
/// the mounted page and non-UI callers share one outcome contract.
enum KnowledgeGraphEnableAction {
    @MainActor
    static func perform(using appModel: AppModel, enabled: Bool = true) async -> KnowledgeGraphEnableActionPresentation {
        guard await appModel.patchMemoryPolicy(knowledgeGraphEnabled: enabled),
              appModel.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == enabled else {
            return .failure(statusText: appModel.statusText, enabling: enabled)
        }
        return enabled ? .enabled : .disabled
    }
}
