import Testing
import Foundation
@testable import NotificationInbox
import NativeAgentCore
import PersistenceCore

// MARK: - Temp fixtures

/// Write `items.jsonl` (one JSON object per line) + optional `index.json` into a
/// fresh temp `<dir>/inbox` and return the inbox dir.
private func makeInboxDir(
    itemsLines: [String],
    indexJSON: String? = nil
) throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("naitest-\(UUID().uuidString)", isDirectory: true)
    let inbox = base.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let items = itemsLines.joined(separator: "\n") + (itemsLines.isEmpty ? "" : "\n")
    try items.write(to: inbox.appendingPathComponent("items.jsonl"), atomically: true, encoding: .utf8)
    if let indexJSON {
        try indexJSON.write(to: inbox.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
    }
    return inbox
}

private func line(
    id: String,
    createdAt: String,
    source: String = "trigger:file_watch:foo.swift",
    severity: String = "info",
    title: String = "t",
    summary: String = "s",
    status: String = "unread",
    extra: String = ""
) -> String {
    "{\"id\":\"\(id)\",\"created_at\":\"\(createdAt)\",\"source\":\"\(source)\",\"severity\":\"\(severity)\",\"title\":\"\(title)\",\"summary\":\"\(summary)\",\"actions\":[],\"status\":\"\(status)\"\(extra)}"
}

private func idsOf(_ v: JSONValue) -> [String] {
    guard case .array(let arr) = v else { return [] }
    return arr.compactMap { item in
        if case .object(let o) = item, case .string(let id)? = o["id"] { return id }
        return nil
    }
}

private func field(_ v: JSONValue, _ key: String) -> JSONValue? {
    if case .object(let o) = v { return o[key] }
    return nil
}

// MARK: - load_all + overlay

@Test func loadAllAppliesIndexOverlay() throws {
    let dir = try makeInboxDir(
        itemsLines: [
            line(id: "a", createdAt: "2026-06-01T10:00:00Z", status: "unread"),
            line(id: "b", createdAt: "2026-06-01T11:00:00Z", status: "unread"),
        ],
        // overlay flips b -> archived with a read_at
        indexJSON: #"{"b": {"status": "archived", "read_at": "2026-06-01T12:00:00Z"}}"#
    )
    let store = NotificationInboxStore(inboxDir: dir)
    let items = store.loadAll()
    #expect(items.count == 2)
    let a = items.first { $0.id == "a" }!
    let b = items.first { $0.id == "b" }!
    #expect(a.status == "unread")          // no overlay -> base status
    #expect(a.readAt == nil)
    #expect(b.status == "archived")        // overlay applied
    #expect(b.readAt == "2026-06-01T12:00:00Z")
}

@Test func missingItemsFileYieldsEmpty() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("naitest-missing-\(UUID().uuidString)/inbox", isDirectory: true)
    let store = NotificationInboxStore(inboxDir: dir)
    #expect(store.loadAll().isEmpty)
    #expect(store.unreadCount() == 0)
    #expect(store.list().isEmpty)
    #expect(store.get("nope") == nil)
}

@Test func malformedLinesAreSkipped() throws {
    let dir = try makeInboxDir(itemsLines: [
        line(id: "ok", createdAt: "2026-06-01T10:00:00Z"),
        "{ this is not valid json",
        "",
        "   ",
        line(id: "ok2", createdAt: "2026-06-01T09:00:00Z"),
    ])
    let store = NotificationInboxStore(inboxDir: dir)
    let items = store.loadAll()
    #expect(items.count == 2)
    #expect(Set(items.map { $0.id }) == ["ok", "ok2"])
}

@Test func overlayPresentWithoutReadAtClearsReadAt() throws {
    // Python: when id is in the index, read_at = overlay.get("read_at") even if
    // absent -> None. So an overlay entry with only "status" wipes any base read_at.
    let dir = try makeInboxDir(
        itemsLines: [ line(id: "x", createdAt: "2026-06-01T10:00:00Z", extra: ",\"read_at\":\"2026-06-01T08:00:00Z\"") ],
        indexJSON: #"{"x": {"status": "read"}}"#
    )
    let store = NotificationInboxStore(inboxDir: dir)
    let x = store.get("x")!
    #expect(x.status == "read")
    #expect(x.readAt == nil)   // overlay had no read_at -> cleared
}

