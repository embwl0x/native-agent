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
// Blueprint: | `iCloudBridge+ChatAdmission.swift` | Durable chat admission, reply binding and settlement in the bridge ledger |

extension iCloudBridge {
    enum ChatAdmission: Sendable {
        case reserved(url: URL, contents: Data)
        case completed, interrupted, unreadable, collision, stale, unavailable
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

    nonisolated static func isTerminalChatTransaction(_ data: Data) -> Bool {
        guard let row = try? JSONDecoder().decode(ChatRecord.self, from: data),
              row.direction == "mac_to_ios" || row.hasAdmission else { return false }
        return ["completed", "sent_unconfirmed", "failed_before_answer", "unknown", "failed"].contains(row.state)
    }

    /// Both transports reserve the same canonical envelope before a turn starts.
    nonisolated static func reserveChat(_ message: BridgeMessage, dataRoot: URL, canDispatch: Bool) async -> ChatAdmission {
        do {
            let digest = MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning())
            let id = MacSyncSnapshotIntegrity.digest(Data(message.id.utf8))
            let url = Self.chatURL(message.id, dataRoot: dataRoot)
            return try await SwiftNativePersistenceCore.withFileLock(url) {
                switch MacSyncEngine.coordinatedReadOutcome(at: url) {
                case .data(let data):
                    guard let row = try? JSONDecoder().decode(ChatRecord.self, from: data), row.hasAdmission else { return .unreadable }
                    guard row.id == id, row.msgId == message.id, row.actionDigest == digest,
                          row.direction == "ios_to_mac", row.action == "chat" else { return .collision }
                    return ["completed", "sent_unconfirmed", "failed_before_answer"].contains(row.state) ? .completed : .interrupted
                case .failed:
                    return .unreadable
                case .missing:
                    break
                }
                let age = Date().timeIntervalSince(message.timestamp)
                guard age <= 24 * 60 * 60, age >= -15 * 60 else { return .stale }
                guard canDispatch else { return .unavailable }
                let now = ISO8601DateFormatter().string(from: Date())
                let row = ChatRecord(id: id, direction: "ios_to_mac", action: "chat",
                                                 state: "running", createdAt: now, updatedAt: now,
                                                 attempts: 1, msgId: message.id, actionDigest: digest)
                let data = try Self.writeChat(row, to: url)
                guard case .data(let retained) = MacSyncEngine.coordinatedReadOutcome(at: url),
                      retained == data else { return .unavailable }
                return .reserved(url: url, contents: data)
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
