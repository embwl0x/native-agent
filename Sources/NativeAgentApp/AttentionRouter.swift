import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentShared
import PersistenceCore
import TelegramBot

// MARK: - Attention router (sweep item 26, 2026-09-01)
//
// THE PROBLEM this closes: thirteen push sites all called ONE exit
// (`MacSyncEngine.sendNotificationToPairedDevices`) with no routing. Every
// knock went to the same place regardless of what it was or where User actually
// was — so 345 of 500 inbox rows were "Codex/Claude finished", 95 sat unread,
// and 26 morning briefs went unread back to Aug 11. The push was firing; it
// wasn't REACHING him.
//
// This is the one place that decides. Inputs:
//   1. an importance class — what KIND of fact this is, and
//   2. User's last-active surface — where he actually is, read from the newest
//      turn trace (every turn already stamps `surface`).
// Output: phone push, Telegram message, or nothing.
//
// NORTHSTAR clause 6 governs: "Delivery goes to User as a push he can ignore."
// A routine success is not a fact User is waiting on — it already rolls up into
// the informational rollup card, so it NEVER knocks. Owner-waiting and adverse
// facts always knock, at the surface he is on, with the phone as the fallback
// that is always reachable. The morning brief is informational and stays a
// PHONE PUSH (User's explicit decision) whose inbox card is the receipt — never
// a chat message into Agent's own context.
//
// SHAPE: generalized from `NeedsUserEdgeNotifier` — durable state under
// data/notify, edge-triggered (an event id knocks once), re-ping only on a NEW
// reason (a changed reason is a new fact), and delivery is the commit point (a
// failed send leaves the ledger untouched so the next pass retries instead of
// losing the only signal). This is a ROUTER the existing sites call, not a
// fourteenth call site.

/// What KIND of fact a notification carries. This, not the sending subsystem,
/// decides whether User is interrupted.
enum AttentionImportance: String, Sendable, CaseIterable {
    /// Agent is blocked on User, or is deliberately reaching for him (an
    /// approval, a needs-you edge, an explicitly invoked notify tool).
    case ownerWaiting = "owner_waiting"
    /// Something went wrong, stalled, or was lost. Bad news travels.
    case adverse
    /// A thing finished the way it was supposed to. Never knocks — the rollup
    /// card already carries it.
    case routineSuccess = "routine_success"
    /// News and scheduled deliveries (the morning brief). One phone push; the
    /// inbox card is the receipt.
    case informational

    /// Map an inbox-card severity onto a class. The existing severity
    /// vocabulary is the closest thing the codebase already had to an
    /// importance class, so the notification-inbox sites keep their exact
    /// current gate and gain routing on top of it.
    static func fromInboxSeverity(_ severity: String) -> AttentionImportance {
        switch severity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "critical", "actionable":
            return .adverse
        case "important":
            return .informational
        default:
            // "info" and anything unrecognized. An unknown severity is NOT a
            // reason to interrupt User.
            return .routineSuccess
        }
    }
}

/// Where User last was. Mirrors the `surface` value every turn trace stamps.
enum AttentionSurface: String, Sendable, CaseIterable {
    case chat
    case ios
    case telegram
}

/// The router's only outputs.
enum AttentionDelivery: String, Sendable, Equatable {
    case phone
    case telegram
    case none
}

struct AttentionOutcome: Sendable {
    /// What the routing table chose. `.none` means the class does not knock.
    let delivery: AttentionDelivery
    /// The phone receipt, when a phone push actually went out.
    let receipt: MobileNotificationDeliveryReceipt?
    /// True when the routing said knock but the ledger had already delivered
    /// this exact event for this exact reason.
    let suppressed: Bool
    /// True when the routing said knock and the user's declared quiet hours
    /// said not now. A DISTINCT fact from `suppressed`, and observable rather
    /// than merely documented: the ledger was left UNTOUCHED, so the same fact
    /// can still reach him once the window closes.
    let deferredForQuietHours: Bool

    init(
        delivery: AttentionDelivery,
        receipt: MobileNotificationDeliveryReceipt?,
        suppressed: Bool,
        deferredForQuietHours: Bool = false
    ) {
        self.delivery = delivery
        self.receipt = receipt
        self.suppressed = suppressed
        self.deferredForQuietHours = deferredForQuietHours
    }

