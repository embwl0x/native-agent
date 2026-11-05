import Foundation
import Experiences
import NativeAgentShared
import PersistenceCore
// Blueprint: | `iCloudBridge+DeliveryReceipts.swift` | Signed phone receipts accept their matter's phone obligation at arrival; transport evidence journal |

extension iCloudBridge {
    /// Both transports share durable receipts; ephemeral phone presentation must never enter this journal.
    @discardableResult
    nonisolated static func appendChatDeliveryReceipt(
        _ message: BridgeMessage,
        direction: String,
        transport: String,
        status: ChatDeliveryReceiptStatus,
        secret: Data,
        dataRoot: URL,
        detail: String? = nil
    ) async -> Bool {
        if direction == "mac_to_ios",
           let kind = message.metadata?["kind"],
           ["text_delta", "progress", "notice", "tool_use", "tool_result"].contains(kind) {
            return true
        }
        var fields: [String: JSONValue] = [
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "messageId": .string(message.id),
            "correlationId": message.correlationID.map { .string($0) } ?? .null,
            "sessionId": message.sessionID.map { .string($0) } ?? .null,
            "sender": .string(message.sender),
            "direction": .string(direction),
            "transport": .string(transport),
            "status": .string(status.rawValue),
            "deliveryConfirmed": .bool(status.deliveryConfirmed),
            "signatureVerified": .bool(message.verifySignature(secret: secret)),
            "kind": message.metadata?["kind"].map { .string($0) } ?? .string("reply"),
            "targetSourceKey": message.metadata?["targetSourceKey"].map { .string($0) } ?? .null,
            "textPreview": .string(String(message.text.prefix(240))),
            "attachmentCount": .int(Int64(message.attachments?.count ?? 0)),
            "assistantRunId": message.metadata?["assistantRunId"].map(JSONValue.string) ?? message.correlationID.map(JSONValue.string) ?? .null,
        ]
        if let eventID = message.metadata?["userInfo.eventId"] ?? message.metadata?["eventId"] {
            fields["eventId"] = .string(eventID)
        }
        if let run = message.metadata?["canonicalAnswerRunId"] { fields["canonicalAnswerRunId"] = .string(run) }
        if let session = message.metadata?["canonicalAnswerSessionId"] { fields["canonicalAnswerSessionId"] = .string(session) }
        if let detail { fields["outcomeDetail"] = .string(detail) }
        return (try? await upsertChatDeliveryReceipt(
            appendRow: .object(fields),
            dataRoot: dataRoot
        )) == true
    }

