import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import AttentionRouting
import Experiences
// Blueprint: | `HeartbeatNoticeCards.swift` | Heartbeat condition episodes are matters; measured clearance resolves them without another alert |

extension HeartbeatBackgroundWork {
    public func upsertHeartbeatNoticeCard(dataRoot: URL, notice: HeartbeatNotice) async throws {
        let condition = notice.conditionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condition.isEmpty else { throw JSONRow.Malformed.field("conditionId") }
        let body = notice.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = try HeartbeatCardAction.cardActions(authored: notice.actions)
        try await BodyNotice.tell(key: "heartbeat-" + condition, from: "heartbeat",
            finding: condition, dataRoot: dataRoot) { id in
            try await port.tell(Matter(id: id, form: .ask, from: "heartbeat", title: "Heartbeat flagged something",
                summary: String(body.prefix(500)), words: body, choices: actions.map { .init(id: $0.id, label: $0.label) }),
                dataRoot: dataRoot, reach: .person(from: nil), turn: nil)
        }
    }

    /// A condition no longer measured active ends its episode; an active one keeps it, acknowledged or not.
    internal func retireInactiveHeartbeatCards(dataRoot: URL, activeConditionIDs: Set<String>) async {
        do {
            for matter in try await ForPerson.at(dataRoot).matters() where matter.face?.from == "heartbeat"
                && !activeConditionIDs.contains(where: { matter.id.hasPrefix("heartbeat-" + $0 + ":") }) {
                try await BodyNotice.resolve(matter, dataRoot: dataRoot)
            }
        } catch {
            nativeLog("Heartbeat condition resolution failed: %@", error.localizedDescription)
        }
    }
}
