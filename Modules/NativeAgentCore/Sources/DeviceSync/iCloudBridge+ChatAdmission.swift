import Foundation
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import ProviderRouting
import OSLog
import Network
// Blueprint: | `iCloudBridge+ChatAdmission.swift` | One durable ledger for admission, Stop, signed reply retention and settlement. |

extension iCloudBridge {
    enum ChatAdmission: Sendable {
        case reserved
        case completed, interrupted, cancelled, unreadable, collision, stale, unavailable
    }

    /// Admission fields are absent on Mac-originated reply obligations; both share the same ledger schema.
    struct ChatRecord: Codable, Sendable {
        var id: String?
        var direction: String
        var action: String
        var state: String
        var createdAt: String?
        var updatedAt: String?
        var attempts: Int?
        var lastError: String?
        var response: [String: String]?
        var msgId: String
        var actionDigest: String?
        var assistantSessionId: String?
        var resendRunId: String?
        var resendSessionId: String?
        var targetSourceKey: String?
        var stopRequestedSessionId: String?
        var replyPublicationId: String?
        /// Exact signed publication bytes survive an ambiguous upload or receipt failure.
        var outboundMessage: BridgeMessage?
        var hasAdmission: Bool { id != nil && createdAt != nil && updatedAt != nil && attempts != nil }
    }

    nonisolated static func chatURL(_ messageID: String, dataRoot: URL) -> URL {
        let id = MacSyncSnapshotIntegrity.digest(Data(messageID.utf8))
        return dataRoot.appendingPathComponent("icloud/chat_transactions/\(id).json")
    }