    static func appendActionResponseDeliveryReceipt(
        response: [String: String],
        correlationID: String,
        transport: String,
        status: ChatDeliveryReceiptStatus,
        dataRoot: URL
    ) async -> Bool {
        let preview = String((response["message"] ?? response["status"] ?? "").prefix(240))
        let row: JSONValue = .object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "messageId": response["msgId"].map { .string($0) } ?? .null,
            "correlationId": .string(correlationID),
            "sessionId": .null,
            "sender": .string("mac"),
            "direction": .string("mac_to_ios"),
            "transport": .string(transport),
            "status": .string(status.rawValue),
            "deliveryConfirmed": .bool(status.deliveryConfirmed),
            "signatureVerified": .bool(true),
            "kind": .string("icloud_action_response"),
            "targetSourceKey": .null,
            "textPreview": .string(preview),
            "attachmentCount": .int(0),
        ])
        return (try? await upsertChatDeliveryReceipt(appendRow: row, dataRoot: dataRoot)) == true
    }

    static func appendInboundSuccessReceipt(
        _ message: BridgeMessage,
        transport: String,
        secret: Data,
        dataRoot: URL
    ) async -> Bool {
        return await appendChatDeliveryReceipt(
            message,
            direction: "ios_to_mac",
            transport: transport,
            status: .deliveredToMac,
            secret: secret,
            dataRoot: dataRoot
        )
    }

    static func appendInboundActionSuccessReceipt(
        messageID: String,
        action: String,
        transport: String,
        dataRoot: URL
    ) async -> Bool {
        let row: JSONValue = .object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "messageId": .string(messageID),
            "correlationId": .string(messageID),
            "sessionId": .null,
            "sender": .string("ios"),
            "direction": .string("ios_to_mac"),
            "transport": .string(transport),
            "status": .string(ChatDeliveryReceiptStatus.deliveredToMac.rawValue),
            "deliveryConfirmed": .bool(true),
            "signatureVerified": .bool(true),
            "kind": .string("icloud_action"),
            "targetSourceKey": .null,
            "textPreview": .string(String(action.prefix(240))),
            "attachmentCount": .int(0),
        ])
        return (try? await upsertChatDeliveryReceipt(appendRow: row, dataRoot: dataRoot)) == true
    }

    @discardableResult
    static func confirmChatDeliveryReceipt(
        direction: String,
        eventID: String,
        channel: String,
        dataRoot: URL
    ) async -> Bool {
        let cleanDirection = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanDirection == "mac_to_ios" || cleanDirection == "ios_to_mac" else {
            return false
        }
        let cleanEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEventID.isEmpty else {
            return false
        }
        let cleanChannel = String(channel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let confirmedAt = ISO8601DateFormatter().string(from: Date())
        let receipt: JSONValue = .object([
            "at": .string(confirmedAt),
            "messageId": .null,
            "correlationId": .null,
            "sessionId": .null,
            "sender": .string(cleanDirection == "mac_to_ios" ? "mac" : "ios"),
            "direction": .string(cleanDirection),
            "transport": .string("notification_receipt"),
            "status": .string(ChatDeliveryReceiptStatus.confirmedByPeer.rawValue),
            "deliveryConfirmed": .bool(true),
            "signatureVerified": .bool(true),
            "kind": .string("notification"),
            "targetSourceKey": .null,
            "textPreview": .string(""),
            "attachmentCount": .int(0),
            "eventId": .string(cleanEventID),
            "confirmedAt": .string(confirmedAt),
            "confirmationChannel": .string(cleanChannel),
        ])
        do {
            let saved = try await upsertChatDeliveryReceipt(
                appendRow: receipt,
                match: ChatDeliveryReceiptMatch(
                    direction: cleanDirection,
                    eventID: cleanEventID
                ),
                updateFields: [
                    "direction": .string(cleanDirection),
                    "deliveryConfirmed": .bool(true),
                    "status": .string(ChatDeliveryReceiptStatus.confirmedByPeer.rawValue),
                    "eventId": .string(cleanEventID),
                    "confirmedAt": .string(confirmedAt),
                    "confirmationChannel": .string(cleanChannel),
                    "kind": .string("notification"),
                    "signatureVerified": .bool(true),
                ],
                dataRoot: dataRoot
            )
            // A receipt names the phone's canonical event; a chat reply's receipt has no matter and settles nothing here.
            if saved, cleanDirection == "mac_to_ios", let matter = try await ForPerson.at(dataRoot).matter(phoneEvent: cleanEventID) {
                try await ForPerson.at(dataRoot).accepted(matter.id, .phone,
                    evidence: .init(source: "icloud/chat_delivery_receipts.jsonl", id: cleanEventID))
            }
            return saved
        } catch {
            nativeLog("Phone notification receipt %@ remains unsettled: %@", cleanEventID, error.localizedDescription)
            return false
        }
    }

    nonisolated static func chatDeliveryReceiptsURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("icloud", isDirectory: true)
            .appendingPathComponent("chat_delivery_receipts.jsonl")
    }

    private struct ChatDeliveryReceiptMatch: Sendable {
        let direction: String
        let eventID: String

        func matches(_ fields: [String: JSONValue]) -> Bool {
            fields["direction"]?.stringValue == direction && fields["eventId"]?.stringValue == eventID
        }
    }

    @discardableResult
    private static func upsertChatDeliveryReceipt(
        appendRow: JSONValue,
        match: ChatDeliveryReceiptMatch? = nil,
        updateFields: [String: JSONValue]? = nil,
        dataRoot: URL
    ) async throws -> Bool {
        let path = chatDeliveryReceiptsURL(dataRoot: dataRoot)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let existing = try loadChatDeliveryReceiptRows(path: path)
            var rows = existing
            var matchedIndex: Int?
            if case .object(let fields) = appendRow, let id = fields["messageId"]?.stringValue {
                matchedIndex = rows.firstIndex { $0["messageId"]?.stringValue == id && $0["direction"] == fields["direction"] }
            }
            if let match {
                for index in rows.indices.reversed() {
                    if match.matches(rows[index]) {
                        matchedIndex = index
                        break
                    }
                }
            }
            if let matchedIndex, let updateFields {
                var merged = rows[matchedIndex]
                for (key, value) in updateFields {
                    merged[key] = value
                }
                rows[matchedIndex] = merged
            } else if case .object(let fields) = appendRow {
                if let matchedIndex {
                    let accepted = ["accepted_by_transport", "confirmed_by_peer", "delivered_to_mac"]
                    if !accepted.contains(rows[matchedIndex]["status"]?.stringValue ?? "") || fields["status"] == .string("confirmed_by_peer") {
                        rows[matchedIndex].merge(fields, uniquingKeysWith: { _, new in new })
                    }
                } else { rows.append(fields) }
            } else {
                return false
            }
            try saveChatDeliveryReceiptRows(rows, path: path)
            return true
        }
    }

    /// Delivery evidence is never discarded to repair a malformed journal.
    nonisolated static func loadChatDeliveryReceiptRows(path: URL) throws -> [[String: JSONValue]] {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        guard let text = String(data: data, encoding: .utf8), data.isEmpty || data.last == 0x0A else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return try lines.map { line in
            guard case .object(let fields) = try JSONValue.parse(Data(line.utf8)),
                  case .string(let status)? = fields["status"], ChatDeliveryReceiptStatus(rawValue: status) != nil,
                  case .string(let direction)? = fields["direction"], ["mac_to_ios", "ios_to_mac"].contains(direction),
                  case .string? = fields["kind"] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if fields["direction"] == .string("mac_to_ios"),
               isRetainedChatReply(kind: fields["kind"]?.stringValue, canonicalRun: fields["canonicalAnswerRunId"]?.stringValue) {
                guard status != "delivered_to_mac",
                      case .string(let correlation)? = fields["correlationId"], !correlation.isEmpty,
                      case .string(let identity) = fields["assistantRunId"] ?? fields["correlationId"] ?? .null,
                      !identity.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            }
            return fields
        }
    }

    nonisolated private static func saveChatDeliveryReceiptRows(_ rows: [[String: JSONValue]], path: URL) throws {
        let data = try SwiftNativePersistenceCore.serializeJSONL(rows.map(JSONValue.object))
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
    }
}
