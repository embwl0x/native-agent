import Foundation
import PersistenceCore

struct SlackSessionStore: Sendable {
    let dataRoot: URL

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    func activeSessionId(for inbound: SlackInboundMessage) async throws -> String {
        if let mapped = await mappedSessionId(key: inbound.sessionKey), !mapped.isEmpty {
            try await ensureSessionRow(id: mapped, inbound: inbound)
            return mapped
        }
        // 2026-07-21 audit fix: mint-or-adopt must be ONE locked RMW. The
        // unlocked read above loses to a concurrent first message for the same
        // conversation — both sides saw nil, both minted, and the second patch
        // clobbered the first (orphaning that turn's session context). Re-check
        // inside the flock and adopt any id a concurrent patch already wrote.
        let resolved = try await patchSessionMap(key: inbound.sessionKey) { entry -> String in
            if case .string(let existing)? = entry["activeSessionId"] {
                let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            let minted = UUID().uuidString
            let now = SlackSocketModeLoop.nowString()
            if entry["createdAt"] == nil { entry["createdAt"] = .string(now) }
            entry["activeSessionId"] = .string(minted)
            entry["teamId"] = .string(inbound.teamId)
            entry["channelId"] = .string(inbound.channelId)
            entry["userId"] = .string(inbound.userId)
            entry["updatedAt"] = .string(now)
            return minted
        }
        try await ensureSessionRow(id: resolved, inbound: inbound)
        return resolved
    }

    private func mappedSessionId(key: String) async -> String? {
        guard let entry = await sessionMapEntry(key: key),
              case .string(let id)? = entry["activeSessionId"] else {
            return nil
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessionMapEntry(key: String) async -> [String: JSONValue]? {
        let current = await Self.persistence.readJSON(sessionMapPath, defaultValue: .object([:]))
        guard case .object(let root) = current,
              case .object(let sessions)? = root["sessions"],
              case .object(let entry)? = sessions[key] else {
            return nil
        }
        return entry
    }

    @discardableResult
    private func patchSessionMap<T: Sendable>(
        key: String,
        mutate: @escaping @Sendable (inout [String: JSONValue]) -> T
    ) async throws -> T {
        try await Self.persistence.withFileLock(sessionMapPath) {
            let current = await Self.persistence.readJSON(sessionMapPath, defaultValue: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            var sessions: [String: JSONValue]
            if case .object(let obj)? = root["sessions"] { sessions = obj } else { sessions = [:] }
            var entry: [String: JSONValue]
            if case .object(let obj)? = sessions[key] { entry = obj } else { entry = [:] }
            let result = mutate(&entry)
            sessions[key] = .object(entry)
            root["sessions"] = .object(sessions)
            try await Self.persistence.writeJSON(.object(root), to: sessionMapPath)
            return result
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
