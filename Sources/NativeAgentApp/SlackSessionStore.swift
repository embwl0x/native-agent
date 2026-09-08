import Foundation
import PersistenceCore

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
            var entry: [String: JSONValue] = [:]
            if case .object(let existing)? = sessions[inbound.sessionKey] { entry = existing }
            let resolved: String
            if case .string(let existing)? = entry["activeSessionId"] {
                resolved = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let minted = UUID().uuidString
                let now = SlackSocketModeLoop.nowString()
                if entry["createdAt"] == nil { entry["createdAt"] = .string(now) }
                entry["activeSessionId"] = .string(minted)
                entry["teamId"] = .string(inbound.teamId)
                entry["channelId"] = .string(inbound.channelId)
                entry["userId"] = .string(inbound.userId)
                entry["updatedAt"] = .string(now)
                resolved = minted
            }
            sessions[inbound.sessionKey] = .object(entry)
            if inbound.normalizedThreadTs == nil, let anchor = inbound.replyThreadTs {
                let key = "thread:\(inbound.teamId):\(inbound.channelId):\(anchor)"
                if case .object(let existing)? = sessions[key],
                   case .string(let existingID)? = existing["activeSessionId"],
                   existingID.trimmingCharacters(in: .whitespacesAndNewlines) != resolved {
                    throw SlackSessionStorageError.unavailable
                }
                sessions[key] = .object(entry)
            }
            root["sessions"] = .object(sessions)
            try await Self.persistence.writeJSON(.object(root), to: sessionMapPath)
            return resolved
        }
        try await ensureSessionRow(id: resolved, inbound: inbound)
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
            for (key, value) in sessions {
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
            let row: [String: JSONValue] = [
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
