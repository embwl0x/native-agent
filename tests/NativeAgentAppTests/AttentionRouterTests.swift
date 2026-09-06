import Foundation
import Testing
import BackgroundLoops
import TriggerScheduler
@testable import NativeAgentApp

// Item 26 — one attention router. These tests pin the four things the router
// exists to guarantee:
//   1. the routing table, per importance class × last-active surface,
//   2. edge-trigger dedupe per event id, re-pinging only on a NEW reason,
//   3. the morning brief: ONE phone push plus its card, never a chat message,
//   4. a routine delegation success: no push at all.

private enum RouterTestError: Error {
    case phoneFailed
    case telegramFailed
}

private actor SendRecorder {
    struct Phone: Sendable {
        let title: String
        let body: String
        let userInfo: [String: String]
    }

    private(set) var phone: [Phone] = []
    private(set) var telegram: [String] = []
    private var phoneFailures: Int
    private var telegramFailures: Int

    init(phoneFailures: Int = 0, telegramFailures: Int = 0) {
        self.phoneFailures = phoneFailures
        self.telegramFailures = telegramFailures
    }

    func sendPhone(title: String, body: String, userInfo: [String: String]) throws {
        if phoneFailures > 0 {
            phoneFailures -= 1
            throw RouterTestError.phoneFailed
        }
        phone.append(Phone(title: title, body: body, userInfo: userInfo))
    }

    func sendTelegram(_ text: String) throws {
        if telegramFailures > 0 {
            telegramFailures -= 1
            throw RouterTestError.telegramFailed
        }
        telegram.append(text)
    }
}

private func emptyReceipt() -> MobileNotificationDeliveryReceipt {
    MobileNotificationDeliveryReceipt(
        bridgeMessageID: "test-bridge-id",
        bridgeError: nil,
        apnsReceipts: [],
        apnsErrors: []
    )
}

