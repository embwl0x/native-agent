import Foundation
import PersistenceCore
import Transcripts

enum SlackSessionStorageError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Slack conversation storage is unavailable. Repair or restore session_map.json before retrying; existing bindings have been preserved."
    }
}

struct SlackSessionStore: Sendable {
    let dataRoot: URL

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    func activeSessionId(for inbound: SlackInboundMessage) async throws -> String {
        // Mint/adopt and publish the reply anchor in one locked transaction.
        let resolved = try await Self.persistence.withFileLock(sessionMapPath) {
            var root = try loadSessionMap()
            guard case .object(var sessions)? = root["sessions"] else {
                throw SlackSessionStorageError.unavailable
            }
            var archivedThreads: [String: JSONValue] = [:]
            if case .object(let archived)? = root["archivedThreads"] { archivedThreads = archived }
            var entry: [String: JSONValue] = [:]
            if case .object(let existing)? = sessions[inbound.sessionKey] {
                entry = existing
            } else if case .object(let archived)? = archivedThreads.removeValue(forKey: inbound.sessionKey) {
                entry = archived
            }
            let now = Date()
            let stamp = SlackSocketModeLoop.nowString(now)
            let resolved: String
            if case .string(let existing)? = entry["activeSessionId"] {
                resolved = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let minted = UUID().uuidString
                if entry["createdAt"] == nil { entry["createdAt"] = .string(stamp) }
                entry["activeSessionId"] = .string(minted)
                entry["teamId"] = .string(inbound.teamId)
                entry["channelId"] = .string(inbound.channelId)
                entry["userId"] = .string(inbound.userId)
                resolved = minted
            }
            entry["updatedAt"] = .string(stamp)
            sessions[inbound.sessionKey] = .object(entry)
            var currentKeys: Set<String> = [inbound.sessionKey]
            if inbound.normalizedThreadTs == nil, let anchor = inbound.replyThreadTs {
                let key = "thread:\(inbound.teamId):\(inbound.channelId):\(anchor)"
                if case .object(let existing)? = sessions[key] ?? archivedThreads[key],
                   case .string(let existingID)? = existing["activeSessionId"],
                   existingID.trimmingCharacters(in: .whitespacesAndNewlines) != resolved {
                    throw SlackSessionStorageError.unavailable
                }
                sessions[key] = .object(entry)
                archivedThreads.removeValue(forKey: key)
                currentKeys.insert(key)
            }
            Self.retainThreadBindings(sessions: &sessions, archived: &archivedThreads, currentKeys: currentKeys, now: now)
            root["sessions"] = .object(sessions)
            root["archivedThreads"] = .object(archivedThreads)
            try await Self.persistence.writeJSON(.object(root), to: sessionMapPath)
            return resolved
        }
        try await ensureSessionRow(id: resolved, inbound: inbound)
        // A DM is User's own conversation (inbound is allowlisted); a channel
        // is a shared room and never becomes the anchor.
        if inbound.isDirectMessage {
            _ = try? await ConversationAnchor.publish(
                sessionId: resolved, source: "slack", conversationKind: .direct, dataRoot: dataRoot
            )
        }
        return resolved
    }

