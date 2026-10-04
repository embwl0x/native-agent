import Privacy
import Foundation
import AttentionRouting
import UserNotifications
import ApprovalInbox
import ApprovalTransactions
import NativeAgentCore
import PersistenceCore
import NotificationInbox

enum NativeAgentNotificationActions {
    static let approvalCategory = "nativeagent.approval"
    static let messageCategory = "nativeagent.message"
    static let approve = "nativeagent.approve"
    static let deny = "nativeagent.deny"
    static let reply = "nativeagent.reply"
    static let approvalKey = "approvalId"
    static let sessionKey = "chatSessionId"
    static let newConversationKey = "newNotificationConversation"

    static func register() {
        let options: UNNotificationActionOptions = [.foreground, .authenticationRequired]
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: approvalCategory, actions: [
                UNNotificationAction(identifier: approve, title: "Approve", options: options),
                UNNotificationAction(identifier: deny, title: "Deny", options: options.union(.destructive)),
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: messageCategory, actions: [
                UNTextInputNotificationAction(
                    identifier: reply, title: "Reply", options: options,
                    textInputButtonTitle: "Send", textInputPlaceholder: "Message"
                ),
            ], intentIdentifiers: [], options: []),
        ])
    }

    static func category(for userInfo: [String: String]) -> String {
        if let id = userInfo[approvalKey], !id.isEmpty { return approvalCategory }
        if let id = userInfo[sessionKey], !id.isEmpty { return messageCategory }
        if userInfo[newConversationKey] == "true" { return messageCategory }
        return ""
    }

    /// Copy only value data before crossing from the notification delegate.
    struct Response: Sendable {
        let action: String
        let category: String
        let approvalID: String?
        let sessionID: String?
        let newConversation: Bool
        let deskHandle: String?
        let text: String?
        let title: String
        let body: String

        init(_ response: UNNotificationResponse) {
            let content = response.notification.request.content
            action = response.actionIdentifier
            category = content.categoryIdentifier
            approvalID = content.userInfo[approvalKey] as? String
            sessionID = content.userInfo[sessionKey] as? String
            newConversation = content.userInfo[newConversationKey] as? String == "true"
            deskHandle = NativeAgentNotificationRoute.deskHandle(in: content.userInfo)
            text = (response as? UNTextInputNotificationResponse)?.userText
            title = content.title
            body = content.body
        }
    }

    @MainActor
    static func handle(_ response: Response) async {
        guard response.action != UNNotificationDismissActionIdentifier else { return }
        if response.action == UNNotificationDefaultActionIdentifier {
            if response.category == approvalCategory {
                _ = NativeAgentAppCoordinator.shared.request(.activity(.approvals))
            } else if let sessionID = response.sessionID {
                await openConversation(sessionID)
            } else if response.category == messageCategory {
                _ = NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
            } else if let handle = response.deskHandle {
                _ = NativeAgentAppCoordinator.shared.request(.sidebar(.desk))
                QuietSelfAdmin.shared.appModel?.pendingDeskHandle = handle
            }
            return
        }

        do {
            switch (response.category, response.action) {
            case (approvalCategory, approve), (approvalCategory, deny):
                guard let id = response.approvalID, !id.isEmpty,
                      let appModel = QuietSelfAdmin.shared.appModel else {
                    throw actionError("Approvals are not ready. Open NativeAgent to review the request.")
                }
                _ = NativeAgentAppCoordinator.shared.request(.activity(.approvals))
                // Never treat the delivered payload as authority. Re-read the
                // exact row and use the same executor and outcome UI as buttons.
                guard let record = try await appModel.engine.approvals.list().first(where: { $0.id == id }),
                      record.status == "pending" else {
                    throw actionError("This approval is no longer pending.")
                }
                guard ApprovalPayloadPreviewPresentation.canResolve(record) else {
                    throw actionError(ApprovalPayloadPreviewPresentation.unavailableText)
                }
                if let failure = await ApprovalDecisionAction.resolve(
                    id: id, decision: response.action == approve ? "approved" : "denied", appModel: appModel
                ) {
                    throw actionError(failure)
                }
            case (messageCategory, reply):
                guard let appModel = QuietSelfAdmin.shared.appModel,
                      let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    throw actionError("Chat is not ready or the reply is empty. Open NativeAgent to reply.")
                }
                let sessionID: String
                let turnText: String
                if response.newConversation {
                    sessionID = try await appModel.engine.transcripts.create(title: "Notification reply").id
                    turnText = """
                    I'm replying to this notification:
                    \(response.title)
                    \(response.body)

                    My reply: \(text)
                    """
                } else if let id = response.sessionID,
                          NativeAgentChatSessionID.normalizedPathComponent(id) == id {
                    sessionID = id
                    turnText = text
                } else {
                    throw actionError("The notification has no valid conversation.")
                }
                await openConversation(sessionID)
                // The composer owns admission, the busy-session queue, provider
                // routing, and Trust. A notification cannot start a second turn
                // over the one that is still sending its banner.
                let acceptance = await appModel.startChatTurnForSession(turnText, sessionId: sessionID)
                if case .rejected(let message) = acceptance {
                    throw actionError(message)
                }
            default:
                return
            }
        } catch {
            _ = NativeAgentAppCoordinator.shared.request(
                response.category == approvalCategory ? .activity(.approvals) : .sidebar(.chat)
            )
            QuietSelfAdmin.shared.appModel?.systemToasts.push(
                error: "Notification action failed: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private static func openConversation(_ sessionID: String) async {
        _ = NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        guard let appModel = QuietSelfAdmin.shared.appModel else { return }
        await appModel.refreshChatSessionIndex()
        if let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionID }) {
            await appModel.selectChatSession(session)
        }
    }

    private static func actionError(_ message: String) -> NSError {
        NSError(domain: "NativeAgentNotification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// App-lifetime observation of the same inbox the approval buttons read. The
/// initial read establishes a baseline, avoiding a burst of historical banners
/// at login. No polling, execution, or second approval store lives here.
@MainActor
enum NativeAgentApprovalNotifications {
    static func observe() async {
        async let approvals: Void = observeApprovals()
        async let interactions: Void = InteractionCardDelivery.observe()
        _ = await (approvals, interactions)
    }

    private static func observeApprovals() async {
        let approvals = NativeAgentEngine.live.approvals
        var seen: Set<String>?
        var startupPendingIDs: Set<String> = []
        // Cards whose transcript write failed: retried on later passes, a few times.
        var cardRetries: [String: Int] = [:]
        await ApprovalRequestsLiveRefresh.observe(approvals: approvals) {
            do {
                let rows = try await approvals.list()
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
                            "actions": .array(ApprovalPayloadPreviewPresentation.canResolve(row) ? [
                                .object(["id": .string("approve"), "label": .string("Approve")]),
                                .object(["id": .string("reject"), "label": .string("Deny")]),
                            ] : []),
                        ]), id: row.id)
                        filed = inserted || filed
                    } catch {
                        NSLog("[approval-notification] inbox delivery failed: %@", error.localizedDescription)
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
                    NSLog("[approval-notification] inbox retirement failed: %@", error.localizedDescription)
                    retired = 0
                }
                if filed || retired > 0 {
                    do {
                        let latest = try await NativeAgentEngine.live.inbox.list()
                        if NativeAgentEngine.live.inbox.items != latest {
                            NativeAgentEngine.live.inbox.items = latest
                        }
                    } catch {
                        NSLog("[approval-notification] inbox refresh failed: %@", error.localizedDescription)
                    }
                }
                guard let previous = seen else {
                    startupPendingIDs = pendingIDs
                    for row in rows where row.status == "pending" {
                        guard !Task.isCancelled else { return }
                        if await ApprovalChatCards.post(row, dataRoot: approvals.dataRoot,
                                telegram: TelegramApprovalFilerRef.shared.current(), quiet: true) == .failed {
                            cardRetries[row.id] = 1
                        }
                    }
                    seen = ids
                    // Finish interrupted card deliveries without replaying old banners.
                    var restored = false
                    for row in rows where row.status == "pending" && row.chatCard != nil && !row.chatCardDelivered {
                        guard !Task.isCancelled else { return }
                        let outcome = await ApprovalChatCards.post(row, dataRoot: approvals.dataRoot, quiet: true)
                        if outcome == .failed { cardRetries[row.id] = 1 }
                        if case .posted = outcome { restored = true }
                    }
                    if !pendingIDs.isEmpty || retired > 0 || restored {
                        Task { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }
                    }
                    return
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
                for row in rows where row.status == "pending" && previous.contains(row.id) {
                    guard let tries = cardRetries[row.id] else { continue }
                    let outcome = await ApprovalChatCards.post(row, dataRoot: approvals.dataRoot,
                        telegram: TelegramApprovalFilerRef.shared.current(),
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
                            telegram: TelegramApprovalFilerRef.shared.current(), quiet: wakeHeld) == .failed {
                        cardRetries[row.id] = 1
                    }
                    if wakeHeld {
                        await AttentionRouter.hold(dataRoot: approvals.dataRoot, title: title, body: body, ways: ["phone"],
                                                  approvalID: row.id)
                    } else {
                        do {
                            try await AttentionRouter.shared.route(
                                eventId: "approval:\(row.id)",
                                importance: .ownerWaiting,
                                title: title,
                                body: body,
                                userInfo: [
                                    "screen": "approvals",
                                    "source": "approval",
                                    NativeAgentNotificationActions.approvalKey: row.id,
                                ],
                                // Phone delivery accompanies the in-app card.
                                pinnedTo: .phone
                            )
                        } catch {
                            NSLog("[approval-notification] push failed: %@", error.localizedDescription)
                        }
                    }
                    guard !held, ApprovalPayloadPreviewPresentation.canResolve(row) else { continue }
                    let posted = await NativeAgentNotifications.postAndReport(
                        title: title,
                        body: body,
                        userInfo: [NativeAgentNotificationActions.approvalKey: row.id]
                    )
                    if !posted.posted {
                        NSLog("[approval-notification] banner failed: %@", posted.error ?? posted.delivery)
                    }
                }
                // Push first, snapshot after (User 09-28: everything instant): the
                // phone's own synced-approval notice then finds the push already
                // delivered under the same approvalId and stays quiet.
                if !pending.isEmpty || retired > 0 {
                    Task { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }
                }
                seen = ids
            } catch {
                NSLog("[approval-notification] inbox unavailable: %@", error.localizedDescription)
            }
        }
    }
}
