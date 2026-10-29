import AgentWorkspace
import Foundation
import NativeAgentShared
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Desk
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import MacIntegration
import ToolRegistry
// Blueprint: | `SwiftToolDispatcher+BuilderInbox.swift` | `SwiftToolDispatcher`: message-ID admission, locked deduplication, durable inbox append, quarantine evidence and explicit wake retries |

extension SwiftToolDispatcher {
    static func builderMessageId(input: [String: JSONValue]) -> String {
        guard case .string(let raw)? = input["message_id"] else { return UUID().uuidString }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? UUID().uuidString : String(value.prefix(160))
    }

    /// Deduplicate and append under one inbox lock; compare reviewer pairing when requested.
    /// Durable appends flush and close before returning; either failure throws.
    static func appendBuilderInboxMessage(
        _ messageId: String,
        entry: [String: JSONValue],
        to inboxURL: URL,
        queuedAt: String,
        comparePairReviewer: Bool,
        maxLines: Int,
        logLabel: String,
        quarantine: BuilderInboxQuarantineNote,
        durable: Bool = false
    ) async throws -> (status: String, retryWake: Bool, queuedAt: String) {
        try await SwiftNativePersistenceCore.withFileLock(inboxURL) {
            let existing = try await checkedBuilderInboxMessage(
                messageId, inboxURL: inboxURL, quarantine: quarantine
            )
            if case .object(let object)? = existing {
                let operationFields = ["text", "topic", "conversationId", "workingDirectory", "deskHandle", "origin"]
                guard operationFields.allSatisfy({ object[$0] == entry[$0] }),
                      (object["requireExistingConversation"] == .bool(true)) == (entry["requireExistingConversation"] == .bool(true)),
                      !comparePairReviewer || object["pairReviewer"] == entry["pairReviewer"] else {
                    return ("conflict", false, queuedAt)
                }
                if let session = stringField("sessionId", in: .object(object)), !session.isEmpty {
                    guard object["sessionId"] == entry["sessionId"],
                          object["priority"] == entry["priority"],
                          object["timeoutSeconds"] == entry["timeoutSeconds"] else {
                        return ("conflict", false, queuedAt)
                    }
                }
                // Flush an existing row before claiming a durable retry.
                if durable {
                    let handle = try FileHandle(forWritingTo: inboxURL)
                    defer { try? handle.close() }
                    try handle.synchronize()
                }
                return ("duplicate", builderInboxAllowsExplicitWakeRetry(object),
                        stringField("createdAt", in: .object(object)) ?? queuedAt)
            }
            try await appendJSONLCapped(
                .object(entry), to: inboxURL, maxLines: maxLines, logLabel: logLabel,
                // Amortize full-feed line checks with a byte trigger.
                trimWhenBytesExceed: 4 << 20,
                durable: durable
            )
            return ("appended", false, queuedAt)
        }
    }

    /// Carry only this send's quarantine evidence out of the @Sendable locked closure.
    final class BuilderInboxQuarantineNote: @unchecked Sendable {
        private let lock = NSLock()
        private var quarantinedPath: String?
        var path: String? { lock.withLock { quarantinedPath } }
        func record(_ path: String) { lock.withLock { quarantinedPath = path } }
    }

    static func checkedBuilderInboxMessage(
        _ messageId: String,
        inboxURL: URL,
        quarantine: BuilderInboxQuarantineNote
    ) async throws -> JSONValue? {
        let scan = try await SwiftNativePersistenceCore.readJSONLReporting(inboxURL)
        if !scan.report.isClean
            || !scan.rows.allSatisfy({ if case .object = $0 { return true }; return false }) {
            // Preserve damaged bytes and valid delivery identities; report the preserved path.
            let aside = try await quarantineBuilderInbox(
                inboxURL,
                report: scan.report,
                parsedRowCount: scan.rows.count
            )
            quarantine.record(aside.path)
        }
        let matching = scan.rows.filter { row in
            guard case .object(let object) = row else { return false }
            return object["messageId"] == .string(messageId) || object["id"] == .string(messageId)
        }
        guard matching.count <= 1 else {
            throw PersistenceCoreError.ioFailure("builder inbox message identity is ambiguous; original bytes preserved")
        }
        if case .object(let row)? = matching.first,
           let id = row["id"], let canonicalId = row["messageId"], id != canonicalId {
            throw PersistenceCoreError.ioFailure("builder inbox message identity conflicts; original bytes preserved")
        }
        return matching.first
    }

    /// Report possibly hidden admissions while valid rows retain their deduplication identities.
    static func stampBuilderInboxQuarantine(
        _ note: BuilderInboxQuarantineNote,
        on response: inout [String: JSONValue]
    ) {
        guard let aside = note.path else { return }
        response["inboxQuarantined"] = .object([
            "quarantinedPath": .string(aside),
            "note": .string("The inbox contained malformed rows. Its original bytes were preserved separately; valid rows remain queued and retain their message identities. An earlier admission may be in a damaged row; reconcile against the preserved file before assuming this was the first."),
        ])
    }

    /// Preserve original bytes, durably retain valid object rows, and propagate errors.
    private static func quarantineBuilderInbox(
        _ inboxURL: URL,
        report: JSONLReadReport,
        parsedRowCount: Int
    ) async throws -> URL {
        let fileManager = FileManager.default
        let stamp = String(Int(Date().timeIntervalSince1970))
        var aside = inboxURL.appendingPathExtension("quarantined-\(stamp)")
        var collision = 1
        while fileManager.fileExists(atPath: aside.path) {
            aside = inboxURL.appendingPathExtension("quarantined-\(stamp)-\(collision)")
            collision += 1
        }
        try fileManager.copyItem(at: inboxURL, to: aside)
        let original = try Data(contentsOf: aside)
        var retained = Data()
        for line in original.split(separator: 0x0A, omittingEmptySubsequences: false) {
            guard String(data: Data(line), encoding: .utf8) != nil,
                  let parsed = try? JSONValue.parse(Data(line)), case .object = parsed else { continue }
            retained.append(contentsOf: line)
            retained.append(0x0A)
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(retained, to: inboxURL)
        let receipt: [String: JSONValue] = [
            "event": .string("builder_inbox_quarantined"),
            "quarantinedAt": .string(NativeTimestampFormat.plainZulu(Date())),
            "inboxPath": .string(inboxURL.path),
            "quarantinedPath": .string(aside.path),
            "reason": .string("builder inbox is malformed; original bytes preserved"),
            "malformedLineCount": .int(Int64(report.malformedLineCount)),
            "trailingPartialLine": .bool(report.trailingPartialLine),
            "physicalLineCount": .int(Int64(report.physicalLineCount)),
            "parsedRowCount": .int(Int64(parsedRowCount)),
        ]
        // Quarantine audit failure does not invalidate the already-preserved bytes.
        try? await SwiftNativePersistenceCore.appendJSONLDurable(
            .object(receipt),
            to: inboxURL.deletingLastPathComponent()
                .appendingPathComponent("bridge-inbox-quarantine.jsonl")
        )
        return aside
    }

    static func builderInboxAllowsExplicitWakeRetry(
        _ row: [String: JSONValue]
    ) -> Bool {
        guard row["read"] == .bool(false),
              let createdAt = stringField("createdAt", in: .object(row)),
              !createdAt.isEmpty else { return false }
        guard let session = stringField("sessionId", in: .object(row)),
              !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch row["consumedAt"] {
        case nil, .null: return true
        case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }
}
