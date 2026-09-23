import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentShared
import PersistenceCore
import SlackConnector
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
    /// 2026-09-13: the router knew three surfaces and Slack was not one of
    /// them, so a request born in a Slack thread could only come back as a
    /// phone push. A surface Agent already answers into is a surface she can
    /// knock on.
    case slack
}

/// The router's only outputs.
enum AttentionDelivery: String, Sendable, Equatable {
    case phone
    case telegram
    /// Back to the exact conversation the fact came from — the Telegram topic
    /// or Slack thread whose turn produced it. Not a fourth channel to
    /// configure: it is the channel the PERSON opened, reused.
    case conversation
    case none
}

/// The conversation a knock CAME FROM, carried so the knock can go back there.
///
/// Every field is already-authorized delivery identity minted by the turn that
/// produced the fact — the same `destinationId`/`threadId` pair the completion
/// router answers a turn on. It is NEVER derived from an inbound allowlist: an
/// allowlist says who may talk to Agent and says nothing whatsoever about where
/// she should knock, and treating the two as the same thing is how an agent
/// starts messaging people who never asked to hear from it.
struct AttentionOrigin: Sendable, Equatable {
    let surface: AttentionSurface
    /// The conversation on that surface, when there is one. Carried into the
    /// push payload so a tap lands on the thought's own conversation instead of
    /// a generic screen.
    let sessionId: String?
    /// The chat/channel to answer into, and the topic/thread within it.
    let destinationId: String?
    let threadId: String?

    init(
        surface: AttentionSurface,
        sessionId: String? = nil,
        destinationId: String? = nil,
        threadId: String? = nil
    ) {
        self.surface = surface
        self.sessionId = Self.trimmed(sessionId)
        self.destinationId = Self.trimmed(destinationId)
        self.threadId = Self.trimmed(threadId)
    }

    /// From the live reply route of the turn that is asking — the same value
    /// `codex_message`/`claude_message` already return on. Nil when the route
    /// names no surface this router can reach.
    init?(replyRoute: ChatToolSessionContext.ReplyRoute?, sessionId: String? = nil) {
        guard let replyRoute,
              let surface = AttentionSurface(rawValue: replyRoute.surface.lowercased())
        else { return nil }
        self.init(
            surface: surface,
            sessionId: sessionId,
            destinationId: replyRoute.destinationId,
            threadId: replyRoute.threadId
        )
    }

