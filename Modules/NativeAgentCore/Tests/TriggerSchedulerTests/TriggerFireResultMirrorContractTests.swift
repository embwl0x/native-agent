import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// Board M18: the app-side fire sites mirror a fired card into the REAL
// notifications inbox, but ONLY when the injected notifier did not already do
// it. That guard reads exactly two fields off TriggerFireResult:
//
//     mirror  <=>  status == "fired" && notified != true && item != nil
//
// Get either field wrong and the card is written twice (notify:true) or never
// (notify:false) — the two failure modes M18 exists to close. These tests pin
// the contract at the source, so a change to the fire path can't quietly break
// the app-side rule that depends on it.

private func mirrorTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TriggerMirrorContract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func mirrorLocalDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = 0
    return cal.date(from: dc)!
}

private func mirrorSeedInbox(_ rows: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONValue.array(rows).serializedData(pretty: true)
        .write(to: dir.appendingPathComponent("trigger_config.json"))
}

private func mirrorSeedSessionsUpdatedAt(_ date: Date, root: URL) throws {
    let dir = root.appendingPathComponent("chat", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rows: JSONValue = .array([
        .object([
            "id": .string("s1"),
            "title": .string("a thread"),
            "archived": .bool(false),
            "updatedAt": .string(SwiftNativeTriggerScheduler.isoTimestamp(date)),
        ]),
    ])
    try rows.serializedData(pretty: false).write(to: dir.appendingPathComponent("sessions.json"))
}

private func mirrorMakeClient(
    root: URL,
    now: @escaping @Sendable () -> Date,
    notifier: TriggerNotifier? = nil
) -> SwiftNativeTriggerScheduler {
    SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: now,
        notifier: notifier,
        worklogPath: root.appendingPathComponent("no-such-worklog.jsonl")
    )
}

/// The app-side rule, transcribed. Kept in the test so a change to the rule has
/// to be made here too, deliberately.
private func appWouldMirror(_ r: TriggerFireResult) -> Bool {
    r.status == "fired" && r.notified != true && r.item != nil
}