@Test func nonObjectOverlayDropsItem() throws {
    // Python: `index[id]` non-dict -> overlay.get() raises -> item dropped by
    // the surrounding except. Swift must `continue` (drop) the item.
    let dir = try makeInboxDir(
        itemsLines: [
            line(id: "good", createdAt: "2026-06-01T10:00:00Z"),
            line(id: "bad", createdAt: "2026-06-01T11:00:00Z"),
        ],
        // "bad" overlay is a STRING, not an object -> Python raises -> dropped.
        indexJSON: #"{"bad": "not-an-object"}"#
    )
    let store = NotificationInboxStore(inboxDir: dir)
    let items = store.loadAll()
    #expect(items.map { $0.id } == ["good"])  // "bad" dropped
}

@Test func nowISOMatchesPythonIsoformatShape() {
    // Python isoformat() emits +00:00 offset (NOT Z). Zero-microsecond instant
    // omits the fractional part.
    let zeroMicros = Date(timeIntervalSince1970: 1_780_000_000)  // integral second
    let s = NotificationInboxStore.nowISO(zeroMicros)
    #expect(s.hasSuffix("+00:00"))
    #expect(!s.contains("Z"))
    #expect(!s.contains("."))  // no fractional part at an integral second
    // Sub-second instant carries 6-digit microseconds.
    let withMicros = Date(timeIntervalSince1970: 1_780_000_000.123456)
    let s2 = NotificationInboxStore.nowISO(withMicros)
    #expect(s2.hasSuffix("+00:00"))
    #expect(s2.contains("."))
}

@Test func negativeLimitMatchesPythonSlice() throws {
    let lines = (0..<5).map { line(id: "n\($0)", createdAt: String(format: "2026-06-01T%02d:00:00Z", $0)) }
    let dir = try makeInboxDir(itemsLines: lines)
    let store = NotificationInboxStore(inboxDir: dir)
    // 5 items newest-first: n4 n3 n2 n1 n0. Python items[:-2] -> drop last 2.
    #expect(store.list(limit: -2).map { $0.id } == ["n4", "n3", "n2"])
    // limit more negative than count -> empty (Python items[:-99] == []).
    #expect(store.list(limit: -99).isEmpty)
}

// MARK: - list ordering + unread filter + limit

@Test func listSortsMostRecentFirst() throws {
    let dir = try makeInboxDir(itemsLines: [
        line(id: "old", createdAt: "2026-06-01T08:00:00Z"),
        line(id: "new", createdAt: "2026-06-01T12:00:00Z"),
        line(id: "mid", createdAt: "2026-06-01T10:00:00Z"),
    ])
    let store = NotificationInboxStore(inboxDir: dir)
    let listed = store.list()
    #expect(listed.map { $0.id } == ["new", "mid", "old"])
}

@Test func listUnreadOnlyFilters() throws {
    let dir = try makeInboxDir(
        itemsLines: [
            line(id: "u", createdAt: "2026-06-01T10:00:00Z", status: "unread"),
            line(id: "r", createdAt: "2026-06-01T11:00:00Z", status: "unread"),
        ],
        indexJSON: #"{"r": {"status": "read"}}"#
    )
    let store = NotificationInboxStore(inboxDir: dir)
    #expect(store.list(unreadOnly: true).map { $0.id } == ["u"])
    #expect(store.list(unreadOnly: false).map { $0.id } == ["r", "u"])  // r is newer
    #expect(store.unreadCount() == 1)
}

@Test func listRespectsLimit() throws {
    let lines = (0..<10).map { line(id: "i\($0)", createdAt: String(format: "2026-06-01T%02d:00:00Z", $0)) }
    let dir = try makeInboxDir(itemsLines: lines)
    let store = NotificationInboxStore(inboxDir: dir)
    #expect(store.list(limit: 3).count == 3)
    #expect(store.list(limit: 3).map { $0.id } == ["i9", "i8", "i7"])  // newest 3
}

// MARK: - status transitions (index.json overlay write)

@Test func markReadWritesOverlayAndPreservesLog() throws {
    let dir = try makeInboxDir(itemsLines: [ line(id: "z", createdAt: "2026-06-01T10:00:00Z") ])
    let store = NotificationInboxStore(inboxDir: dir)
    #expect(store.markRead("z", now: "2026-06-01T13:00:00Z"))

    // items.jsonl untouched (still the original line); overlay flips status.
    let reloaded = NotificationInboxStore(inboxDir: dir).get("z")!
    #expect(reloaded.status == "read")
    #expect(reloaded.readAt == "2026-06-01T13:00:00Z")

    // index.json now exists and carries the entry.
    let idx = store.loadIndex()
    #expect(idx["z"] != nil)
}

