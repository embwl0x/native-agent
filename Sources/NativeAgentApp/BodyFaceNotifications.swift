import AppKit
import AttentionRouting
import EngineRuntime
import Foundation
import NativeAgentShared
import UserNotifications
// Blueprint: | `BodyFaceNotifications.swift` | Native notification effects retain their originating renderer and canonical body action owner |

@MainActor
func handleFaceNotification(_ response: NotificationResponse, model: AppModel, target: BodyFacePresentation) async throws {
    let native = NativeAgentNotificationActions.Response(action: response.action, category: response.category,
        userInfo: response.route, text: response.text, title: response.title, body: response.body)
    guard response.action != UNNotificationDismissActionIdentifier else { return }
    if response.action == UNNotificationDefaultActionIdentifier {
        let destination: FaceDestination
        if native.category == NativeAgentNotificationActions.approvalCategory {
            destination = .init(page: "inbox", item: nil, session: nil, message: nil)
        } else if let session = native.sessionID {
            try await target.present(.openConversation(session: session, message: nil))
            return
        } else if let handle = native.deskHandle {
            destination = .init(page: "desk", item: handle, session: nil, message: nil)
        } else if let route = native.pageRoute {
            let parts = route.split(separator: "/", maxSplits: 1).map(String.init)
            guard let page = parts.first else { throw FaceWireError.invalidFeedOrder }
            destination = .init(page: page, item: parts.dropFirst().first, session: nil, message: nil)
        } else {
            destination = .init(page: "chat", item: nil, session: nil, message: nil)
        }
        try await target.present(.navigate(.init(destination: destination, policy: .foreground)))
        return
    }
    var navigationFailure: String?
    try await model.engine.handleNotificationAction(native, showApprovals: {}, openConversation: { session in
        do { try await target.present(.openConversation(session: session, message: nil)) }
        catch { navigationFailure = error.localizedDescription }
    }, resolveApproval: { id, decision in
        do { try await target.present(.navigate(.init(destination: .init(page: "inbox", item: nil, session: nil, message: nil), policy: .foreground))) }
        catch { return error.localizedDescription }
        return await ApprovalDecisionAction.resolve(id: id, decision: decision, appModel: model)
    }, startChatTurn: { text, session in
        if let navigationFailure { return navigationFailure }
        do {
            let reply = try await target.act(.send(.init(session: session, text: text, attachments: [], composerRevision: 0,
                expectedSelection: nil, options: .init(hideUserBubble: false, choice: nil, continuationReference: nil))))
            switch reply {
            case .accepted: return nil
            case .refused(let issue), .failed(let issue): return issue.message
            default: return "The notification reply was not accepted."
            }
        } catch { return error.localizedDescription }
    })
}
