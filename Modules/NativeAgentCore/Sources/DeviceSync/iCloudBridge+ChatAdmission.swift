import Foundation
import CryptoKit
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
// Blueprint: | `iCloudBridge+ChatAdmission.swift` | Durable chat admission, scoped Stop evidence, reply binding, exact signed publication retention and checked settlement in the one bridge ledger; unknown submissions stay nonterminal |

extension iCloudBridge {
    enum ChatAdmission: Sendable {
        case reserved(url: URL, contents: Data)
        case completed, interrupted, cancelled, unreadable, collision, stale, unavailable
    }

    /// The chat ledger's one schema includes admission, reply binding and recovery.
    /// Optional admission fields are absent on Mac-originated reply obligations.
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

    /// The admission ledger retains an accepted scoped Stop across transport delay and restart.
    /// Nonterminal Stop-only rows are never eligible for terminal retention pruning.
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

    nonisolated static func isTerminalChatTransaction(_ data: Data) -> Bool {
        guard let row = try? JSONDecoder().decode(ChatRecord.self, from: data),
              row.direction == "mac_to_ios" || row.hasAdmission else { return false }
        return ["completed", "failed_before_answer", "failed"].contains(row.state)
    }

    /// Both transports reserve the same canonical envelope before a turn starts.
    nonisolated static func reserveChat(_ message: BridgeMessage, dataRoot: URL, canDispatch: Bool) async -> ChatAdmission {
        do {
            let digest = MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning())
            let id = MacSyncSnapshotIntegrity.digest(Data(message.id.utf8))
            let url = Self.chatURL(message.id, dataRoot: dataRoot)
            return try await SwiftNativePersistenceCore.withFileLock(url) {
                var stopSession: String?
                switch MacSyncEngine.coordinatedReadOutcome(at: url) {
                case .data(let data):
                    guard let row = try? JSONDecoder().decode(ChatRecord.self, from: data) else { return .unreadable }
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
                    return row.stopRequestedSessionId == message.sessionID && row.stopRequestedSessionId != nil ? .cancelled : .interrupted
                case .failed:
                    return .unreadable
                case .missing:
                    break
                }
                // A message sent before this life began was another life's to answer
                // (an earlier install on this Mac, or before a restore): history, never a turn.
                if message.timestamp < (try DataRootLife.began(in: dataRoot)) { return .completed }
                let age = Date().timeIntervalSince(message.timestamp)
                guard age <= 24 * 60 * 60, age >= -15 * 60 else { return .stale }
                guard canDispatch else { return .unavailable }
                let now = ISO8601DateFormatter().string(from: Date())
                let row = ChatRecord(id: id, direction: "ios_to_mac", action: "chat",
                                                 state: "running", createdAt: now, updatedAt: now,
                                                 attempts: 1, msgId: message.id, actionDigest: digest,
                                                 stopRequestedSessionId: stopSession)
                let data = try Self.writeChat(row, to: url)
                guard case .data(let retained) = MacSyncEngine.coordinatedReadOutcome(at: url),
                      retained == data else { return .unavailable }
                return stopSession == nil ? .reserved(url: url, contents: data) : .cancelled
            }
        } catch {
            nativeLog("[iCloudBridge] chat reservation unavailable: %@", error.localizedDescription)
            return .unavailable
        }
    }

    /// Only the caller that has not entered a handler may release its new row.
    /// Exact bytes keep an interrupted or subsequently advanced row intact.
    nonisolated static func releaseUndispatchedChat(_ admission: ChatAdmission) async {
        await settle {
            if case .reserved(let url, let contents) = admission {
                do {
                    try await SwiftNativePersistenceCore.withFileLock(url) {
                        if try Data(contentsOf: url) == contents { try FileManager.default.removeItem(at: url) }
                    }
                } catch {
                    nativeLog("[iCloudBridge] undispatched chat reservation could not be released: %@", error.localizedDescription)
                }
            }
        }
    }

    nonisolated static func finishChat(_ message: BridgeMessage, dataRoot: URL, completed: Bool) async -> Bool {
        return await settle {
            do {
                let url = Self.chatURL(message.id, dataRoot: dataRoot)
                return try await SwiftNativePersistenceCore.withFileLock(url) {
                    var row = try Self.readChat(message.id, dataRoot: dataRoot)
                    guard row.hasAdmission, row.msgId == message.id,
                          row.actionDigest == MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning()) else { return false }
                    row.state = completed ? "completed" : "unknown"
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

    /// Recovery reads the producer's retained envelope, including when the
    /// receipt write failed. A generated recovery id is not its publication id.
    nonisolated static func retainedReplyPublication(correlationID: String, runID: String, dataRoot: URL) throws -> BridgeMessage? {
        let directory = dataRoot.appendingPathComponent("icloud/chat_transactions", isDirectory: true)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        var publication: BridgeMessage?
        for file in files where file.pathExtension == "json" {
            let row = try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: file))
            guard row.direction == "mac_to_ios", let saved = row.outboundMessage,
                  saved.correlationID == correlationID,
                  isRetainedChatReply(kind: saved.metadata?["kind"], canonicalRun: saved.metadata?["canonicalAnswerRunId"]),
                  (saved.metadata?["assistantRunId"] ?? saved.correlationID) == runID
                    || saved.metadata?["kind"] == "codex_completion" && saved.metadata?["assistantRunId"] == correlationID else { continue }
            guard row.action == "chat", row.msgId == saved.id, chatURL(saved.id, dataRoot: dataRoot) == file else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard publication == nil else { throw DeviceSyncError.conflict }
            publication = saved
        }
        return publication
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
                // Timestamp/signature are retained from the first publication;
                // every authored body field must still describe the same effect.
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