@Test func dismissAndArchiveSetStatus() throws {
    let dir = try makeInboxDir(itemsLines: [
        line(id: "d", createdAt: "2026-06-01T10:00:00Z"),
        line(id: "a", createdAt: "2026-06-01T11:00:00Z"),
    ])
    let store = NotificationInboxStore(inboxDir: dir)
    #expect(store.dismiss("d"))
    #expect(store.markArchived("a"))
    let s2 = NotificationInboxStore(inboxDir: dir)
    #expect(s2.get("d")!.status == "dismissed")
    #expect(s2.get("a")!.status == "archived")
    // dismiss/archive set NO read_at (Python passes read_at=None).
    #expect(s2.get("d")!.readAt == nil)
    #expect(s2.get("a")!.readAt == nil)
}

@Test func updateStatusPreservesOtherIndexKeys() throws {
    // An existing overlay entry with an extra key must keep it after update
    // (Python: entry = dict(index.get(id, {})); entry["status"] = ...).
    let dir = try makeInboxDir(
        itemsLines: [ line(id: "k", createdAt: "2026-06-01T10:00:00Z") ],
        indexJSON: #"{"k": {"status": "unread", "custom": "keepme"}}"#
    )
    let store = NotificationInboxStore(inboxDir: dir)
    #expect(store.markArchived("k"))
    let idx = NotificationInboxStore(inboxDir: dir).loadIndex()
    guard case .object(let entry)? = idx["k"] else { Issue.record("missing entry"); return }
    #expect(entry["status"] == .string("archived"))
    #expect(entry["custom"] == .string("keepme"))
}

// MARK: - payload wire shape

@Test func toJSONValueEmitsNullForAbsentOptionals() throws {
    let dir = try makeInboxDir(itemsLines: [ line(id: "p", createdAt: "2026-06-01T10:00:00Z") ])
    let item = NotificationInboxStore(inboxDir: dir).get("p")!
    let payload = item.toJSONValue()
    #expect(field(payload, "detail") == .null)
    #expect(field(payload, "related_mission_id") == .null)
    #expect(field(payload, "related_approval_id") == .null)
    #expect(field(payload, "related_paths") == .null)
    #expect(field(payload, "read_at") == .null)
    #expect(field(payload, "actions") == .array([]))
    #expect(field(payload, "status") == .string("unread"))
}

// MARK: - SwiftNative reader + enrichment fallback

@Test func swiftNativeListServesPureTriggerInbox() async throws {
    let dir = try makeInboxDir(itemsLines: [
        line(id: "t1", createdAt: "2026-06-01T10:00:00Z", source: "trigger:file_watch:x"),
        line(id: "m1", createdAt: "2026-06-01T11:00:00Z", source: "mission_complete:abc"),
    ])
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    let listed = await reader.list(unreadOnly: false)
    #expect(listed != nil)
    #expect(idsOf(listed!) == ["m1", "t1"])  // newest first
}

@Test func swiftNativeListDeclinesProactiveCard() async throws {
    // ANY proactive_autonomy:* item declines the local list (nil), because those
    // cards still need a richer enrichment path.
    let dir = try makeInboxDir(itemsLines: [
        line(id: "t1", createdAt: "2026-06-01T10:00:00Z", source: "trigger:file_watch:x"),
        line(id: "p1", createdAt: "2026-06-01T11:00:00Z", source: "proactive_autonomy:code_review:op1"),
    ])
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    let listed = await reader.list(unreadOnly: false)
    #expect(listed == nil)
}

@Test func swiftNativeGetNotFoundAndDeclinedEnrichment() async throws {
    let dir = try makeInboxDir(itemsLines: [
        line(id: "ok", createdAt: "2026-06-01T10:00:00Z", source: "idle_checkin"),
        line(id: "pc", createdAt: "2026-06-01T11:00:00Z", source: "proactive_autonomy:k:o"),
    ])
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)

    // missing id -> .notFound (reproduces daemon 404).
    if case .notFound? = await reader.get(id: "missing") {} else { Issue.record("expected notFound") }

    // pure source -> .found.
    if case .found(let v)? = await reader.get(id: "ok") {
        #expect(field(v, "id") == .string("ok"))
    } else { Issue.record("expected found") }

    // proactive card -> nil (native enrichment not implemented here).
    #expect(await reader.get(id: "pc") == nil)
}

