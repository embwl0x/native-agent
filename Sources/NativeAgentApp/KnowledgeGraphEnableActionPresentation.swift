import Foundation

/// Presentation state for the mounted Knowledge Graph enable action. A policy
/// write is not a graph read: success means the canonical Memory Policy
/// committed, even if the follow-up graph load later has no rows or fails.
enum KnowledgeGraphEnableActionPresentation: Equatable {
    case idle
    case enabling
    case enabled
    case failed(String)

    struct ButtonControl: Equatable {
        let title: String
        let systemImage: String
        let isDisabled: Bool
    }

    static func buttonControl(isEnabling: Bool) -> ButtonControl {
        ButtonControl(
            title: isEnabling ? "Enabling..." : "Enable Knowledge Graph",
            systemImage: isEnabling ? "hourglass" : "checkmark.circle",
            isDisabled: isEnabling
        )
    }

    static func failure(statusText: String) -> Self {
        let detail = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(
            detail.isEmpty
                ? "Knowledge Graph could not be enabled because the Memory Policy write failed."
                : "Knowledge Graph could not be enabled. \(detail)"
        )
    }

    var completionMessage: String? {
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

/// The enable operation is separate from graph loading: its durable success
/// condition is the checked Memory Policy write. Keeping the action here lets
/// the mounted page and non-UI callers share one outcome contract.
enum KnowledgeGraphEnableAction {
    @MainActor
    static func perform(using appModel: AppModel) async -> KnowledgeGraphEnableActionPresentation {
        guard await appModel.patchMemoryPolicy(knowledgeGraphEnabled: true),
              appModel.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == true else {
            return .failure(statusText: appModel.statusText)
        }
        return .enabled
    }
}