    nonisolated static func readChat(_ messageID: String, dataRoot: URL) throws -> ChatRecord {
        try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: chatURL(messageID, dataRoot: dataRoot)))
    }

    @discardableResult
    nonisolated private static func writeChat(_ record: ChatRecord, to path: URL) throws -> Data {
        let data = try JSONEncoder().encode(record)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
        return data
    }

    /// Stop-only rows must survive transport delay and restart; nonterminal stops are ineligible for retention pruning.
    nonisolated static func recordChatStop(session: String, runID: String, dataRoot: URL) async throws {
        let path = chatURL(runID, dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var row: ChatRecord
            switch MacSyncEngine.coordinatedReadOutcome(at: path) {
            case .missing:
                row = ChatRecord(direction: "ios_to_mac", action: "chat", state: "stop_requested", msgId: runID)
            case .data(let data): row = try JSONDecoder().decode(ChatRecord.self, from: data)
            case .failed: throw CocoaError(.fileReadUnknown)
            }
            guard row.msgId == runID, row.action == "chat",
                  row.stopRequestedSessionId == nil || row.stopRequestedSessionId == session else {
                throw CocoaError(.fileReadCorruptFile)
            }
            row.stopRequestedSessionId = session
            try writeChat(row, to: path)
        }
    }

    nonisolated static func chatStopRequested(session: String, runID: String, dataRoot: URL) throws -> Bool {
        switch MacSyncEngine.coordinatedReadOutcome(at: chatURL(runID, dataRoot: dataRoot)) {
        case .missing: return false
        case .failed: throw CocoaError(.fileReadUnknown)
        case .data(let data):
            let row = try JSONDecoder().decode(ChatRecord.self, from: data)
            guard row.msgId == runID, row.action == "chat" else { throw CocoaError(.fileReadCorruptFile) }
            return row.stopRequestedSessionId == session
        }
    }

    /// Reserve the authenticated CloudKit envelope before a turn starts.
    nonisolated static func reserveChat(_ message: BridgeMessage, dataRoot: URL, canDispatch: Bool) async -> ChatAdmission {
        do {
            let digest = MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning())
            let id = MacSyncSnapshotIntegrity.digest(Data(message.id.utf8))
            let url = Self.chatURL(message.id, dataRoot: dataRoot)
            return try await SwiftNativePersistenceCore.withFileLock(url) {
                let age = Date().timeIntervalSince(message.timestamp)
                let inWindow = age <= 24 * 60 * 60 && age >= -15 * 60
                var stopSession: String?
                switch MacSyncEngine.coordinatedReadOutcome(at: url) {
                case .data(let data):
                    guard var row = try? JSONDecoder().decode(ChatRecord.self, from: data) else { return .unreadable }
                    if !row.hasAdmission {
                        guard row.msgId == message.id, row.direction == "ios_to_mac", row.action == "chat",
                              row.state == "stop_requested", let session = row.stopRequestedSessionId else { return .unreadable }
                        guard session == message.sessionID else { return .collision }
                        stopSession = session
                        break
                    }
                    guard row.id == id, row.msgId == message.id, row.actionDigest == digest,
                          row.direction == "ios_to_mac", row.action == "chat" else { return .collision }
                    if ["completed", "failed_before_answer"].contains(row.state) { return .completed }
                    if let stop = row.stopRequestedSessionId, stop == (row.assistantSessionId ?? message.sessionID) { return .cancelled }
                    // Older reservations said running before the forwarder had bound the session.
                    // Both versions bind the session before starting work.
                    if row.state == "running", row.assistantSessionId == nil {
                        guard inWindow else { return .stale }
                        // A message older than this data root's life is another life's, readmitted or not.
                        if message.timestamp < (try DataRootLife.began(in: dataRoot)) { return .completed }
                        guard canDispatch else { return .unavailable }
                        row.state = "reserved"
                        row.updatedAt = NativeTimestampFormat.plainZulu(Date())
                        try writeChat(row, to: url)
                    }
                    if row.state == "reserved" {
                        guard inWindow else { return .stale }
                        return canDispatch ? .reserved : .unavailable
                    }
                    return .interrupted
                case .failed:
                    return .unreadable
                case .missing:
                    break
                }
                // Pre-life messages are history owned by another install or restore, never new turns.
                if message.timestamp < (try DataRootLife.began(in: dataRoot)) { return .completed }
                guard inWindow else { return .stale }
                guard canDispatch else { return .unavailable }
                let now = ISO8601DateFormatter().string(from: Date())
                let row = ChatRecord(id: id, direction: "ios_to_mac", action: "chat",
                                                 state: "reserved", createdAt: now, updatedAt: now,
                                                 attempts: 1, msgId: message.id, actionDigest: digest,
                                                 stopRequestedSessionId: stopSession)
                let data = try Self.writeChat(row, to: url)
                guard case .data(let retained) = MacSyncEngine.coordinatedReadOutcome(at: url),
                      retained == data else { return .unavailable }
                return stopSession == nil ? .reserved : .cancelled
            }
        } catch {
            nativeLog("[iCloudBridge] chat reservation unavailable: %@", error.localizedDescription)
            return .unavailable
        }
    }

    /// The forwarder claims execution after preflight, just before handing work to its owner.
    nonisolated static func beginChat(_ message: BridgeMessage, sessionID: String, dataRoot: URL) async throws {
        let url = chatURL(message.id, dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(url) {
            try Task.checkCancellation()
            var row = try readChat(message.id, dataRoot: dataRoot)
            guard row.state == "reserved", row.assistantSessionId == sessionID,
                  row.actionDigest == MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning()) else {
                throw DeviceSyncError.conflict
            }
            if row.stopRequestedSessionId == sessionID { throw CancellationError() }
            row.state = "running"
            row.updatedAt = NativeTimestampFormat.plainZulu(Date())
            try writeChat(row, to: url)
        }
    }

    nonisolated static func finishChat(_ message: BridgeMessage, dataRoot: URL) async -> Bool {
        return await settle {
            do {
                let url = Self.chatURL(message.id, dataRoot: dataRoot)
                return try await SwiftNativePersistenceCore.withFileLock(url) {
                    var row = try Self.readChat(message.id, dataRoot: dataRoot)
                    guard row.hasAdmission, row.msgId == message.id,
                          row.actionDigest == MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning()) else { return false }
                    if row.state == "completed" { return true }
                    row.state = "completed"
                    row.updatedAt = ISO8601DateFormatter().string(from: Date())
                    try Self.writeChat(row, to: url)
                    return true
                }
            } catch {
                nativeLog("[iCloudBridge] chat outcome could not be saved: %@", error.localizedDescription)
                return false
            }
        }
    }

    nonisolated static func bindReplySession(_ message: BridgeMessage, sessionID: String, dataRoot: URL,
                                            resendRunID: String? = nil, resendSessionID: String? = nil) async throws {
        let path = chatURL(message.id, dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var row = try readChat(message.id, dataRoot: dataRoot)
            guard row.msgId == message.id,
                  row.actionDigest == MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning()),
                  row.assistantSessionId == nil || row.assistantSessionId == sessionID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            row.assistantSessionId = sessionID
            if let resendRunID { row.resendRunId = resendRunID }
            if let resendSessionID { row.resendSessionId = resendSessionID }
            try writeChat(row, to: path)
        }
    }

    /// Recover the exact signed bytes named by the owning transaction (or its existing legacy receipt).
    nonisolated static func retainedReplyPublication(id: String, correlationID: String, dataRoot: URL) throws -> BridgeMessage? {
        let row: ChatRecord
        do {
            row = try readChat(id, dataRoot: dataRoot)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let secret = try PairingSecret.requireExistingSecret()
        guard row.action == "chat", row.direction == "mac_to_ios", row.msgId == id,
              let saved = row.outboundMessage, saved.id == id, saved.correlationID == correlationID,
              saved.verifySignature(secret: secret) else { throw CocoaError(.fileReadCorruptFile) }
        return saved
    }

    nonisolated static func matchesReplyPublication(_ message: BridgeMessage, correlationID: String, runID: String) -> Bool {
        let metadata = message.metadata
        return message.correlationID == correlationID
            && isRetainedChatReply(kind: metadata?["kind"], canonicalRun: metadata?["canonicalAnswerRunId"])
            && ((metadata?["assistantRunId"] ?? message.correlationID) == runID
                || metadata?["kind"] == "codex_completion" && metadata?["assistantRunId"] == correlationID)
    }

    /// Before links were written, a reply could be retained under a random ID without a receipt.
    nonisolated static func unlinkedReplyPublication(correlationID: String, runID: String, dataRoot: URL) throws -> BridgeMessage? {
        let directory = chatURL(correlationID, dataRoot: dataRoot).deletingLastPathComponent()
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        var publication: BridgeMessage?
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let row = try? JSONDecoder().decode(ChatRecord.self, from: data), let saved = row.outboundMessage,
                  matchesReplyPublication(saved, correlationID: correlationID, runID: runID) else { continue }
            guard chatURL(saved.id, dataRoot: dataRoot) == file,
                  let verified = try retainedReplyPublication(id: saved.id, correlationID: correlationID, dataRoot: dataRoot) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard publication == nil else { throw DeviceSyncError.conflict }
            publication = verified
        }
        return publication
    }

    /// Link the retained envelope before CloudKit can see the publication.
    nonisolated static func linkReplyPublication(_ message: BridgeMessage, dataRoot: URL) async throws {
        guard let correlation = message.correlationID, correlation != message.id else { return }
        let path = chatURL(correlation, dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var row: ChatRecord
            switch MacSyncEngine.coordinatedReadOutcome(at: path) {
            case .data(let data): row = try JSONDecoder().decode(ChatRecord.self, from: data)
            case .failed: throw CocoaError(.fileReadUnknown)
            case .missing:
                row = ChatRecord(direction: "mac_to_ios", action: "chat", state: "owed", msgId: correlation,
                    assistantSessionId: message.sessionID, targetSourceKey: message.metadata?["targetSourceKey"])
            }
            guard row.msgId == correlation, row.action == "chat",
                  row.replyPublicationId == nil || row.replyPublicationId == message.id else { throw DeviceSyncError.conflict }
            if row.replyPublicationId == message.id { return }
            row.replyPublicationId = message.id
            try writeChat(row, to: path)
        }
    }

    /// One retained publication in the existing ledger, before any send effect.
    nonisolated static func retainPublication(_ message: BridgeMessage, secret: Data, dataRoot: URL) async throws -> BridgeMessage {
        let path = chatURL(message.id, dataRoot: dataRoot)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            switch MacSyncEngine.coordinatedReadOutcome(at: path) {
            case .failed: throw CocoaError(.fileReadUnknown)
            case .data(let data):
                let record = try JSONDecoder().decode(ChatRecord.self, from: data)
                guard record.msgId == message.id, record.direction == "mac_to_ios",
                      let saved = record.outboundMessage, saved.verifySignature(secret: secret) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Retain first-publication time and signature; authored body fields must still describe the same effect.
                let candidate = BridgeMessage.make(id: message.id, sender: message.sender, text: message.text,
                    sessionID: message.sessionID, correlationID: message.correlationID,
                    metadata: message.metadata, attachments: message.attachments, timestamp: saved.timestamp)
                guard try candidate.canonicalBodyForSigning() == saved.canonicalBodyForSigning() else {
                    throw DeviceSyncError.conflict
                }
                return saved
            case .missing:
                let record = ChatRecord(direction: "mac_to_ios", action: "chat", state: "publication_owed",
                    msgId: message.id, outboundMessage: message)
                try writeChat(record, to: path)
                return message
            }
        }
    }

    nonisolated static func completePublication(_ id: String, dataRoot: URL) async throws {
        let path = chatURL(id, dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var row = try readChat(id, dataRoot: dataRoot)
            guard row.msgId == id, row.outboundMessage?.id == id else { throw CocoaError(.fileReadCorruptFile) }
            guard row.state != "completed" else { return }
            row.state = "completed"
            row.updatedAt = NativeTimestampFormat.plainZulu(Date())
            try writeChat(row, to: path)
        }
    }

    nonisolated static func replyReservation(_ correlation: String, session: String, sourceKey: String,
                                             dataRoot: URL) throws -> ChatRecord {
        let path = chatURL(correlation, dataRoot: dataRoot)
        let row = try FileManager.default.fileExists(atPath: path.path)
            ? readChat(correlation, dataRoot: dataRoot)
            : ChatRecord(direction: "mac_to_ios", action: "chat", state: "owed",
                         msgId: correlation, assistantSessionId: session, targetSourceKey: sourceKey)
        guard row.msgId == correlation, ["ios_to_mac", "mac_to_ios"].contains(row.direction),
              row.action == "chat", row.assistantSessionId == nil || row.assistantSessionId == session else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return row
    }

    nonisolated static func settleReply(_ correlation: String, session: String, sourceKey: String,
                                       state: String, dataRoot: URL) async throws {
        let result: Result<Void, Error> = await settle {
            do {
                let path = chatURL(correlation, dataRoot: dataRoot)
                try await SwiftNativePersistenceCore.withFileLock(path) {
                    var row = try replyReservation(correlation, session: session, sourceKey: sourceKey, dataRoot: dataRoot)
                    if row.state == state { return }
                    row.state = state
                    row.updatedAt = ISO8601DateFormatter().string(from: Date())
                    try writeChat(row, to: path)
                }
                return .success(())
            } catch { return .failure(error) }
        }
        try result.get()
    }
}