@Test func statusWritesNativeByDefault() async throws {
    // Wave 32 W16: defaults flipped ON (flock + ledger prereqs closed). All three
    // writes now serve natively for a NON-proactive item (no ledger entry made).
    let dir = try makeInboxDir(itemsLines: [ line(id: "g", createdAt: "2026-06-01T10:00:00Z", source: "idle_checkin") ])
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    #expect(await reader.markRead(id: "g") == true)
    #expect(await reader.markArchived(id: "g") == true)
    #expect(await reader.dismiss(id: "g") == true)
    // Final overlay reflects the last write (dismiss).
    #expect(NotificationInboxStore(inboxDir: dir).get("g")!.status == "dismissed")
}

@Test func statusWritesForcedToHTTPWhenDisabled() async throws {
    // The rollback knob: passing FALSE forces a write surface back to HTTP
    // (nil sentinel) without changing the read owner.
    let dir = try makeInboxDir(itemsLines: [ line(id: "g", createdAt: "2026-06-01T10:00:00Z", source: "idle_checkin") ])
    let writesOff = SwiftNativeNotificationInbox(inboxDir: dir, statusWritesEnabled: false)
    #expect(await writesOff.markRead(id: "g") == nil)
    #expect(await writesOff.markArchived(id: "g") == nil)
    #expect(await writesOff.dismiss(id: "g") == nil)

    // markRead is allowed even with outcome OFF (no ledger dep); archive/dismiss
    // require BOTH flags (they fire the ledger).
    let outcomeOff = SwiftNativeNotificationInbox(inboxDir: dir, statusWritesEnabled: true, proactiveOutcomeWired: false)
    #expect(await outcomeOff.markRead(id: "g") == true)
    #expect(await outcomeOff.markArchived(id: "g") == nil)
    #expect(await outcomeOff.dismiss(id: "g") == nil)
}

// MARK: - proactive-outcome ledger wiring (the wave 32 W16 port)

