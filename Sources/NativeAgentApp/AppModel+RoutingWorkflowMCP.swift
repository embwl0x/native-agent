import Foundation
import NativeAgentShared
import EngineRuntime
import Research
import ApprovalInbox
// Blueprint: | `AppModel+RoutingWorkflowMCP.swift` | `ResearchSearchFailure`; `AppModel`: research `search`, `resolveApproval`, `resolveApprovalOnce` |

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


}
