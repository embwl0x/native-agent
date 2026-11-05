import Foundation
import ApprovalInbox
import ApprovalTransactions
import NativeAgentCore
import Experiences
// Blueprint: | `EngineApprovalNotifications.swift` | Approval observation delivers conversation cards; ForPerson owns the inbox reading and owed doors |

@MainActor
public final class ApprovalNotificationDelivery {
    private let engine: NativeAgentEngine

    public init(engine: NativeAgentEngine) { self.engine = engine }

    public func refresh(writeSnapshots: () -> Void) async {
        do {
            _ = try await ForPerson.at(engine.dataRoot).matters()
            for row in try await engine.approvals.list() where row.status == "pending" && !row.isAgentsOwnDecision {
                guard !Task.isCancelled else { return }
                await ApprovalChatCards.post(row, dataRoot: engine.approvals.dataRoot)
            }
            guard !Task.isCancelled else { return }
            writeSnapshots()
        } catch { nativeLog("[approval-notification] approvals unavailable: %@", error.localizedDescription) }
    }
}
