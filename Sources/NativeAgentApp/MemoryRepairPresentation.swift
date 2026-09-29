import Foundation
import MemoryV2
import PersistenceCore
import NotificationInbox

struct AppMemoryRepairPresentation: MemoryRepairPresentationPort {
    /// Card id == approval id (InboxView routes approve/reject through
    /// inboxAction(id) → resolveApproval(id)). Idempotent whole-file scan
    /// before append, inside the same flock critical section — the same
    /// shape as ensureREMProposalInboxCard.
    func ensureInboxCard(
        dataRoot: URL, approvalId: String, title: String,
        summary: String, detail: String, relatedPath: String
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(fmt.string(from: Date())),
            "source": .string("memory_repair"),
            "severity": .string("actionable"),
            "title": .string(title),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .string(approvalId),
            "related_paths": .array([.string(relatedPath)]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Apply this repair (store backed up first)")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Leave the store untouched")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let inserted = try await LiveNotificationInbox(path: inboxPath)
            .appendUnique(card, id: approvalId)
        if inserted {
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: approvalId,
                title: title,
                summary: summary,
                source: "memory_repair",
                severity: "actionable"
            )
        }
    }

}
