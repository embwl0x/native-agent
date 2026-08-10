import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// The push + receipt contract:
//   - `notify` resolves from config.notify, else the per-name default table.
//   - The push is what `notify: false` suppresses. The RECEIPT NEVER IS.
//     Every fire writes exactly one `kind: "trigger"` activity event, so the
//     path can never go blind-quiet.
//   - notify requested with no notifier wired ⇒ the event says so, loudly
//     (`status: "warn"`), instead of vanishing.
// Plus the newly-lit `idle` periodic condition and its one-fire-per-episode
// re-arm.

// MARK: - Harness

private func tempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TriggerNotifyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = 0
    return cal.date(from: dc)!
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func set(_ d: Date) { lock.lock(); _now = d; lock.unlock() }
}

/// Captures every push the scheduler dispatches and returns a canned
/// `deliveryFields()`-shaped object, exactly like the app's real notifier.
private actor RecordingNotifier {
    private(set) var calls: [TriggerNotification] = []
    nonisolated let delivery: JSONValue = .object([
        "status": .string("accepted"),
        "route": .string("apns"),
        "apnsAccepted": .bool(true),
    ])

    func record(_ n: TriggerNotification) -> JSONValue {
        calls.append(n)
        return delivery
    }

    var count: Int { calls.count }
    var first: TriggerNotification? { calls.first }

    nonisolated func notifier() -> TriggerNotifier {
        { [self] note in await self.record(note) }
    }

    /// A5.2: in production the card LANDS because the app-side notifier seam
    /// (`TriggerNotifierBinding.pairedDevicePush`) mirrors `note.item` into
    /// `<root>/notifications/inbox.jsonl` — normalized (id / status=unread /
    /// read_at=null / created_at) — before it knocks. Core has no app seam, so
    /// a dedupe test must simulate that contract or the second fire has nothing
    /// to dedupe against. Same recording behaviour, plus the card write.
    nonisolated func cardLandingNotifier(root: URL) -> TriggerNotifier {
        { [self] note in
            let delivery = await self.record(note)
            guard case .object(var card) = note.item,
                  case .string(let id)? = card["id"], !id.isEmpty else { return .null }
            if card["status"] == nil { card["status"] = .string("unread") }
            if card["read_at"] == nil { card["read_at"] = .null }
            if card["created_at"] == nil {
                card["created_at"] = .string(SwiftNativeTriggerScheduler.isoTimestamp(Date()))
            }
            let dir = root.appendingPathComponent("notifications", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("inbox.jsonl")
                var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                let encoded = String(
                    data: try JSONValue.object(card).serializedData(pretty: false),
                    encoding: .utf8
                ) ?? "{}"
                try Data((text + encoded + "\n").utf8).write(to: url)
            } catch {
                return .null
            }
            return delivery
        }
    }
}

private func seedInbox(_ rows: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONValue.array(rows).serializedData(pretty: true)
        .write(to: dir.appendingPathComponent("trigger_config.json"))
}