@Suite("Attention router", .serialized)
struct AttentionRouterTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRouter(
        root: URL,
        recorder: SendRecorder,
        lastActive: AttentionSurface?
    ) -> AttentionRouter {
        AttentionRouter(
            dataRoot: root,
            phoneSender: { title, body, userInfo in
                try await recorder.sendPhone(title: title, body: body, userInfo: userInfo)
                return emptyReceipt()
            },
            telegramSender: { text in try await recorder.sendTelegram(text) },
            surfaceReader: { lastActive }
        )
    }

    // MARK: - 1. The routing table, per class × surface

    @Test("routing table: every importance class × every last-active surface")
    func routingTable() {
        let surfaces: [AttentionSurface?] = [.chat, .ios, .telegram, nil]

        // A routine success NEVER knocks, wherever User is. This is the 345 of
        // 500 "Codex/Claude finished" rows.
        for surface in surfaces {
            #expect(AttentionRouter.delivery(importance: .routineSuccess, lastActive: surface) == .none)
        }

        // Informational is the phone, once — never the surface he happens to be
        // on, and never a chat message.
        for surface in surfaces {
            #expect(AttentionRouter.delivery(importance: .informational, lastActive: surface) == .phone)
        }

        // Owner-waiting and adverse follow him, with the phone as the fallback
        // for every surface that is not Telegram (and for an unknown one).
        for importance in [AttentionImportance.ownerWaiting, .adverse] {
            #expect(AttentionRouter.delivery(importance: importance, lastActive: .telegram) == .telegram)
            #expect(AttentionRouter.delivery(importance: importance, lastActive: .ios) == .phone)
            #expect(AttentionRouter.delivery(importance: importance, lastActive: .chat) == .phone)
            #expect(AttentionRouter.delivery(importance: importance, lastActive: nil) == .phone)
        }

        // The table is total: no class falls through without a decision.
        for importance in AttentionImportance.allCases {
            for surface in surfaces {
                let delivery = AttentionRouter.delivery(importance: importance, lastActive: surface)
                #expect(delivery == .none || delivery == .phone || delivery == .telegram)
            }
        }
    }

    @Test("owner-waiting on Telegram sends a Telegram message, not a push")
    func ownerWaitingFollowsUserToTelegram() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()
        let router = makeRouter(root: root, recorder: recorder, lastActive: .telegram)

        let outcome = try await router.route(
            eventId: "needs_user+abc",
            importance: .ownerWaiting,
            title: "Agent needs you",
            body: "A build needs your decision"
        )

        #expect(outcome.delivery == .telegram)
        #expect(await recorder.telegram == ["Agent needs you\n\nA build needs your decision"])
        #expect(await recorder.phone.isEmpty)
    }

    @Test("a Telegram outage falls back to the phone — the fallback is the point")
    func telegramFailureFallsBackToPhone() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder(telegramFailures: 1)
        let router = makeRouter(root: root, recorder: recorder, lastActive: .telegram)

        let outcome = try await router.route(
            eventId: "adverse+1",
            importance: .adverse,
            title: "Delegation failed",
            body: "codex run failed"
        )

        #expect(outcome.delivery == .phone)
        let phone = await recorder.phone
        #expect(phone.count == 1)
        #expect(phone[0].userInfo["telegramFallback"] == "1")
        #expect(phone[0].userInfo["importance"] == "adverse")
    }

    // MARK: - 2. Edge-trigger dedupe, idempotent per event id

    @Test("same event id + same reason knocks once; a NEW reason re-pings")
    func edgeTriggerDedupe() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()
        let router = makeRouter(root: root, recorder: recorder, lastActive: .ios)

        for _ in 0..<3 {
            _ = try await router.route(
                eventId: "inbox:card-1",
                importance: .adverse,
                title: "Heartbeat",
                body: "the loop failed",
                reason: "loop_failed"
            )
        }
        #expect(await recorder.phone.count == 1)

        // A CHANGED reason under the same id is a NEW fact.
        let second = try await router.route(
            eventId: "inbox:card-1",
            importance: .adverse,
            title: "Heartbeat",
            body: "the loop failed twice",
            reason: "loop_failed_twice"
        )
        #expect(second.suppressed == false)
        #expect(await recorder.phone.count == 2)

        // Suppression reports itself rather than pretending it delivered.
        let third = try await router.route(
            eventId: "inbox:card-1",
            importance: .adverse,
            title: "Heartbeat",
            body: "the loop failed twice",
            reason: "loop_failed_twice"
        )
        #expect(third.suppressed)
        #expect(third.receipt == nil)
        #expect(await recorder.phone.count == 2)
    }

    @Test("the ledger is durable across router instances")
    func ledgerSurvivesRestart() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()

        _ = try await makeRouter(root: root, recorder: recorder, lastActive: .ios).route(
            eventId: "pr_approved:owner/repo#7",
            importance: .informational,
            title: "PR approved",
            body: "the PR was approved"
        )
        // A fresh instance reads the persisted ledger, so a restart neither
        // re-pings nor forgets.
        _ = try await makeRouter(root: root, recorder: recorder, lastActive: .ios).route(
            eventId: "pr_approved:owner/repo#7",
            importance: .informational,
            title: "PR approved",
            body: "the PR was approved"
        )

        #expect(await recorder.phone.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("notify/attention_router.json").path))
    }

    @Test("delivery is the commit point — a failed send retries, it does not vanish")
    func failedDeliveryRetries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder(phoneFailures: 1)
        let router = makeRouter(root: root, recorder: recorder, lastActive: .ios)

        await #expect(throws: RouterTestError.self) {
            _ = try await router.route(
                eventId: "needs_user+xyz",
                importance: .ownerWaiting,
                title: "Agent needs you",
                body: "a decision is waiting"
            )
        }
        // The ledger was NOT committed, so the retry gets through.
        _ = try await router.route(
            eventId: "needs_user+xyz",
            importance: .ownerWaiting,
            title: "Agent needs you",
            body: "a decision is waiting"
        )
        #expect(await recorder.phone.count == 1)
    }

    @Test("a pinned tool call is a command, not an edge: repeats are not swallowed")
    func pinnedChannelSkipsTableAndLedger() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()
        // User is on Telegram, but `mobile_notify` names its own channel.
        let router = makeRouter(root: root, recorder: recorder, lastActive: .telegram)

        for _ in 0..<2 {
            let outcome = try await router.route(
                eventId: "mobile_notify:same",
                importance: .ownerWaiting,
                title: "Heads up",
                body: "same message twice",
                pinnedTo: .phone
            )
            #expect(outcome.delivery == .phone)
            #expect(outcome.receipt != nil)
        }
        #expect(await recorder.phone.count == 2)
        #expect(await recorder.telegram.isEmpty)
    }

    // MARK: - 3. The morning brief

    @Test("morning brief: one phone push, its card is the receipt, never a chat message")
    func morningBriefGoesToThePhoneOnce() async throws {
        // The clock trigger classifies informational...
        let brief = TriggerNotification(
            triggerName: "morning_brief",
            kind: "time",
            title: "Morning brief",
            body: "3 things today",
            screen: "inbox",
            source: "trigger:morning_brief",
            urgency: "normal",
            itemId: "brief-2026-09-01",
            item: .object(["id": .string("brief-2026-09-01")])
        )
        #expect(TriggerNotifierBinding.importance(for: brief) == .informational)

        // ...and informational is the phone from EVERY surface, including when
        // User's last turn was on Telegram or in the Mac chat window. The brief
        // is a notification, not a message into a thread (clause 6, User's call).
        for surface in [AttentionSurface.chat, .ios, .telegram] {
            #expect(AttentionRouter.delivery(importance: .informational, lastActive: surface) == .phone)
        }

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()
        let router = makeRouter(root: root, recorder: recorder, lastActive: .telegram)

        // Two evaluations of the same brief — one push. The card the binding
        // mirrors before this call is the durable receipt.
        for _ in 0..<2 {
            _ = try await router.route(
                eventId: "trigger:\(brief.itemId)",
                importance: TriggerNotifierBinding.importance(for: brief),
                title: brief.title,
                body: brief.body,
                userInfo: ["screen": brief.screen, "itemId": brief.itemId]
            )
        }
        let phone = await recorder.phone
        #expect(phone.count == 1)
        #expect(phone[0].title == "Morning brief")
        #expect(phone[0].userInfo["itemId"] == "brief-2026-09-01")
        #expect(await recorder.telegram.isEmpty, "the brief must never be routed into a chat thread")
    }

    @Test("an urgent event trigger still follows User; a quiet one does not")
    func eventTriggerClassification() {
        func note(kind: String, urgency: String) -> TriggerNotification {
            TriggerNotification(
                triggerName: "mission_followup", kind: kind, title: "t", body: "b",
                screen: "inbox", source: "trigger:mission_followup", urgency: urgency
            )
        }
        #expect(TriggerNotifierBinding.importance(for: note(kind: "mission_complete", urgency: "high")) == .ownerWaiting)
        #expect(TriggerNotifierBinding.importance(for: note(kind: "mission_complete", urgency: "normal")) == .informational)
        // A clock trigger is informational whatever its urgency.
        #expect(TriggerNotifierBinding.importance(for: note(kind: "time", urgency: "high")) == .informational)
    }

    // MARK: - 4. Delegation success never pushes

    @Test("a successful delegation is a routine success and never knocks")
    func delegationSuccessNeverPushes() async throws {
        // The loop's own severity for a clean success is the input...
        #expect(DelegationOutcome.succeeded.severity == "info")
        #expect(AttentionImportance.fromInboxSeverity(DelegationOutcome.succeeded.severity) == .routineSuccess)

        // ...and every adverse delegation outcome still reaches User.
        for outcome in DelegationOutcome.allCases where outcome != .succeeded {
            #expect(AttentionImportance.fromInboxSeverity(outcome.severity) == .adverse,
                    "\(outcome.rawValue) must still knock")
        }

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()

        // From every surface: nothing goes out.
        for surface in [AttentionSurface.chat, .ios, .telegram] {
            let router = makeRouter(root: root, recorder: recorder, lastActive: surface)
            let result = try await router.route(
                eventId: "delegation-outcome:codex:job-1",
                importance: .routineSuccess,
                title: "Codex finished",
                body: "Codex finished the sweep"
            )
            #expect(result.delivery == .none)
            #expect(result.suppressed == false)
        }
        #expect(await recorder.phone.isEmpty)
        #expect(await recorder.telegram.isEmpty)
        // A suppressed routine success writes no ledger row either — there is
        // nothing to dedupe against.
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("notify/attention_router.json").path))
    }

    @Test("inbox severities map onto classes without silently promoting noise")
    func severityMapping() {
        #expect(AttentionImportance.fromInboxSeverity("critical") == .adverse)
        #expect(AttentionImportance.fromInboxSeverity("actionable") == .adverse)
        #expect(AttentionImportance.fromInboxSeverity("important") == .informational)
        #expect(AttentionImportance.fromInboxSeverity("info") == .routineSuccess)
        #expect(AttentionImportance.fromInboxSeverity("  ACTIONABLE ") == .adverse)
        // An unrecognized severity is not a reason to interrupt User.
        #expect(AttentionImportance.fromInboxSeverity("banana") == .routineSuccess)
    }

    // MARK: - Last-active surface

    @Test("last-active surface comes from the newest turn trace, and goes stale")
    func lastActiveSurfaceRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        func row(_ surface: String, _ minutesAgo: Int) -> String {
            let ts = fmt.string(from: now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
            return #"{"turnId":"t","ts":"\#(ts)","kind":"turn.terminal","surface":"\#(surface)","payload":{}}"#
        }

        try ([row("chat", 90), row("telegram", 20), row("workshop", 5)])
            .joined(separator: "\n")
            .write(to: dir.appendingPathComponent("2026-09-01.jsonl"), atomically: true, encoding: .utf8)

        // `workshop` is Agent working, not User present — the newest HUMAN
        // surface wins.
        #expect(LastActiveSurfaceReader.lastActiveSurface(dataRoot: root, now: now) == .telegram)

        // Beyond the freshness window it is a guess about yesterday, so the
        // reader says "unknown" and the router falls back to the phone.
        #expect(LastActiveSurfaceReader.lastActiveSurface(
            dataRoot: root, now: now, freshness: 60) == nil)
        #expect(AttentionRouter.delivery(importance: .ownerWaiting, lastActive: nil) == .phone)

        // No feed at all is unknown, not a crash.
        let bare = try makeRoot()
        defer { try? FileManager.default.removeItem(at: bare) }
        #expect(LastActiveSurfaceReader.lastActiveSurface(dataRoot: bare, now: now) == nil)
    }

    // MARK: - The ledger file itself (2026-09-01 review)

    private func ledgerURL(_ root: URL) -> URL {
        root.appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("attention_router.json")
    }

    private func writeLedgerBytes(_ root: URL, _ data: Data) throws {
        let url = ledgerURL(root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    @Test("a corrupt ledger is preserved aside with a receipt, never silently reset")
    func corruptLedgerSelfHeals() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()

        // Bytes that decode to nothing. Before the fix these became `.empty`
        // through a `try?` and were overwritten by the very next delivery — the
        // dedupe state reset with no trace of what had already been sent.
        let damaged = Data(#"{"reasons":{"a":"b"},"order":["#.utf8)
        try writeLedgerBytes(root, damaged)

        let router = makeRouter(root: root, recorder: recorder, lastActive: .ios)
        _ = try await router.route(
            eventId: "needs_user+after-corruption",
            importance: .ownerWaiting,
            title: "Agent needs you",
            body: "a decision is waiting"
        )
        // The router recovered rather than wedging.
        #expect(await recorder.phone.count == 1)

        // The damaged bytes are on disk, byte-for-byte, under a
        // `.quarantined-<ts>` name — not deleted, not overwritten.
        let notify = root.appendingPathComponent("notify", isDirectory: true)
        let aside = try FileManager.default
            .contentsOfDirectory(atPath: notify.path)
            .filter { $0.hasPrefix("attention_router.json.quarantined-") }
        #expect(aside.count == 1)
        let preserved = try #require(aside.first)
        let preservedBytes = try Data(contentsOf: notify.appendingPathComponent(preserved))
        #expect(preservedBytes == damaged)

        // And the reset is recorded, in the same repair-receipt shape the other
        // path-owned stores emit.
        let receiptURL = notify.appendingPathComponent("attention-router-quarantine.jsonl")
        let receiptText = try String(contentsOf: receiptURL, encoding: .utf8)
        let line = try #require(receiptText.split(separator: "\n").first.map(String.init))
        let decoded = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let receipt = try #require(decoded as? [String: Any])
        #expect(receipt["event"] as? String == "attention_router_ledger_quarantined")
        #expect((receipt["quarantinedPath"] as? String)?.hasSuffix(preserved) == true)
        #expect((receipt["ledgerPath"] as? String)?.hasSuffix("attention_router.json") == true)
        #expect(receipt["byteCount"] as? Int == damaged.count)
        #expect((receipt["reason"] as? String)?.isEmpty == false)

        // The fresh ledger is a working ledger: the same event does not knock
        // twice from here on.
        let repeated = try await router.route(
            eventId: "needs_user+after-corruption",
            importance: .ownerWaiting,
            title: "Agent needs you",
            body: "a decision is waiting"
        )
        #expect(repeated.suppressed)
        #expect(await recorder.phone.count == 1)
    }

    @Test("the ledger is capped in bytes, not just in entry count")
    func ledgerByteCapIsEnforced() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()

        // A well-formed ledger that the COUNT cap alone considers legal: 500
        // entries, exactly `ledgerLimit`, but with keys long enough to make the
        // file megabytes. This is what a foreign writer or a changed key
        // derivation produces, and the count cap can do nothing about it.
        var reasons: [String: String] = [:]
        var order: [String] = []
        for index in 0..<AttentionRouter.ledgerLimit {
            let key = String(repeating: "x", count: 2048) + "-\(index)"
            reasons[key] = "digest-\(index)"
            order.append(key)
        }
        let seeded = try JSONSerialization.data(
            withJSONObject: ["reasons": reasons, "order": order])
        try writeLedgerBytes(root, seeded)
        #expect(seeded.count > AttentionRouter.ledgerMaxBytes)

        let router = makeRouter(root: root, recorder: recorder, lastActive: .ios)
        _ = try await router.route(
            eventId: "pr_approved:owner/repo#9",
            importance: .informational,
            title: "PR approved",
            body: "the PR was approved"
        )

        let written = try Data(contentsOf: ledgerURL(root))
        #expect(written.count <= AttentionRouter.ledgerMaxBytes)

        // Eviction is oldest-first, so the entry this pass just committed —
        // the whole point of the ledger — survives the trim.
        let repeated = try await router.route(
            eventId: "pr_approved:owner/repo#9",
            importance: .informational,
            title: "PR approved",
            body: "the PR was approved"
        )
        #expect(repeated.suppressed)
        #expect(await recorder.phone.count == 1)
    }

    @Test("a readable ledger is never quarantined")
    func healthyLedgerIsLeftAlone() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SendRecorder()

        _ = try await makeRouter(root: root, recorder: recorder, lastActive: .ios).route(
            eventId: "needs_user+healthy",
            importance: .ownerWaiting,
            title: "Agent needs you",
            body: "a decision is waiting"
        )
        // A fresh instance re-reads the file it wrote; nothing is moved aside.
        _ = try await makeRouter(root: root, recorder: recorder, lastActive: .ios).route(
            eventId: "needs_user+healthy",
            importance: .ownerWaiting,
            title: "Agent needs you",
            body: "a decision is waiting"
        )
        let notify = root.appendingPathComponent("notify", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: notify.path)
        #expect(entries == ["attention_router.json"])
        #expect(await recorder.phone.count == 1)
    }
}
