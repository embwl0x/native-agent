import ChatTurnRuntime
import ChatTurnContracts
import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TelegramBot
import DeviceSync
import Experiences
import Transcripts
import ApprovalInbox
import AgentWorkspace
// Blueprint: | `AttentionRouter.swift` | One matter reaches the person's doors through ForPerson's delivery obligations |

public actor AttentionRouter {
    public typealias PhoneSender = @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt
    let dataRoot: URL
    let delivery: AttentionDeliveryPorts
    private var inFlight: [String: Task<AttentionOutcome, Error>] = [:]
    var stopped = false
    var resultScanInFlight = false
    var settledResultFiles: [URL: Date] = [:]
    var resultRetryOffset = 0

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot(), delivery: AttentionDeliveryPorts) {
        self.dataRoot = dataRoot
        self.delivery = delivery
    }

    public func shutdown() {
        stopped = true
        for task in inFlight.values { task.cancel() }
    }

    /// Who a matter reaches: no door (it waits in the person's inbox), the person's doors, or the one door its caller names.
    public enum Reach: Sendable, Equatable {
        case inbox
        case person(from: AttentionOrigin?)
        case pinned(AttentionDelivery, from: AttentionOrigin?)
    }

    /// Tells the person once, with its doors declared at birth, then sends what is still owed. Quiet hours hold it unless something went wrong, or the
    /// person named the door through their own Mac act or current conversation request.
    @discardableResult
    public func tell(_ matter: Matter, reach: Reach, at date: Date = Date(), turn: Turn?) async throws -> AttentionOutcome {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let doors = Self.doors(reach)
        guard try await ForPerson.at(dataRoot).tell(matter, doors: doors) != .settled, !doors.isEmpty else { return try await outcome(matter.id) }
        var namedByPerson = false
        if case .pinned = reach, let turn, turn.rows.hiddenInput == nil, turn.origin == nil,
           let envelope = turn.envelope, envelope.agent == nil {
            // The person's local act is its own request; it need not create a conversation or words.
            if envelope.declaredRemote == false {
                namedByPerson = true
            } else if let session = turn.verifiedSessionID, let request = turn.userText,
                      !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                namedByPerson = SwiftNativeChatOrchestrationClient.isUsersTurn(
                    surface: envelope.surface, sessionId: session, dataRoot: dataRoot, turn: turn)
            }
        }
        if matter.form != .wentWrong, !namedByPerson {
            let end: Date?
            do { end = try Self.quietHoursEnd(at: date, dataRoot: dataRoot) }
            catch {
                throw ToolFailureError("Matter \(matter.id) is recorded and still owed; this call admitted no send. " + error.localizedDescription,
                    effects: .occurred, owner: "user_prefs.json", code: "quiet_hours_unavailable",
                    instruction: "Repair the quiet-hours policy; do not send the recorded matter again.", recovery: .repair)
            }
            if let end { return try await outcome(matter.id, deferredUntil: end) }
        }
        return try await deliver(matter.id)
    }

    /// One send per matter at a time; a second caller joins the first.
    func deliver(_ id: String) async throws -> AttentionOutcome {
        if let task = inFlight[id] { return try await task.value }
        guard !stopped else { throw CancellationError() }
        let task = Task { try await self.send(id) }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        return try await task.value
    }

    /// Each unsettled door: the person's preference may close it; otherwise it is reserved and started durably before its transport runs.
    private func send(_ id: String) async throws -> AttentionOutcome {
        let forPerson = ForPerson.at(dataRoot)
        guard let matter = try await forPerson.matter(id) else { throw CocoaError(.fileReadNoSuchFile) }
        let payload = try PersonPayload(matter)
        var verdicts: [String: NotificationDeliveryOutcome] = [:]
        var receipt: MobileNotificationDeliveryReceipt?
        var macPost: NativeAgentNotificationPostResult?
        for (key, owed) in matter.owes.sorted(by: { $0.key < $1.key }) where key.hasPrefix("deliver:") && !owed.phase.isSettled {
            guard !stopped else { throw CancellationError() }
            guard let door = Door(address: owed.to) else {
                throw ToolFailureError("Matter \(id) names an unreadable delivery door: \(key).", effects: .none,
                    owner: "experiences:" + id, code: "delivery_door_unavailable")
            }
            // A conversation's card is written by its own owner (the chat mirror), which accepts the door with the row it wrote.
            if case .conversation = door { continue }
            // Among the person's doors the Mac counts only while the person is at it (a caller that pinned the Mac named it); walking up later never alerts
            // again.
            if door == .mac, matter.owes[Door.phone.key] != nil, !Self.atMac() {
                try await forPerson.letGo(id, door, .cancelled)
                continue
            }
            if let preference = Self.suppression(door) {
                try await forPerson.letGo(id, door, .cancelled)
                verdicts[door.surface] = .suppressed(preference: preference)
                continue
            }
            if case .telegram(let chat, _) = door, let approval = Self.approval(matter), try await promptDelivered(approval, chat: chat) {
                try await forPerson.accepted(id, door, evidence: .init(source: Matter.approvals, id: approval))
                continue
            }
            guard let attempt = try await forPerson.reserve(id, door) else { continue }
            try await forPerson.started(attempt)
            let verdict: NotificationDeliveryOutcome
            switch door {
            case .phone:
                let sent = await delivery.phone(payload.title, payload.summary, Self.phoneInfo(matter, payload: payload))
                (receipt, verdict) = (sent.receipt, sent.outcome)
            case .mac:
                // The Mac routes and settles its banner on the matter's own id; only the phone needs the canonical event.
                var info = Self.phoneInfo(matter, payload: payload)
                info["eventId"] = id
                let post = await NativeAgentNotifications.banner(title: payload.title, body: payload.summary,
                    userInfo: info, identifier: id, dataRoot: dataRoot)
                macPost = post
                verdict = post.notificationOutcome
            case .telegram, .slack:
                verdict = await sendConversation(matter, door, payload: payload)
            case .conversation:
                continue
            }
            let saved: Result<Void, Error> = await settle {
                do {
                    if let phase = try Self.phase(verdict) {
                        try await forPerson.finished(attempt, phase)
                    } else { try await forPerson.letGo(id, door, .cancelled) }
                    return .success(())
                } catch { return .failure(error) }
            }
            if case .failure(let error) = saved {
                if door == .mac, let macPost, macPost.posted { throw MacNotificationSettlementFailure(result: macPost.receiptUnavailable(error)) }
                throw error
            }
            verdicts[door.surface] = verdict
        }
        if let macPost, macPost.status == "settlement_failed" { throw MacNotificationSettlementFailure(result: macPost) }
        do { return try await outcome(id, now: verdicts, receipt: receipt, macPost: macPost) }
        catch {
            if let macPost, macPost.posted { throw MacNotificationSettlementFailure(result: macPost.receiptUnavailable(error)) }
            throw error
        }
    }

    /// This call's transport verdicts, and each other door as its obligation stands.
    func outcome(_ id: String, deferredUntil: Date? = nil, now verdicts: [String: NotificationDeliveryOutcome] = [:],
                 receipt: MobileNotificationDeliveryReceipt? = nil,
                 macPost: NativeAgentNotificationPostResult? = nil) async throws -> AttentionOutcome {
        guard let matter = try await ForPerson.at(dataRoot).matter(id) else { throw CocoaError(.fileReadNoSuchFile) }
        var outcomes = verdicts
        for (key, owed) in matter.owes where key.hasPrefix("deliver:") {
            guard let door = Door(address: owed.to) else {
                throw ToolFailureError("Matter \(id) names an unreadable delivery door: \(key).", effects: .unknown,
                    owner: "experiences:" + id, code: "delivery_door_unavailable")
            }
            guard outcomes[door.surface] == nil else { continue }
            switch owed.phase {
            case .accepted: outcomes[door.surface] = .delivered
            case .letGo:
                guard let reason = owed.reason else {
                    throw ToolFailureError("Matter \(id) has no reason for letting go its \(door.surface) door.", effects: .unknown,
                        owner: "experiences:" + id, code: "delivery_reason_unavailable")
                }
                outcomes[door.surface] = .suppressed(preference: reason.rawValue)
            case .owed:
                outcomes[door.surface] = deferredUntil.map { .deferred(until: $0) } ?? .notDelivered(reason: "not sent yet")
            case .preDispatchFailed:
                outcomes[door.surface] = .notDelivered(reason: "the door failed before dispatch")
            case .rejected: outcomes[door.surface] = .notDelivered(reason: "the door refused it")
            case .reserved, .dispatchStarted, .outcomeUnknown:
                outcomes[door.surface] = .unknown(sent: owed.phase != .reserved, reason: "the door has not confirmed it")
            }
        }
        return AttentionOutcome(matterID: id, receipt: receipt, destinationOutcomes: outcomes, macPost: macPost)
    }

    /// A door that turned out closed by the person's preference is let go, not settled by a transport phase.
    static func phase(_ verdict: NotificationDeliveryOutcome) throws -> ObligationPhase? {
        switch verdict {
        case .delivered: .accepted
        case .notDelivered: .rejected
        case .unknown: .outcomeUnknown
        case .suppressed: nil
        case .deferred:
            throw ToolFailureError("A transport returned a quiet-hours hold after dispatch started. Inspect its receipt before another send.",
                effects: .unknown, owner: "experiences", code: "delivery_phase_unavailable", recovery: .reconcile)
        }
    }

    static func suppression(_ door: Door) -> String? {
        switch door {
        case .phone: return NotificationChannelPreference.push() ? nil : NotificationChannelPreference.pushKey
        case .telegram: return NotificationChannelPreference.telegram() ? nil : NotificationChannelPreference.telegramKey
        case .mac: return NotificationChannelPreference.inApp() ? nil : NotificationChannelPreference.inAppKey
        // Slack and a conversation have no separate notification preference.
        case .slack, .conversation: return nil
        }
    }

    static func approval(_ matter: Experience) -> String? {
        matter.evidence.first { $0.source == Matter.approvals }?.id
    }

    private struct PersonPayload {
        let title: String
        let summary: String
        let words: String
        let from: String
        let open: String?

        init(_ matter: Experience) throws {
            guard let face = matter.face, let row = face.row, let summary = row.detail, let from = face.from,
                  !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolFailureError("Matter \(matter.id) has no complete person-facing payload.", effects: .none,
                    owner: "experiences:" + matter.id, code: "person_payload_unavailable",
                    instruction: "Its owner must commit its title, summary, words and source before delivery.", recovery: .reconcile)
            }
            title = row.title
            self.summary = summary
            words = face.words
            self.from = from
            open = row.open
        }
    }

    /// What the phone and a banner click route on, read from the matter itself: the card, its approval, its conversation, its Desk item.
    private static func phoneInfo(_ matter: Experience, payload: PersonPayload) -> [String: String] {
        var info = ["eventId": ForPerson.phoneEvent(matter.id), "itemId": matter.id, "source": payload.from, "screen": "inbox"]
        if let approval = approval(matter) { (info["screen"], info["approvalId"]) = ("approvals", approval) }
        if let open = payload.open, open.hasPrefix("chat:") { (info["screen"], info["sessionId"]) = ("chat", String(open.dropFirst(5))) }
        if let open = payload.open, open.hasPrefix("page:desk/") { (info["screen"], info["taskId"]) = ("desk", String(open.dropFirst(10))) }
        if matter.face?.row?.tone == .failed { info["urgency"] = "urgent" }
        return info
    }

    /// The approval owner saves its Telegram prompt receipt; a prompt already in that chat is accepted, never sent twice.
    private func promptDelivered(_ approval: String, chat: String) async throws -> Bool {
        try await SwiftNativeApprovalInbox(root: dataRoot).get(approval).chatCard?.objectValue?["telegram_prompt_delivered:\(chat)"] == .bool(true)
    }

    private func sendConversation(_ matter: Experience, _ door: Door, payload: PersonPayload) async -> NotificationDeliveryOutcome {
        let text = Self.telegramText(title: payload.title, body: payload.words)
        switch door {
        case .telegram(let place, let topic):
            guard let chat = Int(place) else { return .notDelivered(reason: "Telegram door has no valid chat id") }
            // An ask's Telegram door is its prompt with answer buttons (approval or interaction), never a plain-text copy.
            if matter.owes["decide"] != nil { return await delivery.telegramApproval(Self.approval(matter) ?? matter.id, chat, dataRoot) }
            do {
                guard let config = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot),
                      config.enabled, !config.botToken.isEmpty else { return .notDelivered(reason: "Telegram is not configured") }
                let thread = topic.flatMap(Int.init)
                guard topic == nil || thread != nil else { return .notDelivered(reason: "Telegram door has an invalid topic id") }
                return await delivery.telegram(config.botToken, TelegramDestination(chatId: chat, threadId: thread),
                                               TelegramPollLoop.cleanedPlainText(text))
            } catch { return .notDelivered(reason: error.localizedDescription) }
        case .slack(let channel, let thread):
            var input: [String: JSONValue] = ["channel": .string(channel), "text": .string(text)]
            if let thread { input["thread_ts"] = .string(thread) }
            return await delivery.slack(input, dataRoot)
        case .phone, .mac, .conversation:
            return .notDelivered(reason: "No transport reaches this door from the router")
        }
    }

    static func telegramText(title: String, body: String) -> String {
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty || tail == head { return head }
        return head + "\n\n" + tail
    }

    public nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
