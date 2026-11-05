import Foundation
import NativeAgentShared
import NativeAgentCore
import Experiences
import PersistenceCore
// Blueprint: | `TriggerNotificationInbox.swift` | Trigger acceptance tells one matter with its doors; duplicates and superseded briefs read ForPerson |

public protocol TriggerSnapshotDeliveryPort: Sendable {
    func writeSnapshots() async
}

public enum TriggerNotificationInbox {
    /// A repeated occurrence is the same happening, including after the person handled it; a repeated open face is not another notice.
    public static func accept(_ note: TriggerNotification, notify: Bool, dataRoot: URL) async throws -> String? {
        let matter = try matter(note)
        let forPerson = ForPerson.at(dataRoot)
        let matters = try await forPerson.matters()
        let occurrence = try JSONRow(note.item).optionalString("trigger_occurrence")
        if let occurrence, let prior = matters.first(where: {
            $0.face?.from == note.source && $0.evidence.contains(.init(source: note.source, id: occurrence))
        }) { return prior.id }
        if let prior = matters.first(where: {
            guard $0.face?.from == note.source, ForPerson.reading($0) == .unread || ForPerson.reading($0) == .read,
                  $0.face?.row?.title == matter.title, $0.face?.row?.detail == matter.summary,
                  let at = NativeTimestampFormat.parseISO8601FractionalFirst($0.at) else { return false }
            return Date().timeIntervalSince(at) <= 7 * 86_400
        }) { return prior.id }
        let filed = try await forPerson.tell(matter, doors: notify ? Door.person(thread: nil) : [])
        if note.source == "trigger:morning_brief" { await archiveSupersededMorningBriefs(dataRoot: dataRoot) }
        return filed == .born ? nil : matter.id
    }

    public static func matter(_ note: TriggerNotification) throws -> Matter {
        guard !note.itemId.isEmpty else { throw TriggerSchedulerError.invalidRequest("inbox item missing id") }
        let row = try JSONRow(note.item)
        guard try row.string("id") == note.itemId else { throw JSONRow.Malformed.field("id") }
        let severity = try row.string("severity")
        let authored = try row.optional("actions") { value -> [JSONValue]? in
            if case .array(let actions) = value { return actions }; return nil
        }
        let choices = try (authored ?? []).map { action -> PartFace.Action in
            let value = try JSONRow(action)
            return .init(id: try value.string("id"), label: try value.string("label"))
        }
        let paths = try (row.optionalStrings("related_paths") ?? []).map { Experience.Ref(source: Matter.files, id: $0) }
        let occurrence = try row.optionalString("trigger_occurrence")
        let summary = try row.optionalString("summary") ?? note.body
        return Matter(id: note.itemId,
            form: severity == "critical" ? .wentWrong : note.ownerWaiting || severity == "actionable" ? .ask : .words,
            from: note.source, title: note.title, summary: summary,
            words: try row.optionalString("detail") ?? summary,
            choices: choices, evidence: occurrence.map { [.init(source: note.source, id: $0)] } ?? [], artifacts: paths)
    }

    /// Keep only the newest active brief, without reopening a brief the person already handled.
    public static func archiveSupersededMorningBriefs(dataRoot: URL = PersistenceCore.defaultDataRoot()) async {
        do {
            let forPerson = ForPerson.at(dataRoot)
            let briefs = try await forPerson.matters().filter { $0.face?.from == "trigger:morning_brief" }
            for old in briefs.dropFirst() where ForPerson.reading(old) == .unread || ForPerson.reading(old) == .read {
                try await forPerson.answered(old.id, evidence: nil, letGo: .cancelled)
                try await forPerson.putAway(old.id, .resolved)
            }
        } catch {
            nativeLog("trigger_mirror: morning brief reconciliation failed: %@", error.localizedDescription)
        }
    }
}
