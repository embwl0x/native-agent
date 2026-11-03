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
// Blueprint: | `AttentionRouter.swift` | Notification admission and dispatch through immutable occurrences and attempt-matched ledger rows; origin-bound transports, channel preferences and retained settlement across shutdown |

public actor AttentionRouter {
    public typealias PhoneSender = @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt
    let dataRoot: URL
    let delivery: AttentionDeliveryPorts
    private var inFlight: [String: Task<AttentionOutcome, Error>] = [:]
    private var stopped = false
    var resultScanInFlight = false
    var settledResultFiles: [URL: Date] = [:]
    var resultRetryOffset = 0

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot(), delivery: AttentionDeliveryPorts) {
        self.dataRoot = dataRoot
        self.delivery = delivery
    }

    public func shutdown() { stopped = true }

    /// Every command and notification retains an immutable occurrence BEFORE
    /// admission. A deliberate uncarded command has its own id.
    @discardableResult
    public func route(eventId: String, importance: AttentionImportance, title: String, body: String,
                      reason: String? = nil, userInfo: [String: String] = [:], origin: AttentionOrigin? = nil,
                      pinnedTo: AttentionDelivery? = nil, macBanner: Bool = false, sourceRevision: String? = nil,
                      at date: Date = Date()) async throws -> AttentionOutcome {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let selected = pinnedTo ?? Self.policy(importance: importance, origin: origin)
        guard selected != .none else { return .routineSuccess }
        let event = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo, fallback: eventId)
        let canonicalCard = pinnedTo == nil || userInfo["source"] == "interaction" || userInfo["trigger"] != nil
        let card = canonicalCard ? userInfo["itemId"].flatMap { $0.isEmpty ? nil : $0 } : nil
        let resident = try SessionConversation.checkedKind(ChatToolSessionContext.verifiedSessionId, dataRoot: dataRoot)?.isOwnWork == true
        let destination = Self.destination(selected, origin: origin)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let draft = try NotificationOccurrence(eventID: event, cardID: card, title: title, body: body,
            reason: reason ?? body, userInfo: userInfo, importance: importance.rawValue, route: selected.rawValue,
            origin: try origin.map { try encoder.encode($0) }, destinations: [destination] + (macBanner ? ["mac"] : []),
            commandID: pinnedTo != nil && card == nil ? UUID().uuidString.lowercased() : nil,
            sourceRevision: sourceRevision, honorsQuietHours: resident || (pinnedTo == nil && Self.honorsQuietHours(importance)))
        // Shipped reason-only history proves an earlier effect may exist, not
        // its destination's acceptance. Its retained file is read, never rewritten.
        let prior: NotificationDeliveryOutcome? = try Self.retainedReasons(dataRoot: dataRoot)[event] == Self.stableDigest(reason ?? body)
            ? .unknown(sent: true, reason: "Retained reason-only receipt; reconcile the earlier destination") : nil
        let occurrence = try await retain(draft, priorOutcome: prior)
        try await settlePreferences(occurrence)
        let quiet = try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot)?
            .contains(hour: Calendar.current.component(.hour, from: date)) == true
        if quiet && occurrence.honorsQuietHours {
            // One inbox edge schedules the quiet-hours end; the ledger owns intent.
            if card == nil {
                try await LiveNotificationInbox.hold(dataRoot: dataRoot, title: title, body: body, ways: [],
                    id: "held:" + occurrence.id, fields: ["notification_occurrence_id": .string(occurrence.id)])
            }
            var result = try outcome(for: occurrence.id)
            if result.transportOutcome?.settled != true {
                result = .quietHours; result.knock = occurrence.id; result.heldForResidentWake = resident
            }
            return result
        }
        return try await dispatch(occurrence.id)
    }

    static func destination(_ route: AttentionDelivery, origin: AttentionOrigin?) -> String {
        route == .conversation ? (origin?.surface.rawValue ?? "conversation") : route.rawValue
    }

    /// Consume the inbox's CURRENT intent in the same source lock as admission.
    /// It cannot subsequently replay over a new direct route.
    func retain(_ occurrence: NotificationOccurrence, priorOutcome: NotificationDeliveryOutcome? = nil) async throws -> NotificationOccurrence {
        let ledger = NotificationDeliveryLedger(dataRoot: dataRoot)
        guard let card = occurrence.cardID else {
            let id = try await ledger.retain(occurrence, priorOutcome: priorOutcome)
            guard let retained = try ledger.read().entries[id]?.occurrence else { throw CocoaError(.fileReadCorruptFile) }
            return retained
        }
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        return try await SwiftNativePersistenceCore.withFileLock(inbox.path, waitingAtMost: 5) {
            guard let value = try await inbox.row(id: card), let row = value.objectValue,
                  let title = (row["held_title"] ?? row["title"])?.stringValue,
                  let body = (row["held_body"] ?? row["summary"])?.stringValue else {
                throw ToolFailureError("The notification's canonical card is unavailable; nothing was sent.", effects: .none, owner: inbox.path.path)
            }
            let currentRevision = try LiveNotificationInbox.notificationRevision(value)
            // An explicit producer revision must still be current. Callers
            // without one consume the current card's committed intent below;
            // notification prose is never evidence of source identity.
            if let revision = occurrence.sourceRevision, revision != currentRevision {
                throw ToolFailureError("The card changed before notification admission. Its current intent remains owned by the card; this stale payload was not sent.", effects: .none, owner: inbox.path.path)
            }
            if let severity = occurrence.userInfo["severity"], row["severity"] != .string(severity) {
                throw ToolFailureError("The card severity changed before notification admission; nothing was sent.", effects: .none, owner: inbox.path.path)
            }
            guard row["status"] != .string("archived"), row["status"] != .string("dismissed") else {
                throw ToolFailureError("The card was settled before notification admission; nothing was sent.", effects: .none, owner: inbox.path.path)
            }
            var destinations = Set(occurrence.destinations)
            if row["held_delivery"]?.arrayValue?.contains(.string("mac")) == true { destinations.insert("mac") }
            let honorsQuietHours: Bool
            if let raw = row["held_honors_quiet_hours"] {
                guard case .bool(let value) = raw else { throw CocoaError(.fileReadCorruptFile) }; honorsQuietHours = value
            } else { honorsQuietHours = occurrence.honorsQuietHours }
            let bound = try NotificationOccurrence(eventID: occurrence.eventID, cardID: card,
                title: occurrence.sourceRevision != nil ? occurrence.title : title,
                body: occurrence.sourceRevision != nil ? occurrence.body : body,
                reason: occurrence.reason, userInfo: occurrence.userInfo,
                importance: occurrence.importance, route: occurrence.route, origin: occurrence.origin,
                soundName: occurrence.soundName, destinations: Array(destinations),
                sourceRevision: currentRevision, honorsQuietHours: honorsQuietHours)
            let id = try await ledger.retain(bound, consumedImports: [try Self.heldImportKey(value)], priorOutcome: priorOutcome)
            guard let retained = try ledger.read().entries[id]?.occurrence else { throw CocoaError(.fileReadCorruptFile) }
            return retained
        }
    }

    func settlePreferences(_ occurrence: NotificationOccurrence) async throws {
        for destination in occurrence.destinations where destination != "mac" {
            if let key = Self.suppression(destination) {
                _ = try await NotificationDeliveryLedger(dataRoot: dataRoot).claim(occurrence.id, destination: destination, suppressedBy: key)
            }
        }
    }

    static func suppression(_ destination: String) -> String? {
        switch destination {
        case "phone": return NotificationChannelPreference.push() ? nil : NotificationChannelPreference.pushKey
        case "telegram": return NotificationChannelPreference.telegram() ? nil : NotificationChannelPreference.telegramKey
        default: return nil // Slack has no separate notification preference.
        }
    }

    /// Release names an existing occurrence; it never routes an old snapshot.
    func dispatch(_ id: String) async throws -> AttentionOutcome {
        if let task = inFlight[id] { return try await task.value }
        guard !stopped else { throw CancellationError() }
        let task = Task { try await self.sendOccurrence(id) }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        return try await task.value
    }

    private func sendOccurrence(_ id: String) async throws -> AttentionOutcome {
        let ledger = NotificationDeliveryLedger(dataRoot: dataRoot)
        guard let occurrence = try ledger.read().entries[id]?.occurrence else { throw CocoaError(.fileReadNoSuchFile) }
        let origin = try occurrence.origin.map { try JSONDecoder().decode(AttentionOrigin.self, from: $0) }
        var receipt: MobileNotificationDeliveryReceipt?
        for destination in occurrence.destinations {
            guard !stopped else { break }
            if destination == "mac" {
                _ = await NativeAgentNotifications.deliverOccurrence(id, dataRoot: dataRoot)
                continue
            }
            guard let claim = try await ledger.claim(id, destination: destination, suppressedBy: Self.suppression(destination)) else { continue }
            let verdict: NotificationDeliveryOutcome
            if destination == "phone" {
                var enriched = occurrence.userInfo
                enriched["eventId"] = occurrence.id
                enriched["importance"] = occurrence.importance
                enriched["routedTo"] = occurrence.route
                if let origin {
                    enriched["originSurface"] = origin.surface.rawValue
                    if let session = origin.sessionId { enriched["originSessionId"] = session }
                }
                let sent = await delivery.phone(occurrence.title, occurrence.body, enriched)
                receipt = sent.receipt; verdict = sent.outcome
            } else {
                verdict = await sendConversation(occurrence)
            }
            let saved: Result<Void, Error> = await settle {
                do { try await ledger.finish(claim, outcome: verdict); return .success(()) }
                catch { return .failure(error) }
            }
            try saved.get()
        }
        let readout = try outcome(for: id)
        var result = AttentionOutcome(delivery: readout.delivery, receipt: receipt,
            transportOutcome: readout.transportOutcome, destinationOutcomes: readout.destinationOutcomes)
        result.knock = id
        return result
    }

    func outcome(for id: String) throws -> AttentionOutcome {
        guard let entry = try NotificationDeliveryLedger(dataRoot: dataRoot).read().entries[id],
              let route = AttentionDelivery(rawValue: entry.occurrence.route) else { throw CocoaError(.fileReadCorruptFile) }
        let origin = try entry.occurrence.origin.map { try JSONDecoder().decode(AttentionOrigin.self, from: $0) }
        let destination = route == .none ? entry.occurrence.destinations.first : Self.destination(route, origin: origin)
        guard let destination, let row = entry.rows[destination] else { throw CocoaError(.fileReadCorruptFile) }
        var result = AttentionOutcome(delivery: route, receipt: nil,
            transportOutcome: row.outcome, destinationOutcomes: entry.rows.mapValues(\.outcome))
        result.knock = id
        return result
    }

    private func sendConversation(_ occurrence: NotificationOccurrence) async -> NotificationDeliveryOutcome {
        do {
            let text = Self.telegramText(title: occurrence.title, body: occurrence.body)
            let origin = try occurrence.origin.map { try JSONDecoder().decode(AttentionOrigin.self, from: $0) }
            if occurrence.route == AttentionDelivery.telegram.rawValue || origin?.surface == .telegram {
                guard let config = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot),
                      config.enabled, !config.botToken.isEmpty else { return .notDelivered(reason: "Telegram is not configured") }
                let destination: TelegramDestination
                if let origin {
                    guard let raw = origin.destinationId, let chat = Int(raw) else { return .notDelivered(reason: "Telegram origin has no chat id") }
                    let thread = origin.threadId.flatMap(Int.init)
                    guard origin.threadId == nil || thread != nil else { return .notDelivered(reason: "Telegram origin has an invalid topic id") }
                    destination = TelegramDestination(chatId: chat, threadId: thread)
                } else {
                    guard let chat = config.ownerUserId.flatMap({ Int(exactly: $0) }), chat > 0,
                          let session = try await TelegramSessionStore(dataRoot: dataRoot).boundSessionId(chatId: chat), !session.isEmpty else {
                        return .notDelivered(reason: "No verified owner Telegram conversation")
                    }
                    destination = TelegramDestination(chatId: chat)
                }
                return await delivery.telegram(config.botToken, destination, TelegramPollLoop.cleanedPlainText(text))
            }
            if let origin, origin.surface == .slack, let channel = origin.destinationId {
                var input: [String: JSONValue] = ["channel": .string(channel), "text": .string(text)]
                if let thread = origin.threadId { input["thread_ts"] = .string(thread) }
                return await delivery.slack(input, dataRoot)
            }
            return .notDelivered(reason: "Origin has no notification transport")
        } catch { return .notDelivered(reason: error.localizedDescription) } // No throwing client call after preflight.
    }

    static func settleKnocks(confirmed: Set<String>, dataRoot: URL) async throws {
        try await NotificationDeliveryLedger(dataRoot: dataRoot).confirmPhone(confirmed)
        guard !confirmed.isEmpty else { return }
        ExperienceStore.record(dataRoot, "knock-receipts") { store in
            for owed in try await store.open() where owed.id.hasPrefix("knock:")
                && owed.owes["deliver"]?.phase.isSettled == false
                && owed.claims.contains(where: { $0.claim.hasPrefix("event: ") && confirmed.contains(String($0.claim.dropFirst(7))) }) {
                try await store.append([.obligation(key: "deliver", phase: .accepted)], to: owed.id)
            }
        }
    }

    static func telegramText(title: String, body: String) -> String {
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty || tail == head { return head }
        return head + "\n\n" + tail
    }
}
