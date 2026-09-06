import Foundation
import ApprovalInbox
import ChatOrchestration
import MacControl
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
        // W2/W3-FIX 4 (defense in depth): redact secret-bearing injection
        // arguments HERE too, not only in AutonomyGatedDispatcher. This record
        // is `remoteResolvable` — it syncs to iOS and is echoed into chat — so
        // the boundary that writes it owns its own redaction rather than
        // trusting every present and future caller to have redacted first.
        let payload = MacInjectionArgRedaction.redactedPayload(tool: toolName, payload: payload)
        // Route and identity come from the TURN ENVELOPE, never from the
        // individual task-locals. An approval outlives the turn that filed it:
        // when a human resolves it minutes later, the only way back to the
        // person who asked is what was written down here. An adapter that binds
        // an envelope and no legacy task-locals — which is exactly what the
        // "how to add a surface" contract tells a new adapter to do — used to
        // file an approval with a null route and null identity, so its reply
        // had nowhere to go. `TurnEnvelope.current(surface:)` composes from the
        // task-locals when no envelope is bound, so the pre-envelope surfaces
        // are unchanged.
        let envelope = TurnEnvelope.current(surface: surface)
        let route = envelope.replyRoute
        let origin: JSONValue = .object([
            "sessionId": Self.nonEmptyStringValue(ChatToolSessionContext.verifiedSessionId),
            "chatId": Self.nonEmptyStringValue(envelope.verifiedChatId),
            "userId": Self.nonEmptyStringValue(envelope.verifiedUserId),
            "surface": Self.nonEmptyStringValue(route.surface),
            "destinationId": Self.nonEmptyStringValue(route.destinationId),
            "threadId": Self.nonEmptyStringValue(route.threadId),
            "sourceKey": Self.nonEmptyStringValue(route.sourceKey),
            "replyTo": Self.nonEmptyStringValue(route.replyTo),
            "correlationId": Self.nonEmptyStringValue(route.correlationId),
        ])
        let requestPayload: JSONValue = .object([
            "kind": .string("chat_tool_approval"),
            "toolName": .string(toolName),
            "surface": .string(surface),
            "input": payload,
            "origin": origin,
        ])
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        // User, 2026-09-06: the SAME request, still pending, gets the SAME id.
        // Every invocation used to mint a fresh approval, so a model that
        // re-asked for one CONFIRM piled up identical rows for the person to
        // resolve and handed the tool loop a different `approvalId` each round —
        // which is exactly what the no-progress guard compares, so the loop it
        // exists to stop was invisible to it.
        //
        // User, 2026-09-06: the match and the create are ONE locked inbox
        // operation. Listing and then creating released the file lock in
        // between, so two turns asking at once (or one re-asking while the
        // first write was still in flight) both found no match and both filed
        // a row. The reused row also gets its `lastRequestedAt` stamped, so a
        // chat card that fences on the turn it belongs to can still show a
        // question re-raised in a later turn — the reused row's `createdAt`
        // belongs to the turn that first asked, and that fence used to hide it.
        let outcome = try await inbox.createOrTouchPending(
            .object([
                "title": .string("Approve \(toolName)"),
                "action": .string(toolName),
                "risk": .string("confirm"),
                "reason": .string(reason),
                "payload": requestPayload,
                "remoteResolvable": .bool(true),
                "localOnly": .bool(false),
            ]),
            matchesPending: { payload in Self.isSameRequest(payload, requestPayload) }
        )
        return outcome.record.id
    }

    /// Two chat-tool approvals are the same REQUEST when the tool, the surface,
    /// the arguments and the initiating conversation all match. `origin` carries
    /// the reply route, which is part of the identity: the same call from two
    /// chats must stay two approvals.
    private static func isSameRequest(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        guard case .object(let left) = lhs, case .object(let right) = rhs,
              left["kind"] == .string("chat_tool_approval") else { return false }
        return left["kind"] == right["kind"]
            && left["toolName"] == right["toolName"]
            && left["surface"] == right["surface"]
            && left["input"] == right["input"]
            && left["origin"] == right["origin"]
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
