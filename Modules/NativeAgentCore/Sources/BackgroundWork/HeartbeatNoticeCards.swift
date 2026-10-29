import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import WorkshopExecution
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatNoticeCards.swift` | HeartbeatBackgroundWork stable notice cards, attention delivery and inactive-condition retirement |
extension HeartbeatBackgroundWork {
    public func upsertHeartbeatNoticeCard(dataRoot: URL, notice: HeartbeatNotice) async throws {
        let body = notice.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardId = heartbeatCardID(conditionId: notice.conditionId)
        let now = NativeTimestampFormat.fractionalZulu(Date())
        let actions = try HeartbeatCardAction.cardActions(authored: notice.actions)
        let card: [String: JSONValue] = [
            "id": .string(cardId),
            "created_at": .string(now),
            "source": .string("heartbeat"),
            "severity": .string("actionable"),
            "title": .string("Heartbeat flagged something"),
            "summary": .string(String(body.prefix(500))),
            "detail": .string(body),
            "condition_id": .string(notice.conditionId),
            "condition_active": .bool(true),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array(actions.map(heartbeatActionJSON)),
            "status": .string("unread"),
            "read_at": .null,
        ]
        do {
            let isNewOccurrence = try await LiveNotificationInbox.live(dataRoot: dataRoot)
                .upsert(id: cardId) { existing in
                    var updated = card
                    if case .object(let previous)? = existing,
                       previous["condition_active"] != .bool(false) {
                        for key in ["status", "read_at", "created_at"] {
                            if let value = previous[key] { updated[key] = value }
                        }
                        return (.object(updated), false)
                    }
                    return (.object(updated), true)
                }
            if isNewOccurrence {
                await port.notifyIfAttentionWorthy(
                    dataRoot: dataRoot,
                    itemId: cardId,
                    title: "Heartbeat flagged something",
                    summary: String(body.prefix(420)) + "\nFlagged at \(now)",
                    source: "heartbeat",
                    severity: "actionable"
                )
            }
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: notice upsert failed: \(error)\n".utf8))
            throw error
        }
    }
    internal func retireInactiveHeartbeatCards(
        dataRoot: URL,
        activeConditionIDs: Set<String>
    ) async {
        let inboxPath = heartbeatInboxPath(dataRoot: dataRoot)
        let now = NativeTimestampFormat.fractionalZulu(Date())
        do {
            try await SwiftNativePersistenceCore.withFileLock(inboxPath) { () async throws -> Void in
                let lines = try LiveNotificationInbox.readLines(inboxPath)
                guard !lines.isEmpty else { return }
                var changed = false
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count)
                for line in lines {
                    guard case .object(var obj)? = line.row,
                          case .string(let source)? = obj["source"],
                          source == "heartbeat",
                          case .string(let id)? = obj["id"],
                          id.hasPrefix("heartbeat-") else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    let conditionID: String
                    if case .string(let explicit)? = obj["condition_id"], !explicit.isEmpty {
                        conditionID = explicit
                    } else {
                        conditionID = String(id.dropFirst("heartbeat-".count))
                    }
                    if activeConditionIDs.contains(conditionID) {
                        mutated.append(line.raw)
                        continue
                    }
                    let status: String
                    if case .string(let raw)? = obj["status"] {
                        status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    } else {
                        status = "unread"
                    }
                    if (status == "archived" || status == "dismissed"),
                       obj["condition_active"] == .bool(false) {
                        mutated.append(line.raw)
                        continue
                    }
                    obj["condition_active"] = .bool(false)
                    if status != "archived" && status != "dismissed" {
                        obj["status"] = .string("archived")
                        obj["read_at"] = .string(now)
                    }
                    mutated.append(Data(try JSONValue.object(obj).serialize(pretty: false).utf8))
                    changed = true
                }
                guard changed else { return }
                try LiveNotificationInbox.write(mutated, to: inboxPath)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: stale card retirement failed: \(error)\n".utf8))
        }
    }
    private func heartbeatInboxPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }
    private func heartbeatCardID(conditionId: String) -> String {
        let cleaned = conditionId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "heartbeat-\(cleaned.isEmpty ? "unknown" : cleaned)"
    }
    private func heartbeatActionJSON(_ action: HeartbeatNoticeAction) -> JSONValue {
        .object([
            "id": .string(action.id),
            "label": .string(action.label),
            "description": .string(action.description ?? action.label),
        ])
    }
}
