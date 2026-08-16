import Foundation
import ApprovalInbox
import NativeAgentCore
import PersistenceCore

public struct ExternalSendApprovalRequest: Sendable, Equatable {
    public static let approvalAction = "connector.external_send"
    public static let payloadKind = "external_send_v1"
    public static let maximumInputBytes = 131_072

    public let connectorID: String
    public let actionID: String
    public let invokedAs: String
    public let surface: String
    public let input: [String: JSONValue]
    public let idempotencyKey: String
    public let sessionID: String?
    public let remoteChatID: String?
    public let commandSignatureVerified: Bool

    public init?(record: ApprovalRecord) {
        guard record.action == Self.approvalAction,
              case .object(let payload) = record.payload,
              Self.string(payload["kind"]) == Self.payloadKind,
              let connectorID = Self.nonEmptyString(payload["connectorId"]),
              let actionID = Self.nonEmptyString(payload["actionId"]),
              let invokedAs = Self.nonEmptyString(payload["invokedAs"]),
              let surface = Self.nonEmptyString(payload["surface"]),
              case .object(let input)? = payload["input"],
              let idempotencyKey = Self.nonEmptyString(payload["idempotencyKey"]),
              idempotencyKey.utf8.count <= 128,
              Self.canonicalActionID(for: invokedAs) == actionID,
              Self.connectorID(for: actionID) == connectorID,
              let inputData = try? JSONValue.object(input).serializedData(pretty: false),
              inputData.count <= Self.maximumInputBytes else {
            return nil
        }
        let origin: [String: JSONValue]
        if case .object(let value)? = payload["origin"] {
            origin = value
        } else {
            origin = [:]
        }
        let telegram: [String: JSONValue]
        if case .object(let value)? = payload["telegram"] {
            telegram = value
        } else {
            telegram = [:]
        }
        self.connectorID = connectorID
        self.actionID = actionID
        self.invokedAs = invokedAs
        self.surface = surface
        self.input = input
        self.idempotencyKey = idempotencyKey
        self.sessionID = Self.nonEmptyString(origin["sessionId"])
            ?? Self.nonEmptyString(telegram["sessionId"])
        self.remoteChatID = Self.nonEmptyString(origin["chatId"])
            ?? Self.nonEmptyString(telegram["chatId"])
        if case .bool(let verified)? = origin["commandSignatureVerified"] {
            self.commandSignatureVerified = verified
        } else {
            self.commandSignatureVerified = false
        }
    }

    public static func canonicalActionID(for toolName: String) -> String? {
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "slack.post_message", "slack_post_message":
            return "slack.post_message"
        case "agentmail.send", "agentmail_send":
            return "agentmail.send"
        default:
            return nil
        }
    }

    public static func connectorID(for actionID: String) -> String? {
        switch actionID {
        case "slack.post_message": return "slack"
        case "agentmail.send": return "agentmail"
        default: return nil
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        return raw
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let raw = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }
}

public struct ExternalSendApprovalStagingResult: Sendable {
    public let approval: ApprovalRecord
    public let toolResult: JSONValue
}

struct ExternalSendPreparedInput: Sendable {
    let input: [String: JSONValue]
    let destinationCount: Int
    let contentByteCount: Int
}

