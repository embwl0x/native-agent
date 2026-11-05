import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import Transcripts
import NativeAgentShared
// Blueprint: | `PriorChatSession.swift` | Participant-bound previous conversation lookup for transcript recall. |

// MARK: - PriorChatSession

// Previous-conversation recall requires an ended, participant-bound transcript.
/// Admit only ended sessions that strictly predate the current session, preventing interleaved windows from appearing previous.
/// Require exact nonempty participant and project binding; unknown or mixed participants carry nothing.
/// Archived sessions stay outside the implicit previous-conversation lookup.
package enum PriorChatSession {
    package struct Resolved: Sendable {
        package let id: String
        package let source: String?
        package let updatedAt: Date
        package let participant: String
        package let scope: String?

        static func admits(_ message: ChatMessage, participant: String, source: String?, scope: String?) -> Bool {
            let metadata: [String: JSONValue]?
            if case .object(let row)? = message.extras,
               case .object(let value)? = row["metadata"] { metadata = value }
            else { metadata = nil }
            return ConversationHistory.admitsContinuity(
                role: message.role, metadata: metadata,
                participant: participant, source: source, scope: scope)
        }
    }

    /// Bound index size before reading it on a turn.
    private static let maxIndexBytes = 5 * 1024 * 1024

    package static func latest(excluding currentSessionId: String, dataRoot: URL) throws -> Resolved? {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: path.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxIndexBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)

        // Without the current persisted session binding, the requesting participant is unknown.
        var anchor: Date? = nil
        var current: [String: JSONValue]? = nil
        for obj in rows {
            guard obj["id"]?.stringValue == currentSessionId else { continue }
            // An archived current thread has no implicit previous conversation.
            guard obj["archived"]?.boolValue != true else { return nil }
            anchor = parseTimestamp(obj["createdAt"]?.stringValue ?? obj["updatedAt"]?.stringValue ?? "")
            current = obj
            break
        }
        guard let anchor, let current, current["continuityParticipant"]?.stringValue != nil else { return nil }

        var best: Resolved? = nil
        for obj in rows {
            guard let id = obj["id"]?.stringValue, id != currentSessionId else { continue }
            guard sameParticipant(current, obj), let participant = obj["continuityParticipant"]?.stringValue else { continue }
            guard obj["archived"]?.boolValue != true else { continue }
            guard let updated = parseTimestamp(
                obj["updatedAt"]?.stringValue ?? obj["createdAt"]?.stringValue ?? ""
            ) else { continue }
            guard updated < anchor else { continue }
            if let best, best.updatedAt >= updated { continue }
            best = Resolved(
                id: id,
                source: obj["source"]?.stringValue,
                updatedAt: updated,
                participant: participant,
                scope: obj["continuityScope"]?.stringValue
            )
        }
        return best
    }

    private static func sameParticipant(_ lhs: [String: JSONValue], _ rhs: [String: JSONValue]) -> Bool {
        guard let participant = lhs["continuityParticipant"]?.stringValue, !participant.isEmpty,
              rhs["continuityParticipant"]?.stringValue == participant,
              lhs["projectSpaceId"] == rhs["projectSpaceId"] else { return false }
        // Shared rooms cannot donate another room's conversation even for the same sender.
        if participant != "local_operator", !participant.hasPrefix("peer:") {
            guard let scope = lhs["continuityScope"]?.stringValue, !scope.isEmpty else { return false }
            return lhs["source"] == rhs["source"] && rhs["continuityScope"]?.stringValue == scope
        }
        return true
    }

    package static func sameParticipant(sessionId: String, otherSessionId: String, dataRoot: URL) throws -> Bool {
        let path = dataRoot.appendingPathComponent("chat/sessions.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxIndexBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
        guard let current = rows.first(where: { $0["id"]?.stringValue == sessionId }),
              let other = rows.first(where: { $0["id"]?.stringValue == otherSessionId }),
              current["archived"]?.boolValue != true, other["archived"]?.boolValue != true else { return false }
        guard sameParticipant(current, other) else { return false }
        // Validate index participant binding against each transcript before selecting recall.
        for row in [current, other] {
            guard let id = row["id"]?.stringValue, let participant = row["continuityParticipant"]?.stringValue else { return false }
            let source = row["source"]?.stringValue
            let scope = row["continuityScope"]?.stringValue
            guard try SessionHistoryReader.continuityMessages(
                forSessionId: id, dataRoot: dataRoot, limit: 1, maximumBytes: 64 * 1024,
                matching: { Resolved.admits($0, participant: participant, source: source, scope: scope) }
            ) != nil else { return false }
        }
        return true
    }

    // MARK: time helpers

    /// Normalize fractional seconds to milliseconds because ISO8601DateFormatter accepts only millisecond precision.
    static func parseTimestamp(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let d = MemoryRecallScoring.parseTimestamp(s) { return d }
        return MemoryRecallScoring.parseTimestamp(normalizeFraction(s))
    }

    private static func normalizeFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        var idx = s.index(after: dot)
        var digits = 0
        while idx < s.endIndex, s[idx].isNumber {
            digits += 1
            idx = s.index(after: idx)
        }
        guard digits > 3 else { return s }
        let keepEnd = s.index(dot, offsetBy: 4)
        return String(s[..<keepEnd]) + String(s[idx...])
    }
}
