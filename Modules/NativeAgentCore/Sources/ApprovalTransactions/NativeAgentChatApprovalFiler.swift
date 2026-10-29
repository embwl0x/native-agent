import AuthoredCapabilities
import Foundation
import ApprovalInbox
import ChatTurnContracts
import AgentConversations
import TrustCenter
import MacControl
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeAgentChatApprovalFiler.swift` | `NativeAgentChatApprovalFiler` actor; `fileApprovalRequest`, `peerRequesterName` |

/// App-owned projection of a chat approval into the canonical ApprovalInbox.
///
/// The inbox remains the authority and `ApprovalExecution` remains
/// the sole post-resolution executor. This filer only preserves the initiating
/// conversation identity and returns immediately so Mac, detached, Slack, iOS,
/// and bridge turns never block while waiting for a person.
public actor NativeAgentChatApprovalFiler: NonBlockingApprovalFiler {
    private let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        try await fileRequest(Self.requestPayload(toolName: toolName, surface: surface, payload: payload),
                              reason: reason).id
    }

    // The durable request owns redaction and authenticated identity on every surface.
    nonisolated static func requestPayload(toolName: String, surface: String, payload: JSONValue,
                                           telegram: JSONValue? = nil) -> JSONValue {
        let payload = MacInjectionArgRedaction.redactedPayload(tool: toolName, payload: payload)
        let envelope = TurnEnvelope.current(surface: surface)
        let route = envelope.replyRoute
        let origin: JSONValue = .object([
            "sessionId": Self.nonEmptyStringValue(ChatToolSessionContext.verifiedSessionId),
            "chatId": Self.nonEmptyStringValue(envelope.verifiedChatId),
            "userId": Self.nonEmptyStringValue(envelope.verifiedUserId),
            "agent": Self.nonEmptyStringValue(envelope.agent),
            "declaredRemote": envelope.declaredRemote.map(JSONValue.bool) ?? .null,
            "surface": Self.nonEmptyStringValue(route.surface),
            "destinationId": Self.nonEmptyStringValue(route.destinationId),
            "threadId": Self.nonEmptyStringValue(route.threadId),
            "sourceKey": Self.nonEmptyStringValue(route.sourceKey),
            "replyTo": Self.nonEmptyStringValue(route.replyTo),
            "correlationId": Self.nonEmptyStringValue(route.correlationId),
            "answerExperienceID": Self.nonEmptyStringValue(envelope.answerExperienceID),
        ])
        var request: [String: JSONValue] = [
            "kind": .string("chat_tool_approval"),
            "toolName": .string(toolName),
            "surface": .string(surface),
            "input": payload,
            "origin": origin,
        ]
        if toolName == "agent_message", AgentConversationApproval.exactProtocol {
            request["agentExactProtocol"] = .bool(true)
        }
        request["peer"] = PeerDataTaint.carriedRecord(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                                      peerID: envelope.verifiedUserId)
        request["fileAccess"] = ChatToolSessionContext.fileAccess.map(JSONValue.string) ?? .null
        request["hostCallID"] = SkillRunContext.hostCallID.map { .string($0.uuidString) }
        request["telegram"] = telegram
        return .object(request)
    }

    func fileRequest(_ requestPayload: JSONValue, reason: String) async throws -> ApprovalRecord {
        guard case .object(let request) = requestPayload,
              case .string(let toolName)? = request["toolName"],
              case .string(let surface)? = request["surface"],
              case .object(let origin)? = request["origin"] else { preconditionFailure("Invalid chat approval request") }
        let preview = try JSONValue.object(request.filter { $0.key != "hostCallID" }).serialize(pretty: false)
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        // Matching and touching are one locked operation, retaining the first request's attribution.
        let outcome = try await inbox.createOrTouchPending(
            .object([
                "title": .string(Self.approvalTitle(
                    toolName: toolName,
                    requester: Self.peerRequesterName(
                        surface: surface,
                        peerID: origin["userId"]?.stringValue,
                        dataRoot: dataRoot
                    )
                )),
                "action": .string(toolName),
                "risk": .string("confirm"),
                "reason": .string(reason),
                "payload": requestPayload,
                "payloadPreview": .string(preview),
                "remoteResolvable": .bool(true),
                "localOnly": .bool(false),
            ]),
            matchesPending: { payload in Self.isSameRequest(payload, requestPayload) }
        )
        return outcome.record
    }

    /// The connected agent's name, when a known peer asked.
    public static func peerRequesterName(surface: String, peerID: String?, dataRoot: URL) -> String? {
        guard PeerTurnEffectPolicy.isPeerBridge(surface: surface),
              let peerID, !peerID.isEmpty,
              let peer = try? AgentPeerStore(dataRoot: dataRoot).list()
                .first(where: { $0.id == peerID })
        else { return nil }
        let name = peer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The separator that lets a reader take the requester back out of a
    /// title — the in-chat card reads it to name the peer in its own heading.
    public static let requesterTitleSeparator = " asked: "

    public static func approvalTitle(toolName: String, requester: String?) -> String {
        guard let requester, !requester.isEmpty else { return "Approve \(toolName)" }
        return "\(requester)\(requesterTitleSeparator)Approve \(toolName)"
    }

    /// The requester a title carries, or nil for the person's own approvals.
    public static func requester(inTitle title: String) -> String? {
        guard let range = title.range(of: requesterTitleSeparator) else { return nil }
        let who = title[title.startIndex..<range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return who.isEmpty ? nil : who
    }

    /// Two chat-tool approvals are the same REQUEST when the tool, the surface,
    /// the arguments and the initiating conversation all match. `origin` carries
    /// the reply route, which is part of the identity: the same call from two
    /// chats must stay two approvals.
    private static func attributionFree(_ origin: JSONValue?) -> JSONValue? {
        guard case .object(var fields)? = origin else { return origin }
        fields["answerExperienceID"] = nil
        return .object(fields)
    }

    nonisolated static func isSameRequest(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        guard case .object(let left) = lhs, case .object(let right) = rhs,
              left["kind"] == .string("chat_tool_approval") else { return false }
        return left["kind"] == right["kind"]
            && left["toolName"] == right["toolName"]
            && left["surface"] == right["surface"]
            && left["input"] == right["input"]
            && left["telegram"] == right["telegram"]
            && left["agentExactProtocol"] == right["agentExactProtocol"]
            // Which answer asked is attribution, not identity: the same request from a
            // later turn is the same pending card (and the card keeps its first answer).
            && attributionFree(left["origin"]) == attributionFree(right["origin"])
            && left["peer"] == right["peer"]
            && left["hostCallID"] == right["hostCallID"]
            // A card filed with other hands is another request (an old card has none).
            && left["fileAccess"] == right["fileAccess"]
    }

    public func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async -> JSONValue {
        _ = payload
        return ToolNotRunStatus.approvalFiled.reporting(.object([
            "status": .string("waiting_approval"),
            "approvalId": .string(id),
            "tool": .string(toolName),
            "surface": .string(surface),
            "reason": .string(reason),
        ]))
    }

    private static func nonEmptyStringValue(_ raw: String?) -> JSONValue {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return .null
        }
        return .string(value)
    }
}
