import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import TelegramBot
import DeviceSync
import Experiences
import Transcripts
import ApprovalInbox
import AgentWorkspace
import CryptoKit
// Blueprint: | `AttentionRouter.swift` | `AttentionRouter` sole routing and send owner: origin-bound transports, retained accepted sends, independent card settlement, closed admission at shutdown |

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

    let dataRoot: URL
    private let phoneSender: PhoneSender
    private let telegramSender: TelegramSender
    private let conversationSender: ConversationSender
    var cached: State?
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
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        // Only the caller's own origin names a conversation.
        // The person's channel switches apply to a PINNED delivery too. A
        // pinned call skips the routing table because the tool's name is its
        // channel contract — but "don't use my phone" is not a routing opinion
        // to be overridden by a tool name, it is the person saying that way out
        // is closed.
        let delivery = Self.allowed(
            pinnedTo ?? Self.policy(importance: importance, origin: origin),
            origin: origin
        )
        // A card and its knock settle independently. Keep transport work on
        // the existing inbox row before trying it, so insertion is never the
        // only opportunity to reach him. The held-delivery owner retries it.
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        let cardID = userInfo["itemId"].flatMap { id in
            !id.isEmpty && (userInfo["source"] == "interaction" || userInfo["trigger"] != nil) ? id : nil
        }
        var fields: [String: JSONValue] = ["held_event_id": .string(eventId), "held_importance": .string(importance.rawValue),
            "held_reason": .string(reason ?? body), "held_user_info": .object(userInfo.mapValues(JSONValue.string))]
        if let pinnedTo { fields["held_pinned_to"] = .string(pinnedTo.rawValue) }
        if let origin { fields["held_origin"] = try JSONValue.parse(JSONEncoder().encode(origin)) }
        if let cardID {
            fields["held_delivery"] = .array([.string("phone")])
            fields["held_title"] = .string(title)
            fields["held_body"] = .string(body)
            try await inbox.patch(id: cardID, unlessPresent: "held_delivery", fields)
        }
        guard delivery != .none || postMacBanner != nil else { return .routineSuccess }
        // Her resident wake runs in his quiet hours; what it would put in
        // front of him, pinned or not, waits in the inbox for them to end.
        let quietHours = TurnQuietHoursWindow.read(dataRoot: dataRoot)
        let quietNow = quietHours?.contains(hour: Calendar.current.component(.hour, from: date)) == true
        let residentHeld = SessionConversation.kind(ChatToolSessionContext.verifiedSessionId, dataRoot: dataRoot)?.isOwnWork == true && quietNow
        if residentHeld || (pinnedTo == nil && Self.honorsQuietHours(importance) && quietNow) {
            let identity = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo, fallback: eventId)
            let id = pinnedTo == nil ? "held:" + Self.stableDigest(identity + ":" + (reason ?? body)) : "held:" + UUID().uuidString.lowercased()
            let ways = (delivery == .none ? [] : ["phone"]) + (postMacBanner == nil ? [] : ["mac"])
            if cardID == nil {
                try await LiveNotificationInbox.hold(dataRoot: dataRoot, title: title, body: body, ways: ways, approvalID: userInfo["approvalId"], id: id, fields: fields)
            }
            var held = AttentionOutcome.quietHours
            held.heldForResidentWake = residentHeld
            return held
        }
        try Task.checkCancellation()
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
        let deduplicates = pinnedTo == nil || cardID != nil
        // One knock's identity: its event plus the reason that made it a new
        // knock (a pinned call is its own each time). It rides the envelope
        // as the device event id, so the phone's receipt names exactly it.
        let knockID = Self.knockIdentity(ledgerKey, deduplicates ? digest : UUID().uuidString.lowercased())
        if deduplicates, try await load().reasons[ledgerKey] == digest {
            if let cardID { try await inbox.settleHeldDelivery(id: cardID, way: "phone") }
            var handled = AttentionOutcome(delivery: delivery, receipt: nil, suppressed: true)
            handled.knock = knockID
            return handled
        }
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let reservation = deduplicates ? "\(ledgerKey):\(digest)" : UUID().uuidString
        if deduplicates, let existing = inFlight[reservation] {
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
            var sent = AttentionOutcome(delivery: delivery, receipt: receipt, suppressed: false)
            sent.knock = knockID
            if sent.deliveryProjection.reachedAChannel, deduplicates {
                // Other deliveries can finish while this one awaits a sender.
                // Merge into their latest committed ledger, not the old snapshot.
                var state = try await load()
                state.remember(eventId: ledgerKey, digest: digest, limit: Self.ledgerLimit)
                try persist(state)
            }
            if sent.deliveryProjection.reachedAChannel, let cardID {
                try await inbox.settleHeldDelivery(id: cardID, way: "phone")
            }
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
            // An unparseable thread id fails the route; it never authorizes a supergroup reply.
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

}