    static let routineSuccess = AttentionOutcome(delivery: .none, receipt: nil, suppressed: false)

    /// The routing said knock, but the user's declared quiet hours say not now.
    /// Distinct from `routineSuccess` (the class never knocks) and from
    /// `suppressed` (the ledger already delivered this). Only sites that opt in
    /// with `respectsQuietHours` ever see this — an owner-waiting or adverse
    /// fact is not silenced by a clock.
    static let quietHours = AttentionOutcome(
        delivery: .none, receipt: nil, suppressed: false, deferredForQuietHours: true)

    /// For the phone-pinned tool sites, whose caller contract IS an APNS
    /// receipt. Fails loud rather than fabricating one — a receipt must record
    /// something that actually ran (NORTHSTAR clause 2).
    func requireReceipt() throws -> MobileNotificationDeliveryReceipt {
        guard let receipt else {
            throw NSError(domain: "AttentionRouter", code: -503, userInfo: [
                NSLocalizedDescriptionKey:
                    "notification routed to \(delivery.rawValue); no paired-device receipt exists",
            ])
        }
        return receipt
    }
}

actor AttentionRouter {
    static let shared = AttentionRouter()

    typealias PhoneSender = @Sendable (
        _ title: String,
        _ body: String,
        _ userInfo: [String: String]
    ) async throws -> MobileNotificationDeliveryReceipt

    typealias TelegramSender = @Sendable (_ text: String) async throws -> Void

    typealias SurfaceReader = @Sendable () async -> AttentionSurface?

    // MARK: - The routing table
    //
    // The whole policy, as a pure function. No I/O, no state — so the table is
    // testable per class × surface without touching a data root.

    /// - Parameter lastActive: User's last-active surface, or nil when it is
    ///   unknown or too stale to trust.
    static func delivery(
        importance: AttentionImportance,
        lastActive: AttentionSurface?
    ) -> AttentionDelivery {
        switch importance {
        case .routineSuccess:
            // Already in the rollup. Interrupting User to say a thing worked is
            // the exact noise this router exists to remove.
            return .none
        case .informational:
            // The morning brief and its kind: the phone, once. Not the surface
            // he happens to be on — an informational delivery is something he
            // reads when he chooses to, and its card is the durable receipt.
            return .phone
        case .ownerWaiting, .adverse:
            // Reach him where he is; the phone is the fallback that is always
            // reachable (and where an unknown or stale surface lands).
            switch lastActive {
            case .telegram:
                return .telegram
            case .ios, .chat, .none:
                return .phone
            }
        }
    }

    /// Is the user's declared quiet-hours window open right now?
    ///
    /// ONE definition of "is it quiet", shared with the turn clock: the window
    /// is read from `data/user_prefs.json` by `TurnQuietHoursWindow`, which
    /// already mirrors `SwiftNativeTriggerScheduler.inQuietHours` semantics
    /// deliberately — two different answers to that question is exactly the
    /// shape that makes an agent contradict itself. No window declared means no
    /// quiet hours, which means nothing is deferred.
    static func inQuietHours(
        at date: Date,
        dataRoot: URL,
        calendar: Calendar = .current
    ) -> Bool {
        guard let window = TurnQuietHoursWindow.read(dataRoot: dataRoot) else { return false }
        return window.contains(hour: calendar.component(.hour, from: date))
    }

    // MARK: - Durable dedupe ledger

    private struct State: Codable {
        /// Event id → digest of the reason it was last delivered under.
        var reasons: [String: String]
        /// Insertion order, oldest first. Bounds the ledger.
        var order: [String]

        static let empty = State(reasons: [:], order: [])

        mutating func remember(eventId: String, digest: String, limit: Int) {
            if reasons[eventId] == nil { order.append(eventId) }
            reasons[eventId] = digest
            if order.count > limit { dropOldest(order.count - limit) }
        }

        mutating func dropOldest(_ count: Int) {
            guard count > 0 else { return }
            let evicted = order.prefix(count)
            for old in evicted { reasons.removeValue(forKey: old) }
            order.removeFirst(evicted.count)
        }
    }

    /// Well above any live burst; the ledger is a dedupe window, not history.
    static let ledgerLimit = 500

    /// The SECOND half of the budget (2026-09-01 review, MEDIUM). `ledgerLimit`
    /// bounds the number of entries, never their SIZE. Today's keys happen to
    /// be bounded — `NativeAgentDeviceEventIdentity.notification` returns a
    /// 64-hex digest — so 500 entries is ~50 KB and this cap does not bind. It
    /// is the guarantee that survives what the count cap cannot cover: a key
    /// derivation that stops digesting, or a ledger written by another version
    /// / edited by hand, either of which makes 500 rows an unbounded file.
    /// Same belt-and-braces the shared JSONL cap helper gives every path-owned
    /// feed (`appendJSONLCapped`'s `maxBytes` beside its `maxLines`), enforced
    /// locally rather than through `jsonlPathOwnedCapPolicy` because this store
    /// is one JSON object, not an append-only feed: there is no line to trim,
    /// so the OLDEST ENTRIES are evicted until the encoding fits.
    static let ledgerMaxBytes = 128 * 1024

    /// Beyond this, a last-active surface is a guess about where User was
    /// yesterday, not where he is. Stale ⇒ the phone.
    static let surfaceFreshness: TimeInterval = 12 * 60 * 60

    private let dataRoot: URL
    private let phoneSender: PhoneSender
    private let telegramSender: TelegramSender
    private let surfaceReader: SurfaceReader
    private var cached: State?

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        phoneSender: @escaping PhoneSender = { title, body, userInfo in
            try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: title,
                body: body,
                userInfo: userInfo
            )
        },
        telegramSender: @escaping TelegramSender = { text in
            _ = try await makeTelegramBot().sendTestMessage(message: text, chatId: nil)
        },
        surfaceReader: SurfaceReader? = nil
    ) {
        self.dataRoot = dataRoot
        self.phoneSender = phoneSender
        self.telegramSender = telegramSender
        self.surfaceReader = surfaceReader ?? {
            LastActiveSurfaceReader.lastActiveSurface(dataRoot: dataRoot)
        }
    }

    private var stateURL: URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("attention_router.json")
    }

    // MARK: - The one entry point

    /// Route one attention event.
    ///
    /// - Parameters:
    ///   - eventId: FALLBACK identity for a payload that carries none. The
    ///     ledger key is the existing device-event identity
    ///     (`NativeAgentDeviceEventIdentity.notification`) whenever the site's
    ///     `userInfo` already carries one of its keys — so the ledger, the APNS
    ///     collapse id, and the iCloud notification id are one identity rather
    ///     than three. Idempotent per that id: the same event with the same
    ///     reason never knocks twice.
    ///   - reason: what makes this event what it is. A CHANGED reason under the
    ///     same id is a new fact and re-pings once. Defaults to the body.
    ///   - userInfo: the site's existing push payload, passed through verbatim.
    ///   - pinnedTo: for the handful of sites whose TOOL NAME is the channel
    ///     contract (`mobile.notify`, `mobile_notify`): an explicitly invoked
    ///     device action is a command, not an attention event to triage.
    ///     Rerouting it to Telegram, or swallowing a deliberate repeat, would
    ///     make the tool lie about what it did. Pinned calls skip the routing
    ///     table and the ledger; they keep the single exit and the class stamp.
    /// - Throws: sender errors, so a site that currently rethrows or logs keeps
    ///   doing exactly that. Suppression is not an error.
    @discardableResult
    func route(
        eventId: String,
        importance: AttentionImportance,
        title: String,
        body: String,
        reason: String? = nil,
        userInfo: [String: String] = [:],
        pinnedTo: AttentionDelivery? = nil,
        respectsQuietHours: Bool = false,
        at date: Date = Date()
    ) async throws -> AttentionOutcome {
        let lastActive = await surfaceReader()
        let delivery = pinnedTo ?? Self.delivery(importance: importance, lastActive: lastActive)
        guard delivery != .none else { return .routineSuccess }
        // OPT-IN, and default OFF so every existing site is byte-identical.
        // A knock Agent CHOSE to make (the shoulder tap) is hers to hold until
        // morning; a knock she was forced into by something going wrong is not.
        // The ledger is deliberately not written here: the fact is still true
        // when the window closes, and it should still be able to reach him.
        if respectsQuietHours, Self.inQuietHours(at: date, dataRoot: dataRoot) {
            return .quietHours
        }

        // The device-event id already exists and is what the APNS collapse id
        // and the iCloud notification id are built from. Reuse it so the ledger
        // dedupes on the SAME identity the delivery layer does, instead of
        // inventing a second one that can disagree with it.
        let ledgerKey = NativeAgentDeviceEventIdentity.notification(
            userInfo: userInfo, fallback: eventId
        )
        let digest = Self.stableDigest(reason ?? body)
        var state = await load()
        if pinnedTo == nil, state.reasons[ledgerKey] == digest {
            return AttentionOutcome(delivery: delivery, receipt: nil, suppressed: true)
        }

        var enriched = userInfo
        enriched["importance"] = importance.rawValue
        enriched["routedTo"] = delivery.rawValue
        if let lastActive { enriched["lastActiveSurface"] = lastActive.rawValue }

        var receipt: MobileNotificationDeliveryReceipt?
        var landedOn = delivery
        if delivery == .telegram {
            do {
                try await telegramSender(Self.telegramText(title: title, body: body))
            } catch {
                // The phone is the fallback, and it is the whole point of
                // having one: a Telegram outage must not swallow an
                // owner-waiting fact. Let a phone failure propagate.
                NSLog("attention_router: telegram send failed, falling back to phone: %@",
                      error.localizedDescription)
                enriched["routedTo"] = AttentionDelivery.phone.rawValue
                enriched["telegramFallback"] = "1"
                receipt = try await phoneSender(title, body, enriched)
                landedOn = .phone
            }
        } else {
            receipt = try await phoneSender(title, body, enriched)
        }

        // Delivery is the commit point. A throw above leaves the ledger
        // untouched so the next pass retries rather than losing the knock.
        if pinnedTo == nil {
            state.remember(eventId: ledgerKey, digest: digest, limit: Self.ledgerLimit)
            persist(state)
        }
        return AttentionOutcome(delivery: landedOn, receipt: receipt, suppressed: false)
    }

    static func telegramText(title: String, body: String) -> String {
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty || tail == head { return head }
        return "\(head)\n\n\(tail)"
    }

    nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// CHECKED decode (2026-09-01 review, MEDIUM). This used to be a `try?`
    /// pair, so a corrupt ledger silently became `.empty` and the very next
    /// delivery OVERWROTE it — the dedupe state was reset without a trace and
    /// every previously-delivered event could knock again, with the evidence of
    /// what was already sent destroyed. Now the damaged bytes are renamed
    /// aside, never deleted, a repair receipt records the loss, and the fresh
    /// ledger starts from a known-empty state.
    private func load() async -> State {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: stateURL) else { return .empty }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            cached = state
            return state
        } catch {
            await quarantineDamagedLedger(byteCount: data.count, error: error)
            return .empty
        }
    }

    /// Rename aside, NEVER delete — the same contract the builder-inbox
    /// self-heal (`SwiftToolDispatcher+AgentBridgeTools.quarantineBuilderInbox`)
    /// and the chat delivery receipts store use: a file that turns out to be
    /// recoverable is still on disk, and a human can read
    /// `attention_router.json.quarantined-<ts>` to see exactly which events had
    /// already been delivered. The receipt lands in a sibling
    /// `attention-router-quarantine.jsonl` so the reset is recorded rather than
    /// silent.
    private func quarantineDamagedLedger(byteCount: Int, error: Error) async {
        let fileManager = FileManager.default
        let stamp = String(Int(Date().timeIntervalSince1970))
        var aside = stateURL.appendingPathExtension("quarantined-\(stamp)")
        var collision = 1
        while fileManager.fileExists(atPath: aside.path) {
            aside = stateURL.appendingPathExtension("quarantined-\(stamp)-\(collision)")
            collision += 1
        }
        do {
            try fileManager.moveItem(at: stateURL, to: aside)
        } catch {
            // The bytes stayed put. The atomic write that follows runs in the
            // same directory, so it will fail for the same reason rather than
            // clobbering them — but say so out loud either way.
            NSLog("attention_router: damaged ledger could not be preserved aside: %@",
                  error.localizedDescription)
            return
        }
        NSLog("attention_router: damaged ledger self-healed; bytes preserved at %@",
              aside.lastPathComponent)
        let receipt: [String: JSONValue] = [
            "event": .string("attention_router_ledger_quarantined"),
            "quarantinedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "ledgerPath": .string(stateURL.path),
            "quarantinedPath": .string(aside.path),
            "reason": .string(
                "attention router dedupe ledger is malformed; original bytes preserved"),
            "byteCount": .int(Int64(byteCount)),
            "decodeError": .string(String(describing: error)),
        ]
        // Best effort: the bytes are already safe, and a receipt write failure
        // must not turn a recovered router back into a dead one.
        try? await SwiftNativePersistenceCore().appendJSONLDurable(
            .object(receipt),
            to: stateURL.deletingLastPathComponent()
                .appendingPathComponent("attention-router-quarantine.jsonl")
        )
    }

    /// Encode under BOTH budgets: `ledgerLimit` has already bounded the entry
    /// count; this evicts the OLDEST entries until the encoding fits
    /// `ledgerMaxBytes`. The newest entry is always kept, so a single
    /// pathological event id can never leave an empty ledger behind.
    private static func encodeWithinByteCap(
        _ state: State,
        maxBytes: Int = ledgerMaxBytes
    ) throws -> (state: State, data: Data) {
        var trimmed = state
        let encoder = JSONEncoder()
        var data = try encoder.encode(trimmed)
        while data.count > maxBytes, trimmed.order.count > 1 {
            trimmed.dropOldest(max(1, trimmed.order.count / 10))
            data = try encoder.encode(trimmed)
        }
        return (trimmed, data)
    }

    private func persist(_ state: State) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let capped = try Self.encodeWithinByteCap(state)
            try capped.data.write(to: stateURL, options: .atomic)
            // Do not advance the process cache until the durable state landed:
            // a duplicate knock after a persistence failure is safer than
            // permanently suppressing one. Cache what was actually WRITTEN, so
            // an entry the byte cap evicted is not still believed in memory.
            cached = capped.state
        } catch {
            NSLog("attention_router: state persistence failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - Last-active surface

/// Reads where User last was from the durable turn-trace feed.
///
/// Every turn already stamps `surface` on every trace row, so this needs no new
/// writer and no new state — it is a bounded TAIL read of the newest
/// `data/turn_traces/<day>.jsonl`. Only surfaces a human can actually be ON
/// count: `workshop` and `swarms` rows are Agent working, not User present.
enum LastActiveSurfaceReader {
    /// How much of the newest day file to look at. Trace rows are small; this
    /// covers hundreds of them and keeps a 9 MB day file off the hot path.
    static let tailBytes = 256 * 1024

    static func lastActiveSurface(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        now: Date = Date(),
        freshness: TimeInterval = AttentionRouter.surfaceFreshness
    ) -> AttentionSurface? {
        let directory = dataRoot.appendingPathComponent("turn_traces", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .sorted(by: >)
        // Two files covers a freshness window that spans local midnight.
        for name in names.prefix(2) {
            if let hit = scan(directory.appendingPathComponent(name), now: now, freshness: freshness) {
                return hit
            }
        }
        return nil
    }

    private static func scan(_ url: URL, now: Date, freshness: TimeInterval) -> AttentionSurface? {
        guard let text = tail(of: url) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = obj["surface"] as? String,
                  let surface = AttentionSurface(rawValue: raw)
            else { continue }
            // A surface User used yesterday is not where he is now. Unknown
            // beats a confident wrong answer — the fallback is reachable.
            guard let ts = obj["ts"] as? String, let stamped = parse(ts) else { continue }
            guard now.timeIntervalSince(stamped) <= freshness else { return nil }
            return surface
        }
        return nil
    }

    private static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // A mid-line start is dropped by the first `split` boundary; a lossy
        // decode keeps a truncated multi-byte scalar from killing the read.
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
