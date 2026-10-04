import Foundation
import NotificationInbox
import PersistenceCore
import PersonaEngine

/// User 10-01: Agent is the boss. Where the harness used to card the person for
/// a peer's, a helper's or a driven agent's step and now lets her decide, it
/// leaves one rolling info row per requester and tool (no push) so he can see
/// what she decided. The detail is the session the decision happened in.
/// Written off the gate's path: the call it records never waits on the inbox.
public enum HarnessDecidedRow {
    public static func post(requester: String, tool: String, sessionID: String?, dataRoot: URL) {
        Task.detached { _ = await record(requester: requester, tool: tool, sessionID: sessionID, dataRoot: dataRoot) }
    }

    /// The same row, written before it returns, for a call whose own receipt
    /// says it was recorded: the row's id and how many decisions it holds.
    /// Nil when the inbox did not write. A decision after the open row was
    /// archived starts a new row, never vanishing into the archived one.
    public static func record(
        requester: String, tool: String, sessionID: String?, dataRoot: URL
    ) async -> (id: String, decisions: Int)? {
        let key = "harness_decided.\(requester).\(tool)"
        let title = "\(PersonaCompiler.agentDisplayName(dataRoot: dataRoot)) decided: \(requester) → \(tool)"
        let id = key + "." + UUID().uuidString.prefix(8).lowercased()
        let row: JSONValue = .object([
            "id": .string(id),
            "created_at": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string("harness_decided"),
            "severity": .string("info"),
            "title": .string(String(title.prefix(200))),
            "summary": .string(""),
            "detail": .string(sessionID ?? ""),
            "actions": .array([]),
            "status": .string("unread"),
        ])
        do {
            let written = try await LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
                .appendOrRollUpInformational(row, id: id, rollupKey: key, occurrenceID: UUID().uuidString)
            return (written.cardID, written.occurrenceCount)
        } catch {
            FileHandle.standardError.write(Data("HarnessDecidedRow: \(key) not recorded: \(error)\n".utf8))
            return nil
        }
    }
}