/// Read the parsed records of `<root>/nextgen/proactive/outcomes.jsonl`.
private func readOutcomes(root: URL) -> [JSONValue] {
    let p = root
        .appendingPathComponent("nextgen", isDirectory: true)
        .appendingPathComponent("proactive", isDirectory: true)
        .appendingPathComponent("outcomes.jsonl")
    guard let data = try? Data(contentsOf: p), let s = String(data: data, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
}

@Test func archiveProactiveCardRecordsUsefulOutcome() async throws {
    let dir = try makeInboxDir(itemsLines: [
        line(id: "pc", createdAt: "2026-06-01T10:00:00Z", source: "proactive_autonomy:code_review:opp42"),
    ])
    let root = dir.deletingLastPathComponent()
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    #expect(await reader.markArchived(id: "pc") == true)

    let outcomes = readOutcomes(root: root)
    #expect(outcomes.count == 1)
    let rec = outcomes[0]
    #expect(field(rec, "itemId") == .string("pc"))
    #expect(field(rec, "kind") == .string("code_review"))
    #expect(field(rec, "opportunityId") == .string("opp42"))
    #expect(field(rec, "outcome") == .string("archive"))
    #expect(field(rec, "useful") == .bool(true))     // archive => useful
    #expect(field(rec, "source") == .string("inbox"))
    // status flipped too.
    #expect(NotificationInboxStore(inboxDir: dir).get("pc")!.status == "archived")
}

@Test func dismissProactiveCardRecordsNotUseful() async throws {
    let dir = try makeInboxDir(itemsLines: [
        line(id: "pc", createdAt: "2026-06-01T10:00:00Z", source: "proactive_autonomy:idea:o9"),
    ])
    let root = dir.deletingLastPathComponent()
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    #expect(await reader.dismiss(id: "pc") == true)
    let outcomes = readOutcomes(root: root)
    #expect(outcomes.count == 1)
    #expect(field(outcomes[0], "outcome") == .string("dismiss"))
    #expect(field(outcomes[0], "useful") == .bool(false))   // dismiss => not useful
}

@Test func nonProactiveCardRecordsNoOutcome() async throws {
    // mark_archived on a NON-proactive item must NOT write the ledger (the
    // daemon's maybe_record_* early-returns when source isn't proactive_autonomy:).
    let dir = try makeInboxDir(itemsLines: [
        line(id: "n", createdAt: "2026-06-01T10:00:00Z", source: "mission_complete:abc"),
    ])
    let root = dir.deletingLastPathComponent()
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    #expect(await reader.markArchived(id: "n") == true)
    #expect(readOutcomes(root: root).isEmpty)
    #expect(NotificationInboxStore(inboxDir: dir).get("n")!.status == "archived")
}

@Test func markReadNeverRecordsOutcome() async throws {
    // mark_read is a bare status flip in the daemon — no ledger entry even for a
    // proactive card.
    let dir = try makeInboxDir(itemsLines: [
        line(id: "pc", createdAt: "2026-06-01T10:00:00Z", source: "proactive_autonomy:code_review:opp1"),
    ])
    let root = dir.deletingLastPathComponent()
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    #expect(await reader.markRead(id: "pc") == true)
    #expect(readOutcomes(root: root).isEmpty)
}

@Test func ledgerDedupsSecondOutcomeForSameItem() async throws {
    // _proactive_outcome_exists_for_item: a second archive/dismiss for an item
    // that already has an outcome must NOT append a duplicate ledger record (but
    // the status write still proceeds).
    let dir = try makeInboxDir(itemsLines: [
        line(id: "pc", createdAt: "2026-06-01T10:00:00Z", source: "proactive_autonomy:k:o"),
    ])
    let root = dir.deletingLastPathComponent()
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    #expect(await reader.markArchived(id: "pc") == true)
    #expect(await reader.dismiss(id: "pc") == true)   // second outcome — deduped
    let outcomes = readOutcomes(root: root)
    #expect(outcomes.count == 1)                       // only the first recorded
    #expect(field(outcomes[0], "outcome") == .string("archive"))
    // status still advanced to dismissed.
    #expect(NotificationInboxStore(inboxDir: dir).get("pc")!.status == "dismissed")
}

@Test func sourcePartsParsing() {
    #expect(ProactiveOutcomeLedger.sourceParts("proactive_autonomy:code_review:opp1").kind == "code_review")
    #expect(ProactiveOutcomeLedger.sourceParts("proactive_autonomy:code_review:opp1").opportunityId == "opp1")
    // last segment is the opportunity id even with extra colons in the middle.
    #expect(ProactiveOutcomeLedger.sourceParts("proactive_autonomy:k:mid:final").opportunityId == "final")
    // not a proactive source -> empty.
    #expect(ProactiveOutcomeLedger.sourceParts("trigger:file_watch:x").kind == "")
    // too few segments -> empty (Python: len(parts) < 3).
    #expect(ProactiveOutcomeLedger.sourceParts("proactive_autonomy:onlyone").kind == "")
}

@Test func ledgerWritesActivityEcho() async throws {
    // record_proactive_outcome echoes a record_activity("proactive", ...) event;
    // verify the activity/events.jsonl entry lands with the expected shape.
    let dir = try makeInboxDir(itemsLines: [
        line(id: "pc", createdAt: "2026-06-01T10:00:00Z", source: "proactive_autonomy:k:o"),
    ])
    let root = dir.deletingLastPathComponent()
    let reader = SwiftNativeNotificationInbox(inboxDir: dir)
    #expect(await reader.markArchived(id: "pc") == true)
    let actPath = root
        .appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    let data = try Data(contentsOf: actPath)
    let s = String(data: data, encoding: .utf8)!
    let events = s.split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
    #expect(events.count == 1)
    #expect(field(events[0], "kind") == .string("proactive"))
    #expect(field(events[0], "title") == .string("Proactive outcome recorded"))
    #expect(field(events[0], "status") == .string("ok"))
    #expect(field(events[0], "detail") == .string("archive"))
}

// MARK: - factory gating

@Test func factoryReturnsSwiftNative() async throws {
    let dir = try makeInboxDir(itemsLines: [ line(id: "f", createdAt: "2026-06-01T10:00:00Z", source: "idle_checkin") ])
    let reader = makeNotificationInbox(inboxDir: dir)
    #expect(reader is SwiftNativeNotificationInbox)
    let listed = await reader.list(unreadOnly: false)
    #expect(listed != nil)
    #expect(idsOf(listed!) == ["f"])
}