private func seedSessionsUpdatedAt(_ date: Date, root: URL) throws {
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

/// Every `kind: "trigger"` row in `<root>/activity/events.jsonl`.
private func triggerEvents(root: URL) -> [[String: JSONValue]] {
    let path = root.appendingPathComponent("activity/events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    var out: [[String: JSONValue]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let d = String(line).data(using: .utf8),
              case .object(let o)? = try? JSONValue.parse(d),
              case .string("trigger")? = o["kind"] else { continue }
        out.append(o)
    }
    return out
}

private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

private func payload(_ e: [String: JSONValue]) -> [String: JSONValue] {
    if case .object(let p)? = e["payload"] { return p }
    return [:]
}

private func makeClient(
    root: URL,
    now: @escaping @Sendable () -> Date = { Date() },
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

private let morningBriefRow: JSONValue = .object([
    "name": .string("morning_brief"),
    "kind": .string("time"),
    "enabled": .bool(true),
    "config": .object(["hour": .int(8), "minute": .int(0)]),
])

// MARK: - notify resolution

@Suite("TriggerScheduler: notify resolution")
struct NotifyResolutionSuite {

    @Test func configNotifyWins() {
        let on = TriggerConfig(name: "idle_checkin", enabled: true, config: .object(["notify": .bool(true)]))
        let off = TriggerConfig(name: "morning_brief", enabled: true, config: .object(["notify": .bool(false)]))
        #expect(SwiftNativeTriggerScheduler.resolveNotify(on))
        #expect(!SwiftNativeTriggerScheduler.resolveNotify(off))
    }

    /// The migration case: an EXISTING install's trigger_config.json predates
    /// the `notify` key entirely. Seeding the defaults alone would never reach
    /// it — the per-name table is what does.
    @Test func perNameFallbackReachesExistingInstalls() {
        let brief = TriggerConfig(name: "morning_brief", enabled: true, config: .object(["hour": .int(8)]))
        let idle = TriggerConfig(name: "idle_checkin", enabled: true, config: .object([:]))
        let unknown = TriggerConfig(name: "some_new_trigger", enabled: true, config: nil)
        #expect(SwiftNativeTriggerScheduler.resolveNotify(brief))
        #expect(!SwiftNativeTriggerScheduler.resolveNotify(idle))
        #expect(!SwiftNativeTriggerScheduler.resolveNotify(unknown))
    }

    @Test func nonBoolNotifyFallsBackRatherThanGuessing() {
        let weird = TriggerConfig(name: "morning_brief", enabled: true, config: .object(["notify": .string("yes")]))
        #expect(SwiftNativeTriggerScheduler.resolveNotify(weird))   // falls back to the table → true
        let weirdIdle = TriggerConfig(name: "idle_checkin", enabled: true, config: .object(["notify": .int(1)]))
        #expect(!SwiftNativeTriggerScheduler.resolveNotify(weirdIdle))
    }

    /// The shipped defaults must agree with the fallback table, or a fresh
    /// install and an upgraded one would behave differently.
    @Test func seededDefaultsAgreeWithFallbackTable() throws {
        for row in SwiftNativeTriggerScheduler._defaultInboxConfigs {
            let cfg = try #require(TriggerConfig(json: row))
            let seeded: Bool? = {
                if case .object(let o)? = cfg.config, case .bool(let b)? = o["notify"] { return b }
                return nil
            }()
            guard let seeded else { continue }
            #expect(seeded == (SwiftNativeTriggerScheduler.notifyDefaultsByName[cfg.name] ?? false),
                    "seeded notify for \(cfg.name) disagrees with the per-name fallback table")
        }
        // idle_checkin ships quiet: newly-lit condition, opt-in push.
        let idle = try #require(SwiftNativeTriggerScheduler._defaultInboxConfigs
            .compactMap(TriggerConfig.init(json:)).first { $0.name == "idle_checkin" })
        #expect(!SwiftNativeTriggerScheduler.resolveNotify(idle))
        #expect(idle.enabled == false)
    }
}

// MARK: - push + receipt

@Suite("TriggerScheduler: notify dispatch + activity receipt")
struct NotifyDispatchSuite {

    @Test func notifyTruePushesOnceAndWritesReceipt() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([morningBriefRow], root: root)
        let rec = RecordingNotifier()
        let now = localDate(2026, 3, 5, 9, 0)
        let client = makeClient(root: root, now: { now }, notifier: rec.notifier())

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")
        #expect(result.stub == false)

        #expect(await rec.count == 1)
        let note = try #require(await rec.first)
        #expect(note.triggerName == "morning_brief")
        #expect(note.kind == "time")
        #expect(note.title == "Morning brief — Thursday, March 5")
        #expect(note.screen == "inbox")
        #expect(note.source == "trigger:morning_brief")
        #expect(note.urgency == "high")          // severity "important"
        #expect(!note.body.isEmpty)
        #expect(!note.body.contains("Stub"))

