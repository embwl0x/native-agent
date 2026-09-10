import Foundation
import NativeAgentShared
import PersistenceCore

extension iCloudBridge {
    /// The durable receipt seam for both CloudKit and Drive sends. Keeping the
    /// row construction and capped append here lets evaluations exercise the
    /// exact persisted evidence without opening a live transport.
    nonisolated static func appendChatDeliveryReceipt(
        _ message: BridgeMessage,
        direction: String,
        transport: String,
        status: ChatDeliveryReceiptStatus,
        secret: Data,
        dataRoot: URL
    ) async {
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
        ]
        if let eventID = message.metadata?["userInfo.eventId"] ?? message.metadata?["eventId"] {
            fields["eventId"] = .string(eventID)
        }
        _ = try? await upsertChatDeliveryReceipt(
            appendRow: .object(fields),
            dataRoot: dataRoot
        )
    }

    static func appendActionResponseDeliveryReceipt(
        response: [String: String],
        correlationID: String,
        transport: String,
        status: ChatDeliveryReceiptStatus,
        dataRoot: URL
    ) async {
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
        _ = try? await upsertChatDeliveryReceipt(appendRow: row, dataRoot: dataRoot)
    }

    static func appendInboundSuccessReceipt(
        _ message: BridgeMessage,
        transport: String,
        secret: Data,
        dataRoot: URL
    ) async {
        await appendChatDeliveryReceipt(
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
    ) async {
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
        _ = try? await upsertChatDeliveryReceipt(appendRow: row, dataRoot: dataRoot)
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
        guard NativeAgentDeviceEventIdentity.isCanonical(cleanEventID) else {
            return false
        }
        let cleanChannel = String(channel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let confirmedAt = ISO8601DateFormatter().string(from: Date())
        let fallback: JSONValue = .object([
            "at": .string(confirmedAt),
            "messageId": .null,
            "correlationId": .null,
            "sessionId": .null,
            "sender": .string(cleanDirection == "mac_to_ios" ? "mac" : "ios"),
            "direction": .string(cleanDirection),
            "transport": .string("notification_receipt"),
            "status": .string(ChatDeliveryReceiptStatus.confirmedByPeer.rawValue),
            "deliveryConfirmed": .bool(true),
            "signatureVerified": .bool(cleanDirection == "ios_to_mac"),
            "kind": .string("notification"),
            "targetSourceKey": .null,
            "textPreview": .string(""),
            "attachmentCount": .int(0),
            "eventId": .string(cleanEventID),
            "confirmedAt": .string(confirmedAt),
            "confirmationChannel": .string(cleanChannel),
        ])
        do {
            return try await upsertChatDeliveryReceipt(
                appendRow: fallback,
                match: ChatDeliveryReceiptMatch(
                    direction: cleanDirection,
                    eventID: cleanEventID,
                    correlationID: nil,
                    kind: nil
                ),
                updateFields: [
                    "direction": .string(cleanDirection),
                    "deliveryConfirmed": .bool(true),
                    "status": .string(ChatDeliveryReceiptStatus.confirmedByPeer.rawValue),
                    "eventId": .string(cleanEventID),
                    "confirmedAt": .string(confirmedAt),
                    "confirmationChannel": .string(cleanChannel),
                    "kind": .string("notification"),
                ],
                dataRoot: dataRoot
            )
        } catch {
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
        let eventID: String?
        let correlationID: String?
        let kind: String?

        func matches(_ fields: [String: JSONValue]) -> Bool {
            guard stringField(fields["direction"]) == direction else { return false }
            if let eventID, stringField(fields["eventId"]) != eventID { return false }
            if let correlationID, stringField(fields["correlationId"]) != correlationID { return false }
            if let kind, stringField(fields["kind"]) != kind { return false }
            return true
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
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(path) {
            let existing = try loadChatDeliveryReceiptRows(path: path)
            var rows = existing
            var matchedIndex: Int?
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
                rows.append(fields)
            } else {
                return false
            }
            if rows.count > 500 {
                rows = Array(rows.suffix(500))
            }
            try saveChatDeliveryReceiptRows(rows, path: path)
            // 2026-09-07: true means "durably persisted", whether by updating a
            // matched row or appending the first one; the caller reports false as
            // receipt_persistence_failed, which a successful append is not.
            return true
        }
    }

    /// Tolerant, self-healing load. This store was appended non-atomically for
    /// most of its life, so a torn last line can already exist on disk at
    /// upgrade time. Throwing on it made `upsertChatDeliveryReceipt` fail
    /// forever — every append swallows the error with `try?`, and
    /// `confirmChatDeliveryReceipt` then answers false permanently, so the
    /// phone's `recordNotificationReceipt` fails with
    /// `receipt_persistence_failed` and never recovers. Skip the unparseable
    /// lines instead, but never drop the bytes silently: the damaged original
    /// is renamed aside as `.stale-<ts>` before the rebuilt store is written.
    nonisolated private struct DamagedReceiptStoreNotPreserved: Error {}

    nonisolated private static func loadChatDeliveryReceiptRows(path: URL) throws -> [[String: JSONValue]] {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            // 2026-09-07 (Agent): a present-but-unreadable store is not an empty
            // one; returning [] here would let the rewrite overwrite it.
            throw error
        }
        guard let text = String(data: data, encoding: .utf8) else {
            // Not even UTF-8 — the whole file is unreadable. Preserve it aside
            // rather than letting the atomic rewrite overwrite the evidence.
            guard quarantineDamagedChatDeliveryReceipts(path: path, reason: "file is not valid UTF-8") else {
                throw DamagedReceiptStoreNotPreserved()
            }
            return []
        }
        var rows: [[String: JSONValue]] = []
        var damagedLines = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard
                let parsed = try? JSONValue.parse(Data(raw.utf8)),
                case .object(let object) = parsed
            else {
                damagedLines += 1
                continue
            }
            rows.append(object)
        }
        if damagedLines > 0 {
            // 2026-09-07: if the damaged bytes cannot be preserved aside, the
            // rebuilt store must not overwrite them; the caller fails instead.
            guard quarantineDamagedChatDeliveryReceipts(
                path: path,
                reason: "\(damagedLines) unparseable row(s)"
            ) else {
                throw DamagedReceiptStoreNotPreserved()
            }
        }
        return rows
    }

    /// Rename the damaged store aside instead of deleting it. The caller
    /// rewrites `path` from the rows it could parse, so the quarantined copy is
    /// the only remaining record of the bytes that were dropped.
    @discardableResult
    nonisolated private static func quarantineDamagedChatDeliveryReceipts(path: URL, reason: String) -> Bool {
        let fm = FileManager.default
        var destination = path.appendingPathExtension("stale-\(Int(Date().timeIntervalSince1970))")
        if fm.fileExists(atPath: destination.path) {
            destination = destination.appendingPathExtension(UUID().uuidString.prefix(8).lowercased())
        }
        do {
            try fm.moveItem(at: path, to: destination)
            NSLog(
                "[iCloudBridge] chat delivery receipts self-healed (%@); damaged store preserved at %@",
                reason,
                destination.lastPathComponent
            )
            return true
        } catch {
            NSLog(
                "[iCloudBridge] chat delivery receipts damaged (%@) but could not be preserved aside: %@",
                reason,
                error.localizedDescription
            )
            return false
        }
    }

    nonisolated private static func saveChatDeliveryReceiptRows(_ rows: [[String: JSONValue]], path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let serialized = try rows.map { try JSONValue.object($0).serialize(pretty: false) }
            .joined(separator: "\n")
        let data = Data((serialized.isEmpty ? "" : serialized + "\n").utf8)
        try data.write(to: path, options: .atomic)
    }

    nonisolated private static func stringField(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

}