    /// Called only under the map lock. Keep the damaged original in place so
    /// subsequent reads cannot mistake quarantine for a missing authority store.
    private func loadSessionMap() throws -> [String: JSONValue] {
        let quarantine = sessionMapPath.appendingPathExtension("damaged")
        let bytes: Data
        do {
            bytes = try Data(contentsOf: sessionMapPath)
        } catch CocoaError.fileReadNoSuchFile {
            guard !FileManager.default.fileExists(atPath: quarantine.path) else {
                throw SlackSessionStorageError.unavailable
            }
            return ["sessions": .object([:])]
        } catch {
            throw SlackSessionStorageError.unavailable
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
            guard case .object(let root) = value,
                  case .object(let sessions)? = root["sessions"] else {
                throw SlackSessionStorageError.unavailable
            }
            var bindings = Array(sessions)
            if let value = root["archivedThreads"] {
                guard case .object(let archived) = value,
                      archived.keys.allSatisfy({ $0.hasPrefix("thread:") }) else {
                    throw SlackSessionStorageError.unavailable
                }
                bindings.append(contentsOf: archived)
            }
            for (key, value) in bindings {
                guard !key.isEmpty, case .object(let entry) = value,
                      case .string(let id)? = entry["activeSessionId"],
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SlackSessionStorageError.unavailable
                }
                for field in ["teamId", "channelId", "userId", "createdAt", "updatedAt"] {
                    if let value = entry[field] {
                        guard case .string = value else { throw SlackSessionStorageError.unavailable }
                    }
                }
            }
            return root
        } catch {
            if !FileManager.default.fileExists(atPath: quarantine.path) {
                try? FileManager.default.copyItem(at: sessionMapPath, to: quarantine)
            }
            throw SlackSessionStorageError.unavailable
        }
    }

    /// Expired bindings stop protecting inactive sessions from transcript
    /// retention. The bounded archive still resolves a returning old thread.
    private static func retainThreadBindings(
        sessions: inout [String: JSONValue],
        archived: inout [String: JSONValue],
        currentKeys: Set<String>,
        now: Date
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacyFormatter = ISO8601DateFormatter()
        func updatedAt(_ value: JSONValue) -> Date {
            guard case .object(let entry) = value,
                  case .string(let stamp)? = entry["updatedAt"] ?? entry["createdAt"] else {
                return .distantPast
            }
            return formatter.date(from: stamp) ?? legacyFormatter.date(from: stamp) ?? .distantPast
        }
        let threads = sessions.filter { $0.key.hasPrefix("thread:") }
            .sorted {
                if currentKeys.contains($0.key) != currentKeys.contains($1.key) {
                    return currentKeys.contains($0.key)
                }
                let lhs = updatedAt($0.value), rhs = updatedAt($1.value)
                return lhs == rhs ? $0.key < $1.key : lhs > rhs
            }
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        for (offset, binding) in threads.enumerated() {
            if offset >= 200 || updatedAt(binding.value) < cutoff {
                archived[binding.key] = binding.value
                sessions.removeValue(forKey: binding.key)
            }
        }
        let archiveCutoff = now.addingTimeInterval(-ChatSessionRetention.archivedMessageRetentionSeconds)
        let retained = archived.filter { updatedAt($0.value) >= archiveCutoff }
            .sorted {
                let lhs = updatedAt($0.value), rhs = updatedAt($1.value)
                return lhs == rhs ? $0.key < $1.key : lhs > rhs
            }.prefix(1_000)
        archived = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }

    private func ensureSessionRow(id: String, inbound: SlackInboundMessage) async throws {
        let title: String
        if inbound.isDirectMessage {
            title = "Slack DM \(inbound.userId)"
        } else if inbound.normalizedThreadTs != nil {
            title = "Slack Thread \(inbound.channelId)"
        } else if inbound.channelType == "mpim" {
            title = "Slack MPIM \(inbound.channelId)"
        } else {
            title = "Slack \(inbound.channelId)"
        }
        try await Self.ensureSessionRow(
            id: id,
            title: title,
            sourceKey: inbound.sessionKey,
            dataRoot: dataRoot
        )
    }

    static func ensureSessionRow(
        id: String,
        title: String,
        sourceKey: String,
        dataRoot: URL
    ) async throws {
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        try await persistence.withFileLock(sessionsPath) {
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            if rows.contains(where: { row in
                guard case .string(let rowId)? = row["id"] else { return false }
                return rowId == id
            }) {
                return
            }
            let now = SlackSocketModeLoop.nowString()
            // A channel still bound to a session retention archived picks its
            // conversation back up instead of starting an empty one.
            let row: [String: JSONValue] = try await ChatSessionRetention.restoreArchivedRow(
                sessionId: id, dataRoot: dataRoot
            ) ?? [
                "id": .string(id),
                "title": .string(title),
                "source": .string("slack"),
                "sourceKey": .string(sourceKey),
                "createdAt": .string(now),
                "updatedAt": .string(now),
                "archived": .bool(false),
                "messageCount": .int(0),
            ]
            rows.insert(row, at: 0)
            let out = try ChatSessionIndexFile.serializedData(for: rows)
            try out.write(to: sessionsPath, options: .atomic)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                now: Date(),
                context: "SlackSocketModeLoop.ensureSessionRow"
            )
        }
    }

    private var sessionMapPath: URL {
        dataRoot
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("session_map.json")
    }

    private var sessionsPath: URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private static let persistence = SwiftNativePersistenceCore()
}
