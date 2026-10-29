import Foundation
import NativeAgentShared
import ApprovalInbox
import ApprovalTransactions
import AttentionRouting
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import Privacy
import TelegramBot
// Blueprint: | `EngineApprovalNotifications.swift` | `ApprovalNotificationDelivery`: approval discovery, pending-state selection and notification delivery coordination |

/// Approval discovery state belongs to the engine; the app supplies native
/// observation events and transport effects.
@MainActor
public final class ApprovalNotificationDelivery {
    private let engine: NativeAgentEngine
    private var seen: Set<String>?
    private var startupPendingIDs: Set<String> = []
    private var cardRetries: [String: Int] = [:]

    public init(engine: NativeAgentEngine) {
        self.engine = engine
    }

    public func refresh(
        router: AttentionRouter,
        telegram: () -> TelegramApprovalFiler?,
        post: (_ title: String, _ body: String, _ userInfo: [String: String]) async -> NativeAgentNotificationPostResult,
        writeSnapshots: () -> Void
    ) async {
        let approvals = engine.approvals
        do {
            // Her own decisions (her canon) get no note, button or ping.
            let rows = try await approvals.list().filter { !$0.isAgentsOwnDecision }
            let ids = Set(rows.map(\.id))
            let pendingIDs = Set(rows.filter { $0.status == "pending" }.map(\.id))
            let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: approvals.dataRoot))
            var filed = false
            for row in rows where row.status == "pending" {
                do {
                    let inserted = try await inbox.appendUnique(.object([
                        "id": .string(row.id), "source": .string("approval"),
                        "created_at": .string(row.createdAt), "status": .string("unread"),
                        "severity": .string("actionable"), "related_approval_id": .string(row.id),
                        "title": .string(NativeAppSecretRedactor.redactText(row.title)),
                        "summary": .string(NativeAppSecretRedactor.redactText(row.reason)),
                        "detail": .string(NativeAppSecretRedactor.redactText(row.payloadPreview)),
                        "actions": .array(ApprovalChatCards.canResolve(row) ? [
                            .object(["id": .string("approve"), "label": .string("Approve")]),
                            .object(["id": .string("reject"), "label": .string("Deny")]),
                        ] : []),
                    ]), id: row.id)
                    filed = inserted || filed
                } catch {
                    nativeLog("[approval-notification] inbox delivery failed: %@", error.localizedDescription)
                }
            }
            let retired: Int
            do {
                let resolvedIDs = try await inbox.rows().compactMap { value -> String? in
                    guard let item = InboxItemRecord(row: value), item.source == "approval",
                          !pendingIDs.contains(item.id) else { return nil }
                    return item.id
                }
                retired = try await inbox.archiveActive(
                    ids: resolvedIDs,
                    readAt: ISO8601DateFormatter().string(from: Date()),
                    metadata: ["actions": .array([])]
                )
            } catch {
                nativeLog("[approval-notification] inbox retirement failed: %@", error.localizedDescription)
                retired = 0
            }
            if filed || retired > 0 {
                do {
                    _ = try await engine.inbox.list()
                } catch {
                    nativeLog("[approval-notification] inbox refresh failed: %@", error.localizedDescription)
                }
            }
            let previous = seen ?? ids
            if seen == nil {
                startupPendingIDs = pendingIDs
                for row in rows where row.status == "pending" {
                    guard !Task.isCancelled else { return }
                    if await ApprovalChatCards.post(row, dataRoot: approvals.dataRoot,
                            telegram: telegram(), quiet: true) == .failed {
                        cardRetries[row.id] = 1
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let pending = rows.filter { $0.status == "pending" && !previous.contains($0.id) }
            guard !Task.isCancelled else { return }
            // Share the existing quiet-hours policy. Suppressed requests
            // remain visible in Approvals; no timer replays them later.
            let held = AttentionRouter.holdsMacBanner(.ownerWaiting, dataRoot: approvals.dataRoot)
            func filedIn(_ row: ApprovalRecord) -> String? {
                if case .object(let payload) = row.payload, case .object(let origin)? = payload["origin"],
                   case .string(let session)? = origin["sessionId"] { return session }
                return nil
            }
            for row in rows where seen != nil && row.status == "pending" && previous.contains(row.id) {
                guard let tries = cardRetries[row.id] else { continue }
                let outcome = await ApprovalChatCards.post(row, dataRoot: approvals.dataRoot,
                    telegram: telegram(),
                    quiet: startupPendingIDs.contains(row.id)
                        || AttentionRouter.holdsResidentWake(session: filedIn(row) ?? "", dataRoot: approvals.dataRoot))
                cardRetries[row.id] = outcome == .failed && tries < 3 ? tries + 1 : nil
            }
            for row in pending {
                let title = NativeAppSecretRedactor.redactText(row.title)
                // The one human line; the raw payload is for Details, not a push.
                let body = NativeAppSecretRedactor.redactText(row.reason)
                // Filed by her resident wake in his quiet hours: the push
                // waits in the inbox for them to end (releaseHeld).
                let wakeHeld = AttentionRouter.holdsResidentWake(session: filedIn(row) ?? "", dataRoot: approvals.dataRoot)
                // User, 10-03: and its card pops up in his conversation —
                // before the snapshot below, so the phone draws it there too.
                if await ApprovalChatCards.post(row, dataRoot: approvals.dataRoot,
                        telegram: telegram(), quiet: wakeHeld) == .failed {
                    cardRetries[row.id] = 1
                }
                guard !held, ApprovalChatCards.canResolve(row) else { continue }
                let posted = await post(
                    title,
                    body,
                    [NativeAgentNotificationActions.approvalKey: row.id]
                )
                if !posted.posted {
                    nativeLog("[approval-notification] banner failed: %@", posted.error ?? posted.delivery)
                }
            }
            // Re-read after card awaits. Attention's ledger suppresses
            // accepted sends; failures retry on owner or recovery events.
            let notificationRows = try await inbox.rows()
            for row in try await approvals.list() where row.status == "pending" && !row.isAgentsOwnDecision {
                guard !Task.isCancelled else { return }
                let eventID = "approval:\(row.id)"
                let alreadyHeld = notificationRows.contains {
                    guard case .object(let card) = $0, case .array(let ways)? = card["held_delivery"] else { return false }
                    return card["approval_id"] == .string(row.id) && ways.contains(.string("phone"))
                }
                if alreadyHeld { continue }
                let title = NativeAppSecretRedactor.redactText(row.title)
                let body = NativeAppSecretRedactor.redactText(row.reason)
                if AttentionRouter.holdsResidentWake(session: filedIn(row) ?? "", dataRoot: approvals.dataRoot) {
                    try await LiveNotificationInbox.hold(dataRoot: approvals.dataRoot, title: title, body: body, ways: ["phone"], approvalID: row.id)
                } else {
                    do {
                        try await router.route(
                            eventId: eventID, importance: .ownerWaiting, title: title, body: body,
                            reason: eventID,
                            userInfo: ["screen": "approvals", "source": "approval", NativeAgentNotificationActions.approvalKey: row.id]
                        )
                    } catch {
                        nativeLog("[approval-notification] push failed: %@", error.localizedDescription)
                    }
                }
            }
            // Push first, snapshot after (User 09-28: everything instant): the
            // phone's own synced-approval notice then finds the push already
            // delivered under the same approvalId and stays quiet.
            if (seen == nil && !pendingIDs.isEmpty) || !pending.isEmpty || retired > 0 {
                writeSnapshots()
            }
            seen = ids
        } catch {
            nativeLog("[approval-notification] inbox unavailable: %@", error.localizedDescription)
        }
    }
}
