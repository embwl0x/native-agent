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
// Blueprint: | `SwiftToolDispatcher+BuilderInbox.swift` | `SwiftToolDispatcher`: message-ID admission, locked deduplication, mandatory durable inbox append; damaged feeds stay byte-preserved and refuse admission as uncertain before any wake |

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
        admissionNote: BuilderInboxAdmissionNote
    ) async throws -> (status: String, retryWake: Bool, queuedAt: String) {
        try await SwiftNativePersistenceCore.withFileLock(inboxURL) {
            let existing = try await checkedBuilderInboxMessage(
                messageId, inboxURL: inboxURL, admissionNote: admissionNote
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
                let handle = try FileHandle(forWritingTo: inboxURL)
                do {
                    try handle.synchronize()
                } catch {
                    try? handle.close()
                    throw error
                }
                try handle.close()
                return ("duplicate", builderInboxAllowsExplicitWakeRetry(object),
                        stringField("createdAt", in: .object(object)) ?? queuedAt)
            }
            try await appendJSONLCapped(
                .object(entry), to: inboxURL, maxLines: maxLines, logLabel: logLabel,
                // Amortize full-feed line checks with a byte trigger.
                trimWhenBytesExceed: 4 << 20,
                durable: true
            )
            return ("appended", false, queuedAt)
        }
    }

    /// Carry this send's unavailable evidence out of the locked closure.
    final class BuilderInboxAdmissionNote: @unchecked Sendable {
        private let lock = NSLock()
        private var unavailablePath: String?
        var path: String? { lock.withLock { unavailablePath } }
        func record(_ path: String) { lock.withLock { unavailablePath = path } }
    }

    static func checkedBuilderInboxMessage(
        _ messageId: String,
        inboxURL: URL,
        admissionNote: BuilderInboxAdmissionNote
    ) async throws -> JSONValue? {
        let scan = try await SwiftNativePersistenceCore.readJSONLReporting(inboxURL)
        if !scan.report.isClean
            || !scan.rows.allSatisfy({ if case .object = $0 { return true }; return false }) {
            // The canonical feed is the evidence, including any hidden prior
            // admission. Never filter it or admit another send over its gaps.
            admissionNote.record(inboxURL.path)
            throw ToolFailureError("The builder inbox is damaged. A prior admission may be hidden in its unreadable rows; no new message was admitted and no wake started. Original bytes remain untouched.",
                effects: .unknown, owner: inboxURL.path, code: "prior_admission_uncertain",
                instruction: "Reconcile the original inbox with retained message and execution evidence before sending again.", recovery: .reconcile)
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

    /// This read did not establish whether a prior admission exists.
    static func stampBuilderInboxUncertainty(
        _ note: BuilderInboxAdmissionNote,
        on response: inout [String: JSONValue]
    ) {
        guard let preserved = note.path else { return }
        response["status"] = .string("uncertain")
        response["outcome"] = .string("unsettled")
        response["reason"] = .string("prior_admission_uncertain")
        response["inboxUnavailable"] = .object([
            "preservedPath": .string(preserved),
            "note": .string("Original inbox bytes remain untouched. A prior admission may be hidden in damaged rows. No new message was admitted and no wake started; reconcile this feed before another send."),
        ])
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
