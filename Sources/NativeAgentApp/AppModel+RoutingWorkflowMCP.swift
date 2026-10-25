import Foundation
import EngineRuntime
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import ToolExecution
import PersonaEngine
import TrustCenter
import DreamREMCycle
import DoctorChecks
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacIntegration
import WorkflowOrchestration
import Connectors
import Browser
// Blueprint: | `AppModel+RoutingWorkflowMCP.swift` | `ResearchSearchFailure`; `AppModel`: research `search`, `resolveApproval`, `resolveApprovalOnce`, `isResolvingApproval` |

enum ResearchSearchFailure: Error, Equatable {
    case blankQuery
    case requestFailed(String)

    var message: String {
        switch self {
        case .blankQuery:
            return "Enter a research query."
        case .requestFailed(let message):
            return message
        }
    }
}

// 2026-09-01: `WorkflowLifecycleAction`, `WorkflowLifecycleActionOutcome`, and
// `WorkflowLifecycleButtonPresentation` were retired with the workflow run
// engine (User authorized). They existed only to drive Resume / Cancel /
// Rollback on a run.

@MainActor
extension AppModel {
    @MainActor
    func search(_ query: String) async -> Result<[ResearchSearchResult], ResearchSearchFailure> {
        let research = SwiftNativeResearchClient(dataRoot: engine.dataRoot)
        return await search(query) { trimmed in
            return try await research.search(query: trimmed).results
        }
    }

    @MainActor
    func search(
        _ query: String,
        using operation: (String) async throws -> [ResearchSearchResult]
    ) async -> Result<[ResearchSearchResult], ResearchSearchFailure> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankQuery) }
        do {
            return .success(try await operation(trimmed))
        } catch {
            setFailureStatus(error, action: "run that research")
            return .failure(.requestFailed(error.localizedDescription))
        }
    }


    /// W3: returns true if an NSError thrown by an app action is a
    /// `notImplemented` envelope (panelDisabled feature, unavailable Swift impl).
    static func isNotImplemented(_ err: NSError) -> Bool {
        return (err.userInfo["code"] as? String) == "not_implemented"
            || (err.userInfo["panelDisabled"] as? Bool) == true
    }

    /// W3: format a user-facing "feature disabled" string from the
    /// `notImplemented` envelope, including the followup link if present.
    static func disabledBadge(for label: String, error err: NSError) -> String {
        let reason = (err.userInfo["reason"] as? String) ?? "unavailable in the Swift runtime"
        var msg = "\(label) disabled — \(reason)"
        if let followup = err.userInfo["followup"] as? String, !followup.isEmpty {
            msg += " (see: \(followup))"
        }
        return msg
    }

    @MainActor
    func resolveApproval(_ approval: ApprovalRecord, decision: String) async {
        let result = await resolveApprovalOnce(id: approval.id, decision: decision)
        switch result {
        case .applied:
            statusText = result.visibleMessage
            await refreshAll()
        case .noOpAlreadyResolved:
            statusText = result.visibleMessage
            await refreshAll()
        case .noOpInFlight, .unavailable:
            statusText = result.visibleMessage
        }
    }

    /// Coalesce simultaneous decisions from the full Approvals screen and
    /// any mounted inline control. The second
    /// caller is deliberately typed as a no-op rather than issuing another
    /// resolve request whose post-resolution effect could run twice.
    @MainActor
    func resolveApprovalOnce(id: String, decision: String) async -> ApprovalsFacade.Resolution {
        do {
            return try await engine.approvals.resolveOnce(id: id) { id in
                try await resolveApproval(id: id, decision: decision)
            }
        } catch {
            return .unavailable(UserFacingError.cause(error, action: "update that approval"))
        }
    }

    @MainActor
    func isResolvingApproval(id: String) -> Bool {
        approvalResolutionInFlightIDs.contains(id)
    }

}
