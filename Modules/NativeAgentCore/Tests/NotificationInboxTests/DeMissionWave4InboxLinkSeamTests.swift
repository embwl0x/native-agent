// Wave 4 (de-mission phase 2) — the NotificationInbox hand-rolled dict I/O
// half of the `related_mission_id` -> `related_execution_id` read-both.
//
// `NotificationInboxItem` does NOT go through Codable on this path: `fromLine`
// and `toJSONValue` are hand-written against raw string keys, so the CodingKeys
// widening in the Mac/iOS `InboxItemRecord` models does not cover it. Same four
// corners as the model tests: old decodes, new decodes, ENCODE still emits the
// OLD key byte-compatibly, and a negative control.

import Testing
import Foundation

import NativeAgentCore
@testable import NotificationInbox
import PersistenceCore

private func inboxLinkField(_ v: JSONValue, _ key: String) -> JSONValue? {
    guard case .object(let o) = v else { return nil }
    return o[key]
}

/// Live shape of one `notifications/inbox.jsonl` row.
private let legacyInboxLine: [String: JSONValue] = [
    "id": .string("card-1"),
    "created_at": .string("2026-07-11T04:00:00Z"),
    "source": .string("execution_complete:wsx-42"),
    "severity": .string("actionable"),
    "title": .string("Workshop execution finished"),
    "summary": .string("3 steps"),
    "detail": .null,
    "related_mission_id": .string("wsx-42"),
    "related_approval_id": .null,
    "related_paths": .null,
    "related_groups": .null,
    "actions": .array([]),
    "status": .string("unread"),
    "read_at": .null,
]

private func inboxLineSwappingLinkKey(
    _ base: [String: JSONValue],
    to key: String,
    value: JSONValue
) -> [String: JSONValue] {
    var out = base
    out.removeValue(forKey: "related_mission_id")
    out[key] = value
    return out
}

@Test("4b inbox: legacy related_mission_id line still reads")
func wave4InboxLineReadsLegacyKey() {
    let item = NotificationInboxItem.fromLine(legacyInboxLine)
    #expect(item.relatedWorkshopExecutionId == "wsx-42")
    #expect(item.id == "card-1")
}

@Test("4b inbox: future related_execution_id line reads")
func wave4InboxLineReadsFutureKey() {
    let line = inboxLineSwappingLinkKey(
        legacyInboxLine, to: "related_execution_id", value: .string("wsx-42")
    )
    let item = NotificationInboxItem.fromLine(line)
    #expect(item.relatedWorkshopExecutionId == "wsx-42")
}

@Test("4b inbox: future key wins when a line carries BOTH")
func wave4InboxLinePrefersFutureKey() {
    var line = legacyInboxLine
    line["related_mission_id"] = .string("old-id")
    line["related_execution_id"] = .string("new-id")
    #expect(NotificationInboxItem.fromLine(line).relatedWorkshopExecutionId == "new-id")
}

@Test("4b inbox: a NULL future key falls THROUGH to a usable legacy value")
func wave4InboxLineNullFutureFallsThrough() {
    // A future writer emits `related_execution_id: null` for non-execution
    // cards. If that shadowed a legacy id the card would silently lose its
    // execution link, which is the whole failure this widening exists to avoid.
    var line = legacyInboxLine
    line["related_execution_id"] = .null
    #expect(NotificationInboxItem.fromLine(line).relatedWorkshopExecutionId == "wsx-42")
}

@Test("4b inbox: ENCODE still emits related_mission_id — wave 4 is wire-invisible")
func wave4InboxLineEncodesLegacyKeyOnly() {
    for line in [
        legacyInboxLine,
        inboxLineSwappingLinkKey(
            legacyInboxLine, to: "related_execution_id", value: .string("wsx-42")
        ),
    ] {
        let out = NotificationInboxItem.fromLine(line).toJSONValue()
        #expect(inboxLinkField(out, "related_mission_id") == .string("wsx-42"))
        // The future spelling must NOT appear: a 0.3.7 iOS install reading this
        // snapshot only knows the old key.
        #expect(inboxLinkField(out, "related_execution_id") == nil)
    }
}

@Test("4b inbox: negative control — neither key reads nil and still emits a null legacy key")
func wave4InboxLineMissingBothKeysIsNull() {
    var line = legacyInboxLine
    line.removeValue(forKey: "related_mission_id")
    let item = NotificationInboxItem.fromLine(line)
    #expect(item.relatedWorkshopExecutionId == nil)
    // Python always emitted the key with `None`; that shape is unchanged.
    let out = item.toJSONValue()
    #expect(inboxLinkField(out, "related_mission_id") == .null)
    #expect(inboxLinkField(out, "related_execution_id") == nil)
}

@Test("4b inbox: the writer key constant has not moved")
func wave4InboxLinkWriterKeyUnchanged() {
    #expect(InboxExecutionLinkVocabulary.wireKey == "related_mission_id")
    #expect(InboxExecutionLinkVocabulary.futureKey == "related_execution_id")
}
