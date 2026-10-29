import Cognition
import EngineRuntime
import ApprovalTransactions
import Foundation
import NativeAgentShared
import AttentionRouting
import UserNotifications
import AppKit
// Blueprint: | `NativeAgentNotificationActions.swift` | Native response mapping, shared category registration and mounted window/conversation dispatch; effects stay in EngineNotificationActions |

extension NativeAgentNotificationActions.Response {
    init(_ response: UNNotificationResponse) {
        let content = response.notification.request.content
        self.init(
            action: response.actionIdentifier, category: content.categoryIdentifier,
            userInfo: content.userInfo,
            text: (response as? UNTextInputNotificationResponse)?.userText,
            title: content.title, body: content.body
        )
    }
}

extension NativeAgentNotificationActions {
    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(nativeAgentNotificationCategories(
            approvalCategory: approvalCategory, messageCategory: messageCategory,
            approve: approve, deny: deny, reply: reply, replyPlaceholder: "Message"
        ))
    }

    @MainActor
    static func handle(_ response: Response) async {
        guard response.action != UNNotificationDismissActionIdentifier else { return }
        if response.action == UNNotificationDefaultActionIdentifier {
            if response.category == approvalCategory {
                _ = ApplicationLifetime.shared.request(.activity(.approvals))
            } else if let sessionID = response.sessionID {
                await openConversation(sessionID)
            } else if response.category == messageCategory {
                _ = ApplicationLifetime.shared.request(.sidebar(.chat))
            } else if let handle = response.deskHandle {
                _ = ApplicationLifetime.shared.request(.sidebar(.desk))
                ApplicationLifetime.shared.appModel?.pendingDeskHandle = handle
            } else if let pageRoute = response.pageRoute {
                let parts = pageRoute.split(separator: "/", maxSplits: 1).map(String.init)
                if let page = parts.first,
                   case .sidebar(let item) = NativeAgentNavigationDestination.route(page) {
                    SettingsLink.open(item, tab: parts.count > 1 ? parts[1] : nil)
                }
            }
            return
        }

        do {
            guard let appModel = ApplicationLifetime.shared.appModel else {
                switch (response.category, response.action) {
                case (approvalCategory, approve), (approvalCategory, deny):
                    throw actionError("Approvals are not ready. Open NativeAgent to review the request.")
                case (messageCategory, reply):
                    throw actionError("Chat is not ready or the reply is empty. Open NativeAgent to reply.")
                default:
                    return
                }
            }
            try await appModel.engine.handleNotificationAction(
                response,
                showApprovals: { _ = ApplicationLifetime.shared.request(.activity(.approvals)) },
                openConversation: { await openConversation($0) },
                resolveApproval: { id, decision in
                    await ApprovalDecisionAction.resolve(id: id, decision: decision, appModel: appModel)
                },
                startChatTurn: { text, sessionID in
                    let acceptance = await appModel.startChatTurnForSession(text, sessionId: sessionID)
                    if case .rejected(let message) = acceptance { return message }
                    return nil
                }
            )
        } catch {
            _ = ApplicationLifetime.shared.request(
                response.category == approvalCategory ? .activity(.approvals) : .sidebar(.chat)
            )
            ApplicationLifetime.shared.appModel?.systemToasts.push(
                error: UserFacingError.message(error, action: "do that from the notification")
            )
        }
    }

    /// Opens the conversation; with `messageID`, lands on that message.
    @MainActor
    static func openConversation(_ sessionID: String, messageID: String? = nil) async {
        _ = ApplicationLifetime.shared.request(.sidebar(.chat))
        guard let appModel = ApplicationLifetime.shared.appModel else { return }
        await appModel.refreshChatSessionIndex()
        if let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionID }) {
            await appModel.selectChatSession(session)
            appModel.pendingChatMessageID = messageID
        }
    }

    private static func actionError(_ message: String) -> NSError {
        NSError(domain: "NativeAgentNotification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// App-lifetime observation of the same inbox the approval buttons read. The
/// initial read establishes a baseline for Mac banners. AttentionRouter owns
/// phone acceptance independently of discovery.
@MainActor
enum NativeAgentApprovalNotifications {
    static func observe() async {
        await observeApprovals()
    }

    private static func observeApprovals() async {
        let engine = NativeAgentEngine.live
        let approvals = engine.approvals
        let delivery = ApprovalNotificationDelivery(engine: engine)
        let approvalPath = await approvals.requestsPath()
        await EventDeadlinePhysiology.refreshOnChanges(paths: [approvalPath] + [
            "config/apns.json", "notifications/push_tokens.json", "mobile_push/tokens.json", "user_prefs.json"
        ].map { approvals.dataRoot.appendingPathComponent($0) },
            notifications: [NSApplication.didBecomeActiveNotification, .NSSystemClockDidChange, UserDefaults.didChangeNotification]) {
            await delivery.refresh(
                router: .shared,
                telegram: { ApprovalChatCards.runningTelegram },
                post: { title, body, userInfo in
                    await NativeAgentNotifications.postAndReport(title: title, body: body, userInfo: userInfo)
                },
                writeSnapshots: { Task { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() } }
            )
        }
    }
}