public enum ExternalSendApprovalLifecycle {
    public static func stage(
        invokedAs: String,
        input: [String: JSONValue],
        surface: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> ExternalSendApprovalStagingResult {
        guard let actionID = ExternalSendApprovalRequest.canonicalActionID(for: invokedAs),
              let connectorID = ExternalSendApprovalRequest.connectorID(for: actionID) else {
            throw ExternalSendApprovalError.unsupportedAction(invokedAs)
        }
        let prepared: ExternalSendPreparedInput
        switch actionID {
        case "slack.post_message":
            prepared = try prepareSlackInput(input)
        case "agentmail.send":
            prepared = try AgentMailActions.prepareSendApprovalInput(input, dataRoot: dataRoot)
        default:
            throw ExternalSendApprovalError.unsupportedAction(invokedAs)
        }
        let privateInput = JSONValue.object(prepared.input)
        let privateInputData = try privateInput.serializedData(pretty: false)
        guard privateInputData.count <= ExternalSendApprovalRequest.maximumInputBytes else {
            throw ExternalSendApprovalError.inputTooLarge(
                actual: privateInputData.count,
                maximum: ExternalSendApprovalRequest.maximumInputBytes
            )
        }

        let idempotencyKey: String
        if let suppliedIdempotencyKey {
            let trimmed = suppliedIdempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else {
                throw ExternalSendApprovalError.invalidIdempotencyKey
            }
            idempotencyKey = trimmed
        } else {
            idempotencyKey = UUID().uuidString.lowercased()
        }

        let sessionID = nonEmpty(ChatToolSessionContext.verifiedSessionId)
        let chatID = nonEmpty(ChatToolSessionContext.verifiedChatId)
        var payload: [String: JSONValue] = [
            "kind": .string(ExternalSendApprovalRequest.payloadKind),
            "connectorId": .string(connectorID),
            "actionId": .string(actionID),
            "invokedAs": .string(invokedAs),
            "surface": .string(surface),
            "input": privateInput,
            "idempotencyKey": .string(idempotencyKey),
            "origin": .object([
                "sessionId": sessionID.map(JSONValue.string) ?? .null,
                "chatId": chatID.map(JSONValue.string) ?? .null,
                "commandSignatureVerified": .bool(ChatToolSessionContext.commandSignatureVerified == true),
            ]),
        ]
        if chatID != nil || sessionID != nil {
            payload["telegram"] = .object([
                "chatId": chatID.map(JSONValue.string) ?? .null,
                "sessionId": sessionID.map(JSONValue.string) ?? .null,
            ])
        }

        let connectorLabel = connectorID == "slack" ? "Slack" : "AgentMail"
        let approval = try await SwiftNativeApprovalInbox(root: dataRoot).create(.object([
            "title": .string("Approve external send via \(connectorLabel)"),
            "action": .string(ExternalSendApprovalRequest.approvalAction),
            "risk": .string("high"),
            "reason": .string("An external message will be sent only after this exact request is approved."),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
            "payloadPreview": .string(
                "\(connectorLabel) external send; \(prepared.destinationCount) destination(s); "
                    + "\(prepared.contentByteCount) content bytes. Message content is private."
            ),
            "payload": .object(payload),
        ]))
        return ExternalSendApprovalStagingResult(
            approval: approval,
            toolResult: .object([
                "status": .string("pending_approval"),
                "actionId": .string(actionID),
                "connectorId": .string(connectorID),
                "approvalId": .string(approval.id),
                "approval_id": .string(approval.id),
                "risk": .string("high"),
                "message": .string("External send queued for approval."),
            ])
        )
    }

    public static func stageToolResult(
        invokedAs: String,
        input: [String: JSONValue],
        surface: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> JSONValue {
        do {
            return try await stage(
                invokedAs: invokedAs,
                input: input,
                surface: surface,
                dataRoot: dataRoot
            ).toolResult
        } catch {
            let errorCode = (error as? AgentMailError)?.message ?? "approval_staging_failed"
            return .object([
                "status": .string("failed"),
                "actionId": .string(
                    ExternalSendApprovalRequest.canonicalActionID(for: invokedAs) ?? invokedAs
                ),
                "error": .string(errorCode),
                "detail": .string(error.localizedDescription),
            ])
        }
    }

    private static func prepareSlackInput(_ input: [String: JSONValue]) throws -> ExternalSendPreparedInput {
        let channel = string(input["channel"] ?? input["channel_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = string(input["text"] ?? input["message"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !channel.isEmpty else { throw ExternalSendApprovalError.missingInput("channel") }
        guard !text.isEmpty else { throw ExternalSendApprovalError.missingInput("text") }
        guard channel.utf8.count <= 512 else {
            throw ExternalSendApprovalError.fieldTooLarge("channel", maximumBytes: 512)
        }
        guard text.utf8.count <= 40_000 else {
            throw ExternalSendApprovalError.fieldTooLarge("text", maximumBytes: 40_000)
        }
        var normalized: [String: JSONValue] = [
            "channel": .string(channel),
            "text": .string(text),
        ]
        if let thread = nonEmpty(string(input["thread_ts"] ?? input["threadTs"])) {
            guard thread.utf8.count <= 128 else {
                throw ExternalSendApprovalError.fieldTooLarge("thread_ts", maximumBytes: 128)
            }
            normalized["thread_ts"] = .string(thread)
        }
        return ExternalSendPreparedInput(
            input: normalized,
            destinationCount: 1,
            contentByteCount: text.utf8.count
        )
    }

    private static func string(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let raw)?: return raw
        case .int(let raw)?: return String(raw)
        case .double(let raw)?: return String(raw)
        case .bool(let raw)?: return raw ? "true" : "false"
        default: return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum ExternalSendApprovalError: LocalizedError {
    case unsupportedAction(String)
    case missingInput(String)
    case fieldTooLarge(String, maximumBytes: Int)
    case inputTooLarge(actual: Int, maximum: Int)
    case invalidIdempotencyKey

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let action):
            return "Unsupported external send action: \(action)"
        case .missingInput(let field):
            return "External send requires \(field)."
        case .fieldTooLarge(let field, let maximumBytes):
            return "External send field \(field) exceeds \(maximumBytes) bytes."
        case .inputTooLarge(let actual, let maximum):
            return "External send replay input is \(actual) bytes; maximum is \(maximum)."
        case .invalidIdempotencyKey:
            return "External send idempotency key must contain 1 to 128 UTF-8 bytes."
        }
    }
}
