import Foundation
import PersistenceCore
import ApprovalInbox
import ChatOrchestration

/// Only the mounted local Desk command path supplies this filer. It is not
/// part of the tool registry or any remote request's selectable authority.
package struct DeskClickApprovalFiler: ApprovalFiler {
    let dataRoot: URL

    package init(dataRoot: URL) { self.dataRoot = dataRoot }

    package func fileApprovalRequest(
        toolName: String, surface: String, payload: JSONValue, reason: String
    ) async throws -> String {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let body: JSONValue = .object([
            "action": .string(toolName),
            "payload": payload,
            "reason": .string(reason + " — auto-approved: initiated by a local desk click"),
            "remoteResolvable": .bool(false),
        ])
        let record = try await inbox.create(body)
        _ = try await inbox.resolve(
            record.id, decision: .approved, decidedBy: "local_desk_click")
        return record.id
    }

    package func awaitResolution(id: String) async throws -> ApprovalDecision {
        let record = try await SwiftNativeApprovalInbox(root: dataRoot).get(id)
        guard record.status == "resolved",
              let rawDecision = record.decision,
              let decision = ApprovalDecision(rawValue: rawDecision) else {
            throw ApprovalInboxError.malformedResponse("Desk approval has no persisted resolution")
        }
        return decision
    }
}
