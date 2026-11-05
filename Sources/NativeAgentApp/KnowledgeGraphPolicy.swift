import EngineRuntime
import Foundation
import SwiftUI
import AppKit
import MemoryV2
import Combine
import Cognition
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `KnowledgeGraphPolicy.swift` | Checked Memory Policy reads/writes and enable/disable presentation |

/// Only the canonical Memory Policy write proves policy success; a later graph load may be empty or fail independently.
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

/// Share the checked policy-write outcome between mounted and non-UI callers; graph loading is a separate operation.
enum KnowledgeGraphEnableAction {
    @MainActor
    static func perform(using appModel: AppModel, enabled: Bool = true) async -> KnowledgeGraphEnableActionPresentation {
        guard await appModel.patchMemoryPolicy(knowledgeGraphEnabled: enabled),
              appModel.engine.trust.policy?.memoryPolicy?.knowledge_graph_enabled == enabled else {
            return .failure(statusText: appModel.statusText, enabling: enabled)
        }
        return enabled ? .enabled : .disabled
    }
}

extension KnowledgeGraphView {
    /// Read policy authority independently so unreadable graph data cannot leave setup checking forever; enable requires the checked policy.
    func loadKnowledgeGraphPolicy() async -> Bool {
        if appModel.engine.trust.policy != nil {
            policyReadError = nil
            return true
        }
        do {
            _ = try await appModel.engine.trust.load()
            policyReadError = nil
            return true
        } catch {
            policyReadError = UserFacingError.message(error, action: "read the trust policy")
            return false
        }
    }

    func reloadKnowledgeGraphPolicyAndGraph() async {
        guard await loadKnowledgeGraphPolicy() else { return }
        await loadGraph()
    }

    func enableKnowledgeGraph(enabled: Bool = true) async {
        guard !isEnablingGraph else { return }
        isEnablingGraph = true
        defer { isEnablingGraph = false }
        enableActionPresentation = enabled ? .enabling : .disabling
        errorMsg = nil
        errorOrigin = nil
        let outcome = await KnowledgeGraphEnableAction.perform(using: appModel, enabled: enabled)
        enableActionPresentation = outcome
        guard outcome == .enabled || outcome == .disabled else { return }
        await loadGraph()
    }
}