        let events = triggerEvents(root: root)
        #expect(events.count == 1)
        let e = try #require(events.first)
        #expect(str(e["status"]) == "ok")
        #expect(str(e["title"]) == "Morning brief — Thursday, March 5")
        #expect(e["executionId"] == .null)
        let p = payload(e)
        #expect(p["notified"] == .bool(true))
        #expect(p["placeholder"] == .bool(false))
        #expect(p["triggerName"] == .string("morning_brief"))
        #expect(p["itemId"] == .string(result.itemId ?? ""))
        guard case .object(let delivery)? = p["delivery"] else {
            Issue.record("expected a delivery object on a notified fire"); return
        }
        #expect(delivery["status"] == .string("accepted"))
    }

    @Test func notifyFalseSuppressesPushButNeverTheReceipt() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["hour": .int(8), "minute": .int(0), "notify": .bool(false)]),
            ]),
        ], root: root)
        let rec = RecordingNotifier()
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 9, 0) }, notifier: rec.notifier())

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")
        #expect(await rec.count == 0)

        let events = triggerEvents(root: root)
        #expect(events.count == 1)
        let e = try #require(events.first)
        #expect(str(e["status"]) == "ok")
        let p = payload(e)
        #expect(p["notified"] == .bool(false))
        #expect(p["delivery"] == nil)
        #expect((str(e["detail"]) ?? "").contains("notify disabled"))
    }

    /// No silent stub: a wanted push with no wiring is a WARN on the record,
    /// not an absence.
    @Test func notifyWantedButUnwiredWarnsOnTheRecord() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([morningBriefRow], root: root)
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 9, 0) }, notifier: nil)

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")          // the item still lands

        let events = triggerEvents(root: root)
        #expect(events.count == 1)
        let e = try #require(events.first)
        #expect(str(e["status"]) == "warn")
        #expect((str(e["detail"]) ?? "").contains("no notifier wired"))
        #expect(payload(e)["notified"] == .bool(false))
        #expect(payload(e)["delivery"] == nil)
    }

    /// `.null` from the notifier means NOTHING was delivered — for the app
    /// notifier, the real-inbox card write itself failed and the push was
    /// suppressed. `notified` stays FALSE so the app-side fire sites retry the
    /// mirror instead of treating the card as handled (gpt-5.5 review,
    /// 2026-07-09 — the lost notify:true card). The fire still succeeded and
    /// the receipt still lands as a WARN.
    @Test func nullNotifierReturnLeavesNotifiedFalseAndWarns() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([morningBriefRow], root: root)
        let failing: TriggerNotifier = { _ in .null }
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 9, 0) }, notifier: failing)

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")            // the item landed
        #expect(result.notified == false)            // so the fire site mirrors it
        let e = try #require(triggerEvents(root: root).first)
        #expect(str(e["status"]) == "warn")
        #expect((str(e["detail"]) ?? "").contains("notifier reported FAILURE"))
        #expect(payload(e)["notified"] == .bool(false))  // nothing was delivered
        #expect(payload(e)["delivery"] == nil)           // no receipt to record
    }

    /// The PARTIAL outcome: the sender landed the card but the push send
    /// failed (`{"delivered": false}`). `notified` stays TRUE — mirroring
    /// again would double-write the card — but the record reads WARN, not ok.
    @Test func partialDeliveryKeepsNotifiedTrueButWarns() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([morningBriefRow], root: root)
        let partial: TriggerNotifier = { _ in
            .object(["delivered": .bool(false), "mirrored": .bool(true)])
        }
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 9, 0) }, notifier: partial)

        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")
        #expect(result.notified == true)             // card landed — do NOT re-mirror
        let e = try #require(triggerEvents(root: root).first)
        #expect(str(e["status"]) == "warn")
        #expect((str(e["detail"]) ?? "").contains("push send FAILED"))
        #expect(payload(e)["notified"] == .bool(true))
    }

    /// `ProactiveInboxStore.surface` suppresses an active duplicate (same
    /// source+title+summary, still unread, within 7 days) and hands back the
    /// EXISTING item id without appending. No new card appeared, so pushing
    /// would notify User about something already unread in his inbox. The
    /// receipt still lands, flagged `deduped`.
    ///
    /// Pinned on `idle_checkin` because its summary is a pure function of the
    /// clock + activity signal. A morning brief cannot self-dedupe in practice:
    /// its summary counts unread inbox items, and the first brief IS one.
    @Test func dedupedFireSurfacesNoNewCardAndSendsNoPush() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object(["name": .string("idle_checkin"), "kind": .string("idle"),
                     "enabled": .bool(true),
                     "config": .object(["idle_minutes": .int(30), "notify": .bool(true)])]),
        ], root: root)
        try seedSessionsUpdatedAt(localDate(2026, 3, 5, 14, 0), root: root)
        let rec = RecordingNotifier()
        let now = localDate(2026, 3, 5, 14, 45)
        // The second fire only dedupes if the FIRST fire's card is visible in
        // the live inbox — which in production the notifier seam puts there.
        let client = makeClient(root: root, now: { now },
                                notifier: rec.cardLandingNotifier(root: root))

        let first = try await client.fireInboxTrigger(name: "idle_checkin", isStub: true)
        #expect(first.status == "fired")
        #expect(await rec.count == 1)

        // Identical clock + identical activity signal ⇒ identical title+summary.
        let second = try await client.fireInboxTrigger(name: "idle_checkin", isStub: true)
        #expect(second.status == "fired")
        #expect(second.itemId == first.itemId)      // the ORIGINAL card, not a new one
        #expect(await rec.count == 1)               // no second push

        let events = triggerEvents(root: root)
        #expect(events.count == 2)                  // the receipt is never suppressed
        let e = try #require(events.last)
        #expect(payload(e)["deduped"] == .bool(true))
        #expect(payload(e)["notified"] == .bool(false))
        #expect(payload(e)["delivery"] == nil)
        #expect((str(e["detail"]) ?? "").contains("duplicate of an active inbox item"))
        // And the first receipt was NOT flagged.
        #expect(payload(try #require(events.first))["deduped"] == nil)
    }

    @Test func placeholderKindsRefuseToFabricateCardsOrReceipts() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object(["name": .string("mission_followup"), "kind": .string("mission_complete"),
                     "enabled": .bool(true), "config": .object([:])]),
        ], root: root)
        let rec = RecordingNotifier()
        let client = makeClient(root: root, notifier: rec.notifier())

        let result = try await client.fireInboxTrigger(name: "mission_followup", isStub: true)
        #expect(result.status == "error")
        #expect(result.stub == false)
        #expect(result.item == nil)
        #expect(await rec.count == 0)
        #expect(triggerEvents(root: root).isEmpty)
    }

    /// A fire that never happened writes nothing — the receipt is a receipt,
    /// not a log line.
    @Test func notFoundWritesNoReceipt() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([morningBriefRow], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireInboxTrigger(name: "nope", isStub: true)
        #expect(result.status == "not_found")
        #expect(triggerEvents(root: root).isEmpty)
    }
}