/// The other half of the app-side seam, transcribed:
/// `TriggerNotifierBinding.mirrorNonNotifiedFire` normalizes the card (id /
/// status=unread / read_at=null / created_at) and appends it to the LIVE inbox
/// at `<root>/notifications/inbox.jsonl`. A5.2 retired the legacy `<root>/inbox/`
/// silo, so this is the ONLY place a fired card lands — which means a Core test
/// that expects the NEXT fire to dedupe has to run this seam itself.
@discardableResult
private func appMirrorsCard(_ r: TriggerFireResult, root: URL) throws -> Bool {
    guard appWouldMirror(r), case .object(var card)? = r.item else { return false }
    if card["status"] == nil { card["status"] = .string("unread") }
    if card["read_at"] == nil { card["read_at"] = .null }
    if card["created_at"] == nil {
        card["created_at"] = .string(SwiftNativeTriggerScheduler.isoTimestamp(Date()))
    }
    let dir = root.appendingPathComponent("notifications", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("inbox.jsonl")
    var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    let encoded = String(
        data: try JSONValue.object(card).serializedData(pretty: false), encoding: .utf8
    ) ?? "{}"
    try Data((text + encoded + "\n").utf8).write(to: url)
    return true
}

private func idOf(_ item: JSONValue?) -> String? {
    guard case .object(let o)? = item, case .string(let s)? = o["id"] else { return nil }
    return s
}

private func briefRow(notify: Bool) -> JSONValue {
    .object([
        "name": .string("morning_brief"),
        "kind": .string("time"),
        "enabled": .bool(true),
        "config": .object(["hour": .int(8), "minute": .int(0), "notify": .bool(notify)]),
    ])
}

private actor CountingNotifier {
    private(set) var count = 0
    func record(_ n: TriggerNotification) -> JSONValue {
        count += 1
        return .object(["status": .string("accepted")])
    }
    nonisolated func notifier() -> TriggerNotifier { { [self] note in await self.record(note) } }
}

@Suite("TriggerFireResult: app-side mirror contract (M18)")
struct TriggerFireResultMirrorContractTests {

    /// notify:true + a wired notifier — the notifier mirrored it. The app MUST
    /// NOT mirror again, or the card double-writes.
    @Test func notifiedFireIsNotMirroredAgainByTheApp() async throws {
        let root = try mirrorTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try mirrorSeedInbox([briefRow(notify: true)], root: root)
        let rec = CountingNotifier()
        let client = mirrorMakeClient(root: root, now: { mirrorLocalDate(2026, 3, 5, 9, 0) },
                                      notifier: rec.notifier())

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")
        #expect(await rec.count == 1)          // the notifier ran, so it mirrored
        #expect(result.notified == true)
        #expect(!appWouldMirror(result))       // ...and the app stands down
    }

    /// notify:false — nothing pushed, nothing mirrored by the notifier. The app
    /// MUST mirror, or the card lands only in the legacy store nothing reads.
    @Test func nonNotifiedFireCarriesItsCardForTheAppToMirror() async throws {
        let root = try mirrorTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try mirrorSeedInbox([briefRow(notify: false)], root: root)
        let rec = CountingNotifier()
        let client = mirrorMakeClient(root: root, now: { mirrorLocalDate(2026, 3, 5, 9, 0) },
                                      notifier: rec.notifier())

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")
        #expect(await rec.count == 0)          // no push, so no notifier-side mirror
        #expect(result.notified == false)
        #expect(appWouldMirror(result))
        // The card the app mirrors is the one the scheduler surfaced — same id,
        // so notification/inbox correlation and dedup still line up.
        #expect(idOf(result.item) == result.itemId)
    }

    /// notify:true but NO notifier injected: the push cannot happen, but the
    /// card still exists and must still reach the user's inbox.
    @Test func notifyRequestedWithNoNotifierStillHandsTheAppItsCard() async throws {
        let root = try mirrorTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try mirrorSeedInbox([briefRow(notify: true)], root: root)
        let client = mirrorMakeClient(root: root, now: { mirrorLocalDate(2026, 3, 5, 9, 0) },
                                      notifier: nil)

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")
        #expect(result.notified == false)
        #expect(appWouldMirror(result))
    }

    /// A fire deduped against an already-active card created nothing new. The
    /// app MUST NOT mirror, or every re-fire appends a duplicate card.
    ///
    /// Pinned on `idle_checkin`, whose summary is a pure function of the clock +
    /// activity signal. A morning brief cannot self-dedupe: its summary counts
    /// unread inbox items, and the first brief IS one. (Same reasoning as
    /// TriggerNotifyTests.dedupedFireSurfacesNoNewCardAndSendsNoPush.)
    @Test func dedupedFireCarriesNoCardSoTheAppDoesNotDuplicateIt() async throws {
        let root = try mirrorTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try mirrorSeedInbox([
            .object(["name": .string("idle_checkin"), "kind": .string("idle"),
                     "enabled": .bool(true),
                     "config": .object(["idle_minutes": .int(30), "notify": .bool(false)])]),
        ], root: root)
        try mirrorSeedSessionsUpdatedAt(mirrorLocalDate(2026, 3, 5, 14, 0), root: root)
        let now = mirrorLocalDate(2026, 3, 5, 14, 45)
        let client = mirrorMakeClient(root: root, now: { now }, notifier: nil)

        let first = try await client.fireInboxTrigger(name: "idle_checkin", isStub: true)
        #expect(first.status == "fired")
        #expect(appWouldMirror(first))           // a real new card — the app mirrors it
        // …and it ACTUALLY mirrors it. This fire is notify:false, so the card
        // reaches the live inbox through `mirrorNonNotifiedFire`, not through a
        // notifier. Without running that seam there is nothing on disk for the
        // second fire to dedupe against (A5.2: surface() writes nothing).
        #expect(try appMirrorsCard(first, root: root))

        // Identical clock + activity signal ⇒ identical source+title+summary ⇒
        // surface() matches the mirrored card and hands back the EXISTING id.
        let second = try await client.fireInboxTrigger(name: "idle_checkin", isStub: true)
        #expect(second.status == "fired")
        #expect(second.itemId == first.itemId)   // the existing card, not a new one
        #expect(second.item == nil)              // nothing new to mirror
        #expect(!appWouldMirror(second))
    }

    /// Workshop fires have no inbox card at all.
    @Test func workshopExecutionFireCarriesNoInboxCard() async throws {
        let root = try mirrorTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = mirrorMakeClient(root: root, now: { mirrorLocalDate(2026, 3, 5, 9, 0) })

        let result = try await client.fireWorkshopTrigger(name: "no_such_mission_trigger")
        #expect(result.item == nil)
        #expect(!appWouldMirror(result))
    }
}
