import Foundation
import ApprovalInbox
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

/// App-owned projection of a chat approval into the canonical ApprovalInbox.
///
/// The inbox remains the authority and `NativeClient+ApprovalExecutors` remains
/// the sole post-resolution executor. This filer only preserves the initiating
/// conversation identity and returns immediately so Mac, detached, Slack, iOS,
/// and bridge-message turns never block while waiting for a person.
actor NativeAgentChatApprovalFiler: NonBlockingApprovalFiler {
    private let dataRoot: URL

    init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        let route = ChatToolSessionContext.replyRoute
        let origin: JSONValue = .object([
            "sessionId": Self.nonEmptyStringValue(ChatToolSessionContext.verifiedSessionId),
            "chatId": Self.nonEmptyStringValue(ChatToolSessionContext.verifiedChatId),
            "userId": Self.nonEmptyStringValue(ChatToolSessionContext.verifiedUserId),
            "destinationId": Self.nonEmptyStringValue(route?.destinationId),
            "threadId": Self.nonEmptyStringValue(route?.threadId),
            "sourceKey": Self.nonEmptyStringValue(route?.sourceKey),
            "replyTo": Self.nonEmptyStringValue(route?.replyTo),
            "correlationId": Self.nonEmptyStringValue(route?.correlationId),
        ])
        let record = try await SwiftNativeApprovalInbox(root: dataRoot).create(.object([
            "title": .string("Approve \(toolName)"),
            "action": .string(toolName),
            "risk": .string("confirm"),
            "reason": .string(reason),
            "payload": .object([
                "kind": .string("chat_tool_approval"),
                "toolName": .string(toolName),
                "surface": .string(surface),
                "input": payload,
                "origin": origin,
            ]),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
        ]))
        return record.id
    }

    func awaitResolution(id: String) async throws -> ApprovalDecision {
        _ = id
        throw NSError(
            domain: "NativeAgentChatApprovalFiler",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "This approval filer is nonblocking; resolved approvals execute through the canonical inbox."]
        )
    }

    func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async -> JSONValue {
        _ = payload
        return .object([
            "status": .string("waiting_approval"),
            "approvalId": .string(id),
            "tool": .string(toolName),
            "surface": .string(surface),
            "reason": .string(reason),
            "detail": .string("Approval is waiting in NativeAgent Activity → Approvals. The tool has not run."),
        ])
    }

    private static func nonEmptyStringValue(_ raw: String?) -> JSONValue {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return .null
        }
        return .string(value)
    }
}