// MARK: - idle periodic condition

@Suite("TriggerScheduler: idle self-fire episode")
struct IdleEpisodeSuite {

    private static let idleRow: JSONValue = .object([
        "name": .string("idle_checkin"),
        "kind": .string("idle"),
        "enabled": .bool(true),
        "config": .object([
            "idle_minutes": .int(30),
            "quiet_start_hour": .int(23),
            "quiet_end_hour": .int(8),
        ]),
    ])

    @Test func firesOncePerEpisodeThenReArmsOnNewActivity() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([Self.idleRow], root: root)

        let lastActivity = localDate(2026, 3, 5, 14, 0)
        try seedSessionsUpdatedAt(lastActivity, root: root)

        let clock = MutableClock(localDate(2026, 3, 5, 14, 20))   // 20m quiet — not yet
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])

        clock.set(localDate(2026, 3, 5, 14, 31))                  // 31m quiet — due
        #expect(await client.evaluateAndFire() == ["idle_checkin"])

        // Same episode, one tick later: the claim holds.
        clock.set(localDate(2026, 3, 5, 14, 32))
        #expect(await client.evaluateAndFire() == [])
        clock.set(localDate(2026, 3, 5, 16, 0))
        #expect(await client.evaluateAndFire() == [])

        // User says something → lastActivity advances → new episode, new instant.
        let newActivity = localDate(2026, 3, 5, 16, 30)
        try seedSessionsUpdatedAt(newActivity, root: root)
        clock.set(localDate(2026, 3, 5, 16, 45))                  // 15m — not yet
        #expect(await client.evaluateAndFire() == [])
        clock.set(localDate(2026, 3, 5, 17, 5))                   // 35m — due again
        #expect(await client.evaluateAndFire() == ["idle_checkin"])
    }

    @Test func quietHoursEpisodeStaysDark() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([Self.idleRow], root: root)
        // Last activity 01:00 → episode instant 01:30, inside 23→08 quiet hours.
        try seedSessionsUpdatedAt(localDate(2026, 3, 5, 1, 0), root: root)
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 2, 0) })
        #expect(await client.evaluateAndFire() == [])
        #expect(triggerEvents(root: root).isEmpty)
    }

    @Test func noActivitySignalKeepsIdleDark() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([Self.idleRow], root: root)
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 14, 0) })
        #expect(await client.evaluateAndFire() == [])
    }

    @Test func invalidIdleMinutesKeepsTriggerDormant() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object(["name": .string("idle_checkin"), "kind": .string("idle"),
                     "enabled": .bool(true), "config": .object(["idle_minutes": .int(0)])]),
        ], root: root)
        try seedSessionsUpdatedAt(localDate(2026, 3, 5, 10, 0), root: root)
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 14, 0) })
        #expect(await client.evaluateAndFire() == [])
    }

    /// The periodic tick is a fire site too: an idle episode that resolves
    /// notify=true must reach the sender, and always leaves a receipt.
    @Test func periodicIdleFireWritesReceiptAndHonorsNotify() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object(["name": .string("idle_checkin"), "kind": .string("idle"),
                     "enabled": .bool(true),
                     "config": .object(["idle_minutes": .int(30), "notify": .bool(true)])]),
        ], root: root)
        try seedSessionsUpdatedAt(localDate(2026, 3, 5, 14, 0), root: root)
        let rec = RecordingNotifier()
        let client = makeClient(root: root, now: { localDate(2026, 3, 5, 14, 45) }, notifier: rec.notifier())

        #expect(await client.evaluateAndFire() == ["idle_checkin"])
        #expect(await rec.count == 1)
        let note = try #require(await rec.first)
        #expect(note.urgency == "normal")               // severity "info"
        #expect(note.body.hasPrefix("Quiet for 45m."))

        let e = try #require(triggerEvents(root: root).first)
        #expect(payload(e)["notified"] == .bool(true))
        #expect(payload(e)["placeholder"] == .bool(false))
        #expect(payload(e)["triggerKind"] == .string("idle"))
    }
}