    /// Can this knock actually be returned to the conversation, or is naming
    /// the surface all we have? A Mac or iOS conversation has no way in from a
    /// background actor, so it is not a route — it is a label on the payload.
    var canReturnToConversation: Bool {
        guard let destinationId, !destinationId.isEmpty else { return false }
        switch surface {
        case .telegram, .slack: return true
        case .chat, .ios: return false
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
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
    /// True when the routing said knock, the transport was TRIED and failed,
    /// and no other way out was open. A failed transport is not suppression:
    /// nothing reached him and nothing was deduped, so a caller must be able to
    /// tell this apart from "already delivered". The failure is also written to
    /// `data/notify/attention-router-failures.jsonl`, and the ledger is left
    /// untouched so the next pass can still deliver the fact.
    let deliveryFailed: Bool

    init(
        delivery: AttentionDelivery,
        receipt: MobileNotificationDeliveryReceipt?,
        suppressed: Bool,
        deferredForQuietHours: Bool = false,
        deliveryFailed: Bool = false
    ) {
        self.delivery = delivery
        self.receipt = receipt
        self.suppressed = suppressed
        self.deferredForQuietHours = deferredForQuietHours
        self.deliveryFailed = deliveryFailed
    }

    static let routineSuccess = AttentionOutcome(delivery: .none, receipt: nil, suppressed: false)

    /// The routing said knock, but the user's declared quiet hours say not now.
    /// Distinct from `routineSuccess` (the class never knocks) and from
    /// `suppressed` (the ledger already delivered this). Which classes see it
    /// is `AttentionRouter.honorsQuietHours` — the class decides, not the site.
    static let quietHours = AttentionOutcome(
        delivery: .none, receipt: nil, suppressed: false, deferredForQuietHours: true)

    /// What actually became of the knock. ONE projection, computed from the
    /// facts this outcome already holds, so every caller says the same thing
    /// about the same routing result instead of inferring delivery from the
    /// absence of a failure. Saving the card is a SEPARATE fact and is not
    /// represented here.
    enum Delivery: String, Sendable, Equatable {
        /// The routing table chose no channel: nothing was attempted.
        case noChannel = "no_channel"
        /// Quiet hours. The ledger is untouched, so the fact can still land.
        case deferred
        /// The ledger had already delivered this exact fact for this reason.
        case previouslyHandled = "previously_handled"
        /// Handed to a transport that has not confirmed it reached the device.
        case queued
        /// A transport accepted it.
        case accepted
        /// Tried, and no channel took it.
        case failed

        /// True only when a transport took the knock. "Not failed" is not this.
        var reachedAChannel: Bool { self == .accepted || self == .queued }
    }

    var deliveryProjection: Delivery {
        if deliveryFailed { return .failed }
        if deferredForQuietHours { return .deferred }
        if suppressed { return .previouslyHandled }
        guard delivery != .none else { return .noChannel }
        guard let receipt else {
            // Telegram: the send returned without throwing and there is no
            // per-device receipt to read. That is acceptance by the transport.
            return .accepted
        }
        switch receipt.status {
        case "accepted": return .accepted
        case "queued": return .queued
        default: return .failed
        }
    }

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
    static let shared = AttentionRouter(telegramSender: { text in
        try await AttentionRouter.sendToOwnerTelegram(text, dataRoot: PersistenceCore.defaultDataRoot())
    })

    typealias PhoneSender = @Sendable (
        _ title: String,
        _ body: String,
        _ userInfo: [String: String]
    ) async throws -> MobileNotificationDeliveryReceipt

    typealias TelegramSender = @Sendable (_ text: String) async throws -> Void

    /// Answers into the conversation the fact came from, using the route that
    /// conversation already authorized.
    typealias ConversationSender = @Sendable (
        _ origin: AttentionOrigin,
        _ text: String
    ) async throws -> Void

    typealias SurfaceReader = @Sendable () async -> AttentionSurface?

    // MARK: - The routing table
    //
    // The whole policy, as a pure function. No I/O, no state — so the table is
    // testable per class × surface without touching a data root.

    /// - Parameter lastActive: User's last-active surface, or nil when it is
    ///   unknown or too stale to trust.
    static func delivery(
        importance: AttentionImportance,
        lastActive: AttentionSurface?,
        origin: AttentionOrigin? = nil
    ) -> AttentionDelivery {
        allowed(policy(importance: importance, lastActive: lastActive, origin: origin))
    }

    /// The person's channel switches, applied to whatever the table chose.
    ///
    /// A channel that is switched off is NOT quietly re-routed to another one:
    /// being told on the phone instead of Telegram is a different thing from
    /// being told, and silently upgrading the interruption is exactly what this
    /// router exists to prevent. Off means this way out is not used; the
    /// durable card in the app is still written either way.
    static func allowed(
        _ delivery: AttentionDelivery,
        origin: AttentionOrigin? = nil,
        defaults: UserDefaults = .standard
    ) -> AttentionDelivery {
        switch delivery {
        case .none: return .none
        case .phone: return NotificationChannelPreference.push(in: defaults) ? .phone : .none
        case .telegram: return NotificationChannelPreference.telegram(in: defaults) ? .telegram : .none
        case .conversation:
            // Returning a follow-up to the conversation the PERSON opened is
            // not a new way in, so it is not gated by a new switch. The one
            // switch that already exists still means what it says: "don't knock
            // me on Telegram" closes the Telegram route, origin or not.
            return origin?.surface == .telegram
                && !NotificationChannelPreference.telegram(in: defaults)
                ? .none : .conversation
        }
    }

    /// The whole table, untouched by the switches — kept separate so the
    /// routing rule stays a pure function of importance and surface.
    static func policy(
        importance: AttentionImportance,
        lastActive: AttentionSurface?,
        origin: AttentionOrigin? = nil
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
            // FIRST: the conversation this came from, when it is one she can
            // answer into. A request about a piece of work belongs beside the
            // work, in the thread where it was asked for — not as a decoupled
            // phone push that makes the person go and find what it was about.
            if let origin, origin.canReturnToConversation { return .conversation }
            // Otherwise reach him where he is; the phone is the fallback that
            // is always reachable (and where an unknown or stale surface, or a
            // Mac/iOS origin with no way back in, lands).
            switch lastActive {
            case .telegram:
                return .telegram
            case .ios, .chat, .slack, .none:
                return .phone
            }
        }
    }

    /// Does this KIND of fact earn a knock that breaks through a Focus mode —
    /// lighting the lock screen at 3am — or is it an ordinary notification that
    /// can wait its turn?
    ///
    /// ONE projection from the importance class, in the place that already
    /// decides everything else about a knock. Before this, every site that
    /// passed the attention-worthy gate stamped `urgency: urgent` itself, so an
    /// approval waiting for tomorrow and an imminent loss woke the phone
    /// identically and the word "urgent" meant nothing. Only `.adverse` wakes
    /// the device: something went wrong, stalled, or was lost, and waiting
    /// until morning is itself the consequence. An approval Agent is waiting on
    /// is a real knock and a real card — it is not a reason to wake someone.
    static func wakesTheDevice(_ importance: AttentionImportance) -> Bool {
        importance == .adverse
    }

    /// The corollary: anything that does not wake the device is held during the
    /// person's declared quiet hours. This used to be a per-site opt-in
    /// (`respectsQuietHours:`) that defaulted to OFF, so every site that had
    /// never thought about the clock interrupted at 3am and the one site that
    /// had was the exception. The switch is deleted; the class decides.
    ///
    /// Nothing is replayed when the window closes: the ledger is deliberately
    /// left untouched (see `route`), so a deferred fact can still reach him if
    /// it is still true, and the durable inbox card was written either way.
    static func honorsQuietHours(_ importance: AttentionImportance) -> Bool {
        !wakesTheDevice(importance)
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

    /// Should the Mac banner for this fact be held for quiet hours? The banner
    /// is a way out too, so it obeys the same class-decided window as the
    /// push. Read apart from `route`'s outcome because a switched-off phone
    /// returns before the quiet-hours check, and the phone switch does not
    /// govern the banner. The push ledger is NOT consulted: a delivered push
    /// says nothing about whether the banner posted.
    static func holdsMacBanner(
        _ importance: AttentionImportance,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        at date: Date = Date()
    ) -> Bool {
        honorsQuietHours(importance) && inQuietHours(at: date, dataRoot: dataRoot)
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
    private let conversationSender: ConversationSender
    private let surfaceReader: SurfaceReader
    private var cached: State?
    private var inFlight: [String: Task<AttentionOutcome, Error>] = [:]

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        phoneSender: @escaping PhoneSender = { title, body, userInfo in
            try await MacSyncEngine.shared.sendNotificationToPairedDevices(
                title: title,
                body: body,
                userInfo: userInfo
            )
        },
        telegramSender: @escaping TelegramSender = { _ in
            // The allowlist authorizes inbound chats; it does not identify an
            // owner notification destination. Until an explicit destination
            // (including its topic) is supplied, use the phone fallback.
            throw NSError(domain: "AttentionRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No owner Telegram notification destination is configured."
            ])
        },
        conversationSender: ConversationSender? = nil,
        surfaceReader: SurfaceReader? = nil
    ) {
        self.dataRoot = dataRoot
        self.phoneSender = phoneSender
        self.telegramSender = telegramSender
        self.conversationSender = conversationSender
            ?? { origin, text in
                try await AttentionRouter.sendToOriginatingConversation(
                    origin, text, dataRoot: dataRoot)
            }
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
        origin: AttentionOrigin? = nil,
        pinnedTo: AttentionDelivery? = nil,
        at date: Date = Date()
    ) async throws -> AttentionOutcome {
        let lastActive = await surfaceReader()
        // A caller that knows its origin wins. The newest turn trace still
        // fills in the PAYLOAD's origin stamp when the caller named none — but
        // it is NOT a route: answering into "whatever conversation was newest"
        // put a trigger's title and body into an unrelated Slack channel or
        // Telegram group. Last-active information may pick a channel KIND
        // (below, via `lastActive`), never a conversation, so only an EXPLICIT
        // origin is allowed to choose `.conversation` delivery.
        let explicitOrigin = origin
        let origin = origin ?? LastActiveSurfaceReader.lastActiveOrigin(dataRoot: dataRoot)
        // The person's channel switches apply to a PINNED delivery too. A
        // pinned call skips the routing table because the tool's name is its
        // channel contract — but "don't use my phone" is not a routing opinion
        // to be overridden by a tool name, it is the person saying that way out
        // is closed.
        let delivery = Self.allowed(
            pinnedTo ?? Self.policy(
                importance: importance, lastActive: lastActive, origin: explicitOrigin),
            origin: explicitOrigin
        )
        guard delivery != .none else { return .routineSuccess }
        // A knock Agent CHOSE to make, and a request she is waiting on, are
        // hers to hold until morning; a knock she was forced into by something
        // going wrong is not. A PINNED call is exempt because it is not an
        // attention event to triage — it is an explicit device command whose
        // caller is owed a real receipt.
        // The ledger is deliberately not written here: the fact is still true
        // when the window closes, and it should still be able to reach him.
        if pinnedTo == nil, Self.honorsQuietHours(importance),
           Self.inQuietHours(at: date, dataRoot: dataRoot) {
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
        let state = await load()
        if pinnedTo == nil, state.reasons[ledgerKey] == digest {
            return AttentionOutcome(delivery: delivery, receipt: nil, suppressed: true)
        }
        let reservation = "\(ledgerKey):\(digest)"
        if pinnedTo == nil, let existing = inFlight[reservation] {
            return try await existing.value
        }

        let send = Task<AttentionOutcome, Error> {
            var enriched = userInfo
            enriched["importance"] = importance.rawValue
            enriched["routedTo"] = delivery.rawValue
            if let lastActive { enriched["lastActiveSurface"] = lastActive.rawValue }
            // Honest urgency, PROJECTED from the class instead of asserted by
            // the site. `urgency: urgent` is what the phone turns into a
            // time-sensitive delivery that pierces Sleep Focus, so a site is
            // not allowed to claim it for itself. A pinned call keeps whatever
            // urgency its caller named: the tool's name is its contract.
            if pinnedTo == nil {
                enriched["urgency"] = Self.wakesTheDevice(importance) ? "urgent" : "normal"
            }
            // The conversation this came from rides along whatever channel it
            // leaves on, so a tap opens the thought's own conversation rather
            // than a generic screen. Stamped even when the knock goes to the
            // phone: that is the case where the person most needs to be told
            // what it was about.
            if let origin {
                enriched["originSurface"] = origin.surface.rawValue
                if let sessionId = origin.sessionId { enriched["originSessionId"] = sessionId }
            }

            var receipt: MobileNotificationDeliveryReceipt?
            var landedOn = delivery
            if delivery == .conversation, let origin = explicitOrigin {
                do {
                    try await conversationSender(
                        origin, Self.telegramText(title: title, body: body))
                } catch {
                    // Same contract the Telegram exit has kept: a conversation
                    // that cannot be reached must not swallow the fact.
                    NSLog("attention_router: conversation send failed, falling back to phone: %@",
                          error.localizedDescription)
                    guard NotificationChannelPreference.push() else {
                        await self.recordDeliveryFailure(
                            eventId: ledgerKey, importance: importance,
                            title: title, body: body, error: error
                        )
                        return AttentionOutcome(
                            delivery: .none, receipt: nil, suppressed: false, deliveryFailed: true)
                    }
                    enriched["routedTo"] = AttentionDelivery.phone.rawValue
                    enriched["conversationFallback"] = "1"
                    receipt = try await phoneSender(title, body, enriched)
                    landedOn = .phone
                }
            } else if delivery == .telegram {
                do {
                    try await telegramSender(Self.telegramText(title: title, body: body))
                } catch {
                    // The phone is the fallback, and it is the whole point of
                    // having one: a Telegram outage must not swallow an
                    // owner-waiting fact. Let a phone failure propagate.
                    NSLog("attention_router: telegram send failed, falling back to phone: %@",
                          error.localizedDescription)
                    // ...unless the phone is a channel the person switched off,
                    // in which case there is no fallback to take.
                    guard NotificationChannelPreference.push() else {
                        // Telegram failed and the phone is switched off, so the
                        // fact reached nobody. Returning `suppressed` here told
                        // callers it was handled and left no trace at all; a
                        // failed transport is never suppression.
                        await self.recordDeliveryFailure(
                            eventId: ledgerKey, importance: importance,
                            title: title, body: body, error: error
                        )
                        return AttentionOutcome(
                            delivery: .none, receipt: nil, suppressed: false, deliveryFailed: true)
                    }
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
                // Other deliveries can finish while this one awaits a sender.
                // Merge into their latest committed ledger, not the old snapshot.
                var state = await load()
                state.remember(eventId: ledgerKey, digest: digest, limit: Self.ledgerLimit)
                persist(state)
            }
            return AttentionOutcome(delivery: landedOn, receipt: receipt, suppressed: false)
        }
        if pinnedTo == nil { inFlight[reservation] = send }
        defer {
            if pinnedTo == nil { inFlight[reservation] = nil }
        }
        return try await send.value
    }

    /// 2026-09-22: urgent alerts go to the single private (positive id) chat
    /// in telegram/session_map.json, on the bot's own send path. Zero or
    /// several private chats means no clear owner: throw, and the phone takes it.
    static func sendToOwnerTelegram(_ text: String, dataRoot: URL) async throws {
        let mapURL = dataRoot
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("session_map.json")
        var privateChats: [Int] = []
        if let data = try? Data(contentsOf: mapURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let chats = root["chats"] as? [String: Any] {
            privateChats = chats.keys.compactMap { Int($0) }.filter { $0 > 0 }
        }
        guard privateChats.count == 1, let chatId = privateChats.first,
              let config = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
              config.enabled, !config.botToken.isEmpty,
              config.allowedChatIds.contains(Int64(chatId)) || config.allowedUserIds.contains(Int64(chatId))
        else {
            throw NSError(domain: "AttentionRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No single private Telegram chat to notify."
            ])
        }
        try await TelegramPollLoop.defaultSendMessage(
            config.botToken, TelegramDestination(chatId: chatId), TelegramPollLoop.cleanedPlainText(text))
    }

    /// The default way back into an originating conversation: the SAME
    /// transports the completion router already answers turns on, given the
    /// same route. Nothing new is authorized here — if the turn could be
    /// answered, the follow-up about it can be too.
    static func sendToOriginatingConversation(
        _ origin: AttentionOrigin,
        _ text: String,
        dataRoot: URL
    ) async throws {
        guard let destinationId = origin.destinationId else {
            throw NSError(domain: "AttentionRouter", code: -412, userInfo: [
                NSLocalizedDescriptionKey: "origin names no conversation to answer into",
            ])
        }
        switch origin.surface {
        case .telegram:
            guard let config = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
                  config.enabled, !config.botToken.isEmpty else {
                throw NSError(domain: "AttentionRouter", code: -503, userInfo: [
                    NSLocalizedDescriptionKey: "Telegram is not configured",
                ])
            }
            guard let chatId = Int(destinationId) else {
                throw NSError(domain: "AttentionRouter", code: -400, userInfo: [
                    NSLocalizedDescriptionKey: "Telegram destination \(destinationId) is not a chat id",
                ])
            }
            // A thread id that is present but unparseable is a BROKEN route,
            // not permission to answer the whole supergroup — the completion
            // router learned this the hard way on 2026-09-06 and this exit
            // must not relearn it.
            var threadId: Int?
            if let rawThreadId = origin.threadId {
                guard let parsed = Int(rawThreadId) else {
                    throw NSError(domain: "AttentionRouter", code: -400, userInfo: [
                        NSLocalizedDescriptionKey:
                            "Telegram thread \(rawThreadId) is not a topic id",
                    ])
                }
                threadId = parsed
            }
            try await TelegramPollLoop.defaultSendMessage(
                config.botToken,
                TelegramDestination(chatId: chatId, threadId: threadId),
                TelegramPollLoop.cleanedPlainText(text)
            )
        case .slack:
            var input: [String: JSONValue] = [
                "channel": .string(destinationId),
                "text": .string(text),
            ]
            if let threadId = origin.threadId { input["thread_ts"] = .string(threadId) }
            _ = try await SlackConnectorActions.postMessage(input: input, dataRoot: dataRoot)
        case .chat, .ios:
            throw NSError(domain: "AttentionRouter", code: -412, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(origin.surface.rawValue) conversations have no inbound knock route",
            ])
        }
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

    /// The durable record of a knock that reached nobody, beside the router's
    /// own state and written the same way its quarantine receipt is. Best
    /// effort by design: a failed receipt write must not turn a reported
    /// failure into a thrown one, and the ledger is deliberately not advanced,
    /// so the next pass retries the delivery itself.
    private func recordDeliveryFailure(
        eventId: String,
        importance: AttentionImportance,
        title: String,
        body: String,
        error: Error
    ) async {
        NSLog("attention_router: delivery failed with no channel left, event=%@: %@",
              eventId, error.localizedDescription)
        let row: [String: JSONValue] = [
            "event": .string("attention_router_delivery_failed"),
            "failedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "eventId": .string(eventId),
            "importance": .string(importance.rawValue),
            "attempted": .string(AttentionDelivery.telegram.rawValue),
            "fallback": .string("phone channel switched off"),
            "title": .string(title),
            "body": .string(body),
            "error": .string(error.localizedDescription),
        ]
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? await SwiftNativePersistenceCore().appendJSONLDurable(
            .object(row),
            to: stateURL.deletingLastPathComponent()
                .appendingPathComponent("attention-router-failures.jsonl")
        )
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
        lastActiveOrigin(dataRoot: dataRoot, now: now, freshness: freshness)?.surface
    }

    /// The SAME row, read whole. Every trace row stamps `sessionId` beside
    /// `surface`; this reader used to take the surface and drop the session on
    /// the floor, which is why a follow-up could say WHERE he last was but
    /// never WHICH conversation it was about (2026-09-13).
    static func lastActiveOrigin(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        now: Date = Date(),
        freshness: TimeInterval = AttentionRouter.surfaceFreshness
    ) -> AttentionOrigin? {
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

    private static func scan(_ url: URL, now: Date, freshness: TimeInterval) -> AttentionOrigin? {
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
            // The trace row carries delivery identity for the non-local
            // surfaces the same way it carries the session; a row that has no
            // destination still names the conversation, which is what the
            // payload needs.
            return AttentionOrigin(
                surface: surface,
                sessionId: obj["sessionId"] as? String,
                destinationId: obj["destinationId"] as? String,
                threadId: obj["threadId"] as? String
            )
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
        UserDisplayFormatters.parseFoundationISOTimestamp(value)
    }
}
