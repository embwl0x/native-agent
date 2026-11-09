import Foundation
import ChatTurnContracts
import NativeAgentCore
// Blueprint: | `NativeAgentNotificationActions.swift` | `NativeAgentNotificationActions` |

public enum NativeAgentNotificationActions {
    public static let approvalCategory = "nativeagent.approval"
    public static let messageCategory = "nativeagent.message"
    public static let approve = "nativeagent.approve"
    public static let deny = "nativeagent.deny"
    public static let reply = "nativeagent.reply"
    public static let approvalKey = "approvalId"
    public static let sessionKey = "chatSessionId"
    public static let newConversationKey = "newNotificationConversation"

    public static func messageRoute(turn: Turn?) -> [String: String] {
        var route = turn?.verifiedSessionID.map { [sessionKey: $0] } ?? [newConversationKey: "true"]
        if let connection = turn?[FacePresentationPart.self] { route["faceRenderer"] = connection.uuidString }
        return route
    }

    public static func category(for userInfo: [String: String]) -> String {
        if let id = userInfo[approvalKey], !id.isEmpty { return approvalCategory }
        if let id = userInfo[sessionKey], !id.isEmpty { return messageCategory }
        if userInfo[newConversationKey] == "true" { return messageCategory }
        return ""
    }

    /// Copy only value data before crossing from the notification delegate.
    public struct Response: Sendable {
        public let action: String
        public let category: String
        public let approvalID: String?
        public let sessionID: String?
        public let newConversation: Bool
        public let deskHandle: String?
        public let pageRoute: String?
        public let text: String?
        public let title: String
        public let body: String
        public let renderer: String?
        public let route: [String: String]

        public init(
            action: String, category: String, userInfo: [AnyHashable: Any],
            text: String?, title: String, body: String
        ) {
            self.action = action
            self.category = category
            approvalID = userInfo[approvalKey] as? String
            sessionID = userInfo[sessionKey] as? String
            newConversation = userInfo[newConversationKey] as? String == "true"
            deskHandle = NativeAgentNotificationRoute.deskHandle(in: userInfo)
            pageRoute = userInfo[NativeAgentNotificationRoute.pageKey] as? String
            self.text = text
            self.title = title
            self.body = body
            renderer = userInfo["faceRenderer"] as? String
            route = userInfo.reduce(into: [:]) { result, pair in
                if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
            }
        }
    }
}
