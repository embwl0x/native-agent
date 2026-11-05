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

/// Return without waiting for the person; the inbox owns authority and ApprovalExecution alone executes decisions.
public actor NativeAgentChatApprovalFiler: NonBlockingApprovalFiler {
    private let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String,
        turn: Turn
    ) async throws -> String {
        try await fileRequest(Self.requestPayload(toolName: toolName, surface: surface, payload: payload, turn: turn),
                              reason: reason, turn: turn).id
    }

    // The durable request owns redaction and authenticated identity on every surface.
    nonisolated static func requestPayload(toolName: String, surface: String, payload: JSONValue,
                                           turn: Turn, telegram: JSONValue? = nil) -> JSONValue {
        let payload = MacInjectionArgRedaction.redactedPayload(tool: toolName, payload: payload, turn: turn)
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        let route = envelope.replyRoute
        let origin: JSONValue = .object([
            "sessionId": Self.nonEmptyStringValue(turn.verifiedSessionID),
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
        request["peer"] = PeerDataTaint.carriedRecord(turn: turn, peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                                      peerID: envelope.verifiedUserId)
        request["fileAccess"] = turn.fileAccess.map(JSONValue.string) ?? .null
        request["hostCallID"] = turn.hostCallID.map { .string($0.uuidString) }
        request["telegram"] = telegram
        return .object(request)
    }

    func fileRequest(_ requestPayload: JSONValue, reason: String, turn: Turn) async throws -> ApprovalRecord {
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
            turn: turn, matchesPending: { payload in Self.isSameRequest(payload, requestPayload) }
        )
        return outcome.record
    }

    public static func peerRequesterName(surface: String, peerID: String?, dataRoot: URL) -> String? {
        guard PeerTurnEffectPolicy.isPeerBridge(surface: surface),
              let peerID, !peerID.isEmpty,
              let peer = try? AgentPeerStore(dataRoot: dataRoot).list()
                .first(where: { $0.id == peerID })
        else { return nil }
        let name = peer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Keep requester extraction aligned with the separator used to author card headings.
    public static let requesterTitleSeparator = " asked: "

    public static func approvalTitle(toolName: String, requester: String?) -> String {
        guard let requester, !requester.isEmpty else { return "Approve \(toolName)" }
        return "\(requester)\(requesterTitleSeparator)Approve \(toolName)"
    }

    public static func requester(inTitle title: String) -> String? {
        guard let range = title.range(of: requesterTitleSeparator) else { return nil }
        let who = title[title.startIndex..<range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return who.isEmpty ? nil : who
    }

    /// Tool, surface, arguments and reply route define identity so matching calls in different chats retain separate approvals.
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
            // Which answer asked is attribution, not identity: the same request from a later turn is the same pending card (and the card keeps its first
            // answer).
            && attributionFree(left["origin"]) == attributionFree(right["origin"])
            && left["peer"] == right["peer"]
            && left["hostCallID"] == right["hostCallID"]
            // Different file-access authority makes a distinct request, including cards without retained access.
            && left["fileAccess"] == right["fileAccess"]
    }

    public func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String,
        turn: Turn
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
