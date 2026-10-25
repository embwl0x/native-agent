import ApprovalInbox
import ChatTurnRuntime
import ChatTurnContracts
import AgentWorkspace
import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import TelegramBot
import DeviceSync
import Experiences
// Blueprint: | `AttentionRouter.swift` | `AttentionRouter` actor; `delivery`, `allowed`, `releaseHeld` retain notification destinations and routing metadata through quiet hours; all sends, including pinned commands, stay retained until settlement; terminal shutdown closes new admission and accepted sends finish without an unbounded join |

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
public enum AttentionImportance: String, Sendable, CaseIterable, Codable {
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
    /// The result of explicitly requested work, from any ingress.
    case requestedResult = "requested_result"

    /// Map an inbox-card severity onto a class. The existing severity
    /// vocabulary is the closest thing the codebase already had to an
    /// importance class, so the notification-inbox sites keep their exact
    /// current gate and gain routing on top of it.
    public static func fromInboxSeverity(_ severity: String) -> AttentionImportance {
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
public enum AttentionSurface: String, Sendable, CaseIterable, Codable {
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
public enum AttentionDelivery: String, Sendable, Equatable, Codable {
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
public struct AttentionOrigin: Sendable, Equatable, Codable {
    public let surface: AttentionSurface
    /// The conversation on that surface, when there is one. Carried into the
    /// push payload so a tap lands on the thought's own conversation instead of
    /// a generic screen.
    public let sessionId: String?
    /// The chat/channel to answer into, and the topic/thread within it.
    public let destinationId: String?
    public let threadId: String?

    public init(
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
    public init?(replyRoute: ChatToolSessionContext.ReplyRoute?, sessionId: String? = nil) {
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

public struct AttentionOutcome: Sendable {
    /// What the routing table chose. `.none` means the class does not knock.
    public let delivery: AttentionDelivery
    /// The phone receipt, when a phone push actually went out.
    public let receipt: MobileNotificationDeliveryReceipt?
    /// True when the routing said knock but the ledger had already delivered
    /// this exact event for this exact reason.
    public let suppressed: Bool
    /// True when the routing said knock and the user's declared quiet hours
    /// said not now. A DISTINCT fact from `suppressed`, and observable rather
    /// than merely documented: the ledger was left UNTOUCHED, so the same fact
    /// can still reach him once the window closes.
    public let deferredForQuietHours: Bool
    /// Her resident wake's knock in quiet hours: kept in the inbox, sent when they end.
    public var heldForResidentWake = false
    /// The knock's own identity (its event and the reason that made it a
    /// distinct knock): the event id the phone signs its receipt with.
    public internal(set) var knock: String?

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
    /// `suppressed` (the ledger already delivered this). Which classes see it
    /// is `AttentionRouter.honorsQuietHours` — the class decides, not the site.
    static let quietHours = AttentionOutcome(
        delivery: .none, receipt: nil, suppressed: false, deferredForQuietHours: true)

    /// What actually became of the knock. ONE projection, computed from the
    /// facts this outcome already holds, so every caller says the same thing
    /// about the same routing result instead of inferring delivery from the
    /// absence of a failure. Saving the card is a SEPARATE fact and is not
    /// represented here.
    public enum Delivery: String, Sendable, Equatable {
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
        public var reachedAChannel: Bool { self == .accepted || self == .queued }
    }

    public var deliveryProjection: Delivery {
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
    public func requireReceipt() throws -> MobileNotificationDeliveryReceipt {
        if heldForResidentWake {
            throw NSError(domain: "AttentionRouter", code: -503, userInfo: [NSLocalizedDescriptionKey:
                "Held, not sent: the person's quiet hours are on. It waits in the inbox and goes to his phone when they end."])
        }
        guard let receipt else {
            throw NSError(domain: "AttentionRouter", code: -503, userInfo: [
                NSLocalizedDescriptionKey:
                    "notification routed to \(delivery.rawValue); no paired-device receipt exists",
            ])
        }
        return receipt
    }
}

public actor AttentionRouter {
    public typealias PhoneSender = @Sendable (
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

    // MARK: - The routing table
    //
    // The whole policy, as a pure function. No I/O, no state — so the table is
    // testable per class × surface without touching a data root.

    public static func delivery(
        importance: AttentionImportance,
        origin: AttentionOrigin? = nil
    ) -> AttentionDelivery {
        allowed(policy(importance: importance, origin: origin))
    }

    /// The person's channel switches, applied to whatever the table chose.
    ///
    /// A channel that is switched off is NOT quietly re-routed to another one:
    /// being told on the phone instead of Telegram is a different thing from
    /// being told, and silently upgrading the interruption is exactly what this
    /// router exists to prevent. Off means this way out is not used; the
    /// durable card in the app is still written either way.
    public static func allowed(
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
    /// routing rule stays a pure function of importance and origin.
    public static func policy(
        importance: AttentionImportance,
        origin: AttentionOrigin? = nil
    ) -> AttentionDelivery {
        switch importance {
        case .routineSuccess:
            // Already in the rollup. Interrupting User to say a thing worked is
            // the exact noise this router exists to remove.
            return .none
        case .requestedResult:
            return .phone
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
            // Otherwise his phone, with Reply (User, 2026-10-07). Guessing his
            // door from the newest turn trace sent every knock to Telegram
            // once he had answered there, and the phone never heard her again.
            return .phone
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
    public static func wakesTheDevice(_ importance: AttentionImportance) -> Bool {
        importance == .adverse
    }

    /// The corollary: anything that does not wake the device is held during the
    /// person's declared quiet hours. This used to be a per-site opt-in
    /// (`respectsQuietHours:`) that defaulted to OFF, so every site that had
    /// never thought about the clock interrupted at 3am and the one site that
    /// had was the exception. The switch is deleted; the class decides.
    ///
    /// `route` persists held delivery in the inbox; `releaseHeld` sends it after
    /// quiet hours and clears only destinations whose transport accepted it.
    public static func honorsQuietHours(_ importance: AttentionImportance) -> Bool {
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
    public static func inQuietHours(
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
    public static func holdsMacBanner(
        _ importance: AttentionImportance,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        at date: Date = Date()
    ) -> Bool {
        honorsQuietHours(importance) && inQuietHours(at: date, dataRoot: dataRoot)
    }

    // MARK: - Held for quiet hours

    /// Her resident wake runs in the person's quiet hours too (Agent 10-02);
    /// anything it would put in front of him waits until they end. True for
    /// a knock from that turn (or naming its session) while the window is open.
    public static func holdsResidentWake(session: String?, dataRoot: URL, at date: Date = Date()) -> Bool {
        TurnQuietHoursWindow.holdsResidentWake(session: session ?? ChatToolSessionContext.verifiedSessionId, dataRoot: dataRoot, at: date)
    }

    public static func hasHeld(dataRoot: URL) async -> Bool {
        let rows = (try? await LiveNotificationInbox.live(dataRoot: dataRoot).rows()) ?? []
        return rows.contains { if case .object(let row) = $0 { row["held_delivery"] != nil } else { false } }
    }

    /// Once quiet hours end, clear only destinations whose transport accepted
    /// the knock. Failed sends and unavailable approval reads remain held.
    public static func releaseHeld(dataRoot: URL, router: AttentionRouter,
                                   banner: @Sendable (String, String, [String: String], String?) async -> Bool) async -> Int {
        guard !inQuietHours(at: Date(), dataRoot: dataRoot) else { return 0 }
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        var released = 0
        for case .object(let row) in (try? await inbox.rows()) ?? [] {
            guard case .array(let ways)? = row["held_delivery"], case .string(let id)? = row["id"] else { continue }
            let title = if case .string(let text)? = row["held_title"] ?? row["title"] { text } else { "" }
            let body = if case .string(let text)? = row["held_body"] ?? row["summary"] { text } else { "" }
            let userInfo: [String: String]
            do { userInfo = try row["held_user_info"].map { try JSONDecoder().decode([String: String].self, from: $0.serializedData(pretty: false)) } ?? [:] }
            catch { nativeLog("attention_router: held metadata unavailable: %@", error.localizedDescription); continue }
            // A card settled or an approval decided meanwhile is no longer news.
            let approval: String? = if case .string(let value)? = row["approval_id"] { value } else { nil }
            var live = row["status"] != .string("archived") && row["status"] != .string("dismissed")
            if live, let approval {
                do { live = try await SwiftNativeApprovalInbox(root: dataRoot).get(approval).status == "pending" }
                catch ApprovalInboxError.notFound { live = false }
                catch {
                    nativeLog("attention_router: held approval unavailable: %@", error.localizedDescription)
                    continue
                }
            }
            var remaining = live ? ways : []
            if live, ways.contains(.string("phone")) {
                do {
                    func retainedString(_ key: String) throws -> String? {
                        guard let value = row[key] else { return nil }
                        guard case .string(let text) = value else { throw CocoaError(.fileReadCorruptFile) }
                        return text
                    }
                    let eventID = try retainedString("held_event_id") ?? approval.map { "approval:\($0)" } ?? id
                    let reason = try retainedString("held_reason") ?? eventID
                    let importanceName = try retainedString("held_importance") ?? AttentionImportance.ownerWaiting.rawValue
                    let pinnedName = try retainedString("held_pinned_to")
                    let pinned = pinnedName.flatMap(AttentionDelivery.init(rawValue:))
                    guard let importance = AttentionImportance(rawValue: importanceName), pinnedName == nil || pinned != nil else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let origin = try row["held_origin"].map { try JSONDecoder().decode(AttentionOrigin.self, from: $0.serializedData(pretty: false)) }
                    let outcome = try await router.route(eventId: eventID, importance: importance, title: title, body: body,
                        reason: reason, userInfo: row["held_user_info"] != nil ? userInfo :
                            approval.map { ["screen": "approvals", "source": "approval", "approvalId": $0] } ?? ["screen": "inbox", "itemId": id],
                        origin: origin, pinnedTo: pinned)
                    if outcome.deliveryProjection.reachedAChannel || outcome.deliveryProjection == .previouslyHandled {
                        remaining.removeAll { $0 == .string("phone") }
                    }
                } catch { nativeLog("attention_router: held push failed: %@", error.localizedDescription) }
            }
            if live, ways.contains(.string("mac")) {
                let sound: String? = if case .string(let value)? = row["held_sound_name"] { value } else { nil }
                do {
                    if try await inbox.patch(id: id, unlessPresent: "held_mac_dispatch", ["held_mac_dispatch": .string("sent_unconfirmed")]) {
                        if await banner(title, body, userInfo, sound) {
                            remaining.removeAll { $0 == .string("mac") }
                            _ = try await inbox.patch(id: id, ["held_mac_dispatch": .string("completed")])
                        } else {
                            _ = try await inbox.patch(id: id, ["held_mac_dispatch": .null])
                            nativeLog("attention_router: held banner failed")
                        }
                    } else if row["held_mac_dispatch"] == .string("completed") {
                        remaining.removeAll { $0 == .string("mac") }
                    }
                } catch { nativeLog("attention_router: held banner dispatch remains unconfirmed: %@", error.localizedDescription) }
            }
            guard remaining != ways else { continue }
            do {
                guard try await inbox.patch(id: id, ["held_delivery": remaining.isEmpty ? .null : .array(remaining)]) else { continue }
                if remaining.isEmpty { released += 1 }
            } catch { nativeLog("attention_router: could not acknowledge held knock: %@", error.localizedDescription) }
        }
        return released
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

    /// What the ledger says was delivered, event id → reason digest. The `app`
    /// door diffs it around one action to report the knocks that action set off.
    /// Delivered knocks by key: none when the ledger was never written; a
    /// ledger that does not read or decode throws, never reads as none.
    public static func deliveredKnocks(dataRoot: URL) throws -> [String: String] {
        let url = dataRoot.appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("attention_router.json")
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return [:] }
        return try JSONDecoder().decode(State.self, from: data).reasons
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

    private let dataRoot: URL
    private let phoneSender: PhoneSender
    private let telegramSender: TelegramSender
    private let conversationSender: ConversationSender
    private var cached: State?
    private var inFlight: [String: Task<AttentionOutcome, Error>] = [:]
    private var stopped = false
    var resultScanInFlight = false
    var settledResultFiles: [URL: Date] = [:]
    var resultRetryOffset = 0

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        delivery: AttentionDeliveryPorts
    ) {
        self.dataRoot = dataRoot
        self.phoneSender = delivery.phone
        self.telegramSender = { text in
            // Preserve the singleton's per-send lookup of the owner destination.
            try await Self.sendToOwnerTelegram(
                text, dataRoot: PersistenceCore.defaultDataRoot(), send: delivery.telegram)
        }
        self.conversationSender = { origin, text in
            try await Self.sendToOriginatingConversation(
                origin, text, dataRoot: dataRoot, delivery: delivery)
        }
    }

    /// Close future admission without cancelling an accepted knock. Every send,
    /// including a pinned command, stays retained until its transport exits and
    /// its real outcome settles. Shutdown never joins an unresponsive transport.
    public func shutdown() {
        stopped = true
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
    public func route(
        eventId: String,
        importance: AttentionImportance,
        title: String,
        body: String,
        reason: String? = nil,
        userInfo: [String: String] = [:],
        origin: AttentionOrigin? = nil,
        pinnedTo: AttentionDelivery? = nil,
        postMacBanner: (@Sendable () async -> Void)? = nil,
        at date: Date = Date()
    ) async throws -> AttentionOutcome {
        guard !stopped else { throw CancellationError() }
        // Only the caller's own origin names a conversation. The newest turn
        // trace used to fill one in, and answering into "whatever
        // conversation was newest" put a knock into an unrelated thread.
        // The person's channel switches apply to a PINNED delivery too. A
        // pinned call skips the routing table because the tool's name is its
        // channel contract — but "don't use my phone" is not a routing opinion
        // to be overridden by a tool name, it is the person saying that way out
        // is closed.
        let delivery = Self.allowed(
            pinnedTo ?? Self.policy(importance: importance, origin: origin),
            origin: origin
        )
        guard delivery != .none || postMacBanner != nil else { return .routineSuccess }
        // Her resident wake runs in his quiet hours; what it would put in
        // front of him, pinned or not, waits in the inbox for them to end.
        let quietHours = TurnQuietHoursWindow.read(dataRoot: dataRoot)
        let quietNow = quietHours?.contains(hour: Calendar.current.component(.hour, from: date)) == true
        let residentHeld = ChatToolSessionContext.verifiedSessionId == ResidentWake.session && quietNow
        if residentHeld || (pinnedTo == nil && Self.honorsQuietHours(importance) && quietNow) {
            var fields: [String: JSONValue] = ["held_event_id": .string(eventId), "held_importance": .string(importance.rawValue),
                "held_reason": .string(reason ?? body), "held_user_info": .object(userInfo.mapValues(JSONValue.string))]
            if let origin { fields["held_origin"] = try JSONValue.parse(JSONEncoder().encode(origin)) }
            if let pinnedTo { fields["held_pinned_to"] = .string(pinnedTo.rawValue) }
            let identity = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo, fallback: eventId)
            let id = pinnedTo == nil ? "held:" + Self.stableDigest(identity + ":" + (reason ?? body)) : "held:" + UUID().uuidString.lowercased()
            let ways = (delivery == .none ? [] : ["phone"]) + (postMacBanner == nil ? [] : ["mac"])
            try await LiveNotificationInbox.hold(dataRoot: dataRoot, title: title, body: body, ways: ways, approvalID: userInfo["approvalId"], id: id, fields: fields)
            var held = AttentionOutcome.quietHours
            held.heldForResidentWake = residentHeld
            return held
        }
        await postMacBanner?()
        guard !stopped else { throw CancellationError() }
        guard delivery != .none else { return .routineSuccess }

        // The device-event id already exists and is what the APNS collapse id
        // and the iCloud notification id are built from. Reuse it so the ledger
        // dedupes on the SAME identity the delivery layer does, instead of
        // inventing a second one that can disagree with it.
        let ledgerKey = NativeAgentDeviceEventIdentity.notification(
            userInfo: userInfo, fallback: eventId
        )
        let digest = Self.stableDigest(reason ?? body)
        // One knock's identity: its event plus the reason that made it a new
        // knock (a pinned call is its own each time). It rides the envelope
        // as the device event id, so the phone's receipt names exactly it.
        let knockID = Self.knockIdentity(ledgerKey, pinnedTo == nil ? digest : UUID().uuidString.lowercased())
        if pinnedTo == nil, try await load().reasons[ledgerKey] == digest {
            var handled = AttentionOutcome(delivery: delivery, receipt: nil, suppressed: true)
            handled.knock = knockID
            return handled
        }
        guard !stopped else { throw CancellationError() }
        let reservation = pinnedTo == nil ? "\(ledgerKey):\(digest)" : UUID().uuidString
        if pinnedTo == nil, let existing = inFlight[reservation] {
            return try await existing.value
        }

        let send = Task<AttentionOutcome, Error> {
            var enriched = userInfo
            enriched["eventId"] = knockID
            enriched["importance"] = importance.rawValue
            enriched["routedTo"] = delivery.rawValue
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

            // The knock is owed to him before any door is tried and stays
            // owed, with each failure's cause, until its destination takes it:
            // a caller that only logs the throw can no longer drop it. The
            // chosen door's failure is never a quiet trip through another one,
            // and a throw leaves the ledger untouched.
            let owed = "knock:" + knockID
            Self.owe(dataRoot, owed, door: delivery, event: knockID, words: title + "\n" + body)
            var receipt: MobileNotificationDeliveryReceipt?
            do {
                if delivery == .conversation, let origin {
                    try await conversationSender(origin, Self.telegramText(title: title, body: body))
                } else if delivery == .telegram {
                    try await telegramSender(Self.telegramText(title: title, body: body))
                } else {
                    receipt = try await phoneSender(title, body, enriched)
                }
            } catch {
                Self.knock(dataRoot, owed, [.claim(.init(claim: "failed: " + delivery.rawValue + " did not take it: " + error.localizedDescription, evidence: []))])
                throw error
            }
            // A chat's send returning is that chat holding it; a phone knock
            // settles on the phone's own signed receipt (`settleKnocks`).
            if delivery != .phone { Self.knock(dataRoot, owed, [.obligation(key: "deliver", phase: .accepted)]) }

            // Delivery is the commit point. A throw above leaves the ledger
            // untouched so the next pass retries rather than losing the knock.
            if pinnedTo == nil {
                // Other deliveries can finish while this one awaits a sender.
                // Merge into their latest committed ledger, not the old snapshot.
                var state = try await load()
                state.remember(eventId: ledgerKey, digest: digest, limit: Self.ledgerLimit)
                try persist(state)
            }
            var sent = AttentionOutcome(delivery: delivery, receipt: receipt, suppressed: false)
            sent.knock = knockID
            return sent
        }
        inFlight[reservation] = send
        defer { inFlight[reservation] = nil }
        return try await send.value
    }

    private static func owe(_ dataRoot: URL, _ id: String, door: AttentionDelivery, event: String, words: String) {
        let knock = Experience(id: id, kind: .message, face: .init(words: words, artifacts: []), addressedTo: ["person"],
            owes: ["deliver": .init(to: "person")],
            claims: ["door: " + door.rawValue, "event: " + event].map { .init(claim: $0, evidence: []) })
        ExperienceStore.record(dataRoot, id) { store in _ = try await store.begin(knock) }
    }

    private static func knock(_ dataRoot: URL, _ id: String, _ changes: [ExperienceStore.Change]) {
        ExperienceStore.record(dataRoot, id) { store in try await store.append(changes, to: id) }
    }

    /// Every owed knock whose event the phone has signed as arrived is settled.
    static func settleKnocks(confirmed: Set<String>, dataRoot: URL) {
        guard !confirmed.isEmpty else { return }
        ExperienceStore.record(dataRoot, "knock-receipts") { store in
            for owed in try await store.open() where owed.id.hasPrefix("knock:")
                && owed.owes["deliver"]?.phase.isSettled == false
                && owed.claims.contains(where: { $0.claim.hasPrefix("event: ") && confirmed.contains(String($0.claim.dropFirst(7))) }) {
                try await store.append([.obligation(key: "deliver", phase: .accepted)], to: owed.id)
            }
        }
    }

    /// Owner alerts require the configured single owner's bound private chat.
    private static func sendToOwnerTelegram(
        _ text: String, dataRoot: URL, send: AttentionDeliveryPorts.TelegramSender
    ) async throws {
        guard let config = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
              config.enabled, !config.botToken.isEmpty,
              config.allowedUserIds.count == 1,
              let chatId = config.allowedUserIds.first.flatMap({ Int(exactly: $0) }), chatId > 0,
              let sessionId = await TelegramSessionStore(dataRoot: dataRoot).boundSessionId(chatId: chatId),
              !sessionId.isEmpty
        else {
            throw NSError(domain: "AttentionRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No verified owner Telegram conversation to notify."
            ])
        }
        try await send(
            config.botToken, TelegramDestination(chatId: chatId), TelegramPollLoop.cleanedPlainText(text))
    }

    /// The default way back into an originating conversation: the SAME
    /// transports the completion router already answers turns on, given the
    /// same route. Nothing new is authorized here — if the turn could be
    /// answered, the follow-up about it can be too.
    private static func sendToOriginatingConversation(
        _ origin: AttentionOrigin,
        _ text: String,
        dataRoot: URL,
        delivery: AttentionDeliveryPorts
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
            try await delivery.telegram(
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
            try await delivery.slack(input, dataRoot)
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

    /// A canonical device event id, so the relay and the phone carry it as is.
    static func knockIdentity(_ event: String, _ version: String) -> String {
        SHA256.hash(data: Data((event + ":" + version).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// CHECKED read. A missing ledger is the only empty one. An unreadable
    /// or damaged ledger is not "nothing was delivered": routing throws its
    /// cause, so no event knocks again on invented history. Damaged bytes stay
    /// at their canonical path until repaired.
    private func load() async throws -> State {
        if let cached { return cached }
        let data: Data
        do { data = try Data(contentsOf: stateURL) }
        catch where MacSyncEngine.isNoSuchFileError(error) { return .empty }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            cached = state
            return state
        } catch {
            throw NSError(domain: "AttentionRouter", code: -2, userInfo: [NSLocalizedDescriptionKey:
                "AttentionRouter could not decode \(stateURL.path): \(error.localizedDescription). History is unknown; bytes remain in place. Nothing was sent.", NSUnderlyingErrorKey: error])
        }
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

    private func persist(_ state: State) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let capped = try Self.encodeWithinByteCap(state)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(capped.data, to: stateURL)
        cached = capped.state
    }
}
