import Foundation
import ChatTurnContracts
import DeviceSync
import ChatTurnRuntime
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import TelegramBot
import Experiences
import Transcripts
// Blueprint: | `AttentionFacts.swift` | Attention importance, origin and delivery projections derive from the common transport verdict; queued and absent evidence never mean accepted |

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

    /// Map inbox severity to the attention class; unknown severity never interrupts.
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

/// The supplied conversation's surface.
public enum AttentionSurface: String, Sendable, CaseIterable, Codable {
    case chat
    case ios
    case telegram
    /// Slack threads can receive knocks from work started there.
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

/// Authorized destination and thread minted by the originating turn, never an inbound allowlist.
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
    public let transportOutcome: NotificationDeliveryOutcome?
    public let destinationOutcomes: [String: NotificationDeliveryOutcome]
    public var suppressed: Bool {
        if case .suppressed? = transportOutcome { return true }
        return false
    }
    /// Quiet hours retain the immutable intent without admitting its effect.
    public let deferredForQuietHours: Bool
    /// Her resident wake's knock in quiet hours: kept in the inbox, sent when they end.
    public var heldForResidentWake = false
    /// The knock's own identity (its event and the reason that made it a
    /// distinct knock): the event id the phone signs its receipt with.
    public internal(set) var knock: String?

    init(
        delivery: AttentionDelivery,
        receipt: MobileNotificationDeliveryReceipt?,
        deferredForQuietHours: Bool = false,
        transportOutcome: NotificationDeliveryOutcome? = nil,
        destinationOutcomes: [String: NotificationDeliveryOutcome] = [:]
    ) {
        self.delivery = delivery
        self.receipt = receipt
        self.deferredForQuietHours = deferredForQuietHours
        self.transportOutcome = transportOutcome
        self.destinationOutcomes = destinationOutcomes
    }

    static let routineSuccess = AttentionOutcome(delivery: .none, receipt: nil)

    /// The intent remains pending in its ledger through quiet hours.
    static let quietHours = AttentionOutcome(
        delivery: .none, receipt: nil, deferredForQuietHours: true)

    /// One projection of the transport outcome; saving the card is a separate fact.
    public enum Delivery: String, Sendable, Equatable {
        /// The routing table chose no channel: nothing was attempted.
        case noChannel = "no_channel"
        /// Quiet hours. The intent is retained; no send was admitted.
        case deferred
        /// Handed to a transport that has not confirmed it reached the device.
        case queued
        /// A transport accepted it.
        case accepted
        /// Tried, and no channel took it.
        case failed

        /// True only when a transport took the knock. "Not failed" is not this.
        public var reachedAChannel: Bool { self == .accepted }
    }

    public var deliveryProjection: Delivery {
        if deferredForQuietHours { return .deferred }
        if let transportOutcome {
            switch transportOutcome {
            case .delivered: return .accepted
            case .suppressed: return .noChannel
            case .notDelivered: return .failed
            case .unknown: return .queued
            }
        }
        guard delivery != .none else { return .noChannel }
        return .failed // No checked transport verdict is never acceptance.
    }

    /// Phone-pinned callers receive signed bridge acceptance and APNS transport
    /// evidence. Fails loud rather than fabricating it — a receipt must record
    /// something that actually ran (NORTHSTAR clause 2).
    public func requireReceipt() throws -> MobileNotificationDeliveryReceipt {
        if case .suppressed(let preference)? = transportOutcome {
            throw ToolFailureError("Not sent: this notification channel is off (" + preference + ").", effects: .none,
                owner: preference, code: "notification_suppressed")
        }
        if receipt == nil, case .unknown(_, let reason)? = transportOutcome {
            throw ToolFailureError("Phone notification outcome is unknown: " + reason, effects: .unknown,
                owner: "notify/deliveries.json", code: "notification_unconfirmed",
                instruction: "Reconcile the retained occurrence before requesting another notification.", recovery: .reconcile)
        }
        if case .notDelivered(let reason)? = transportOutcome {
            throw ToolFailureError("Phone notification was not delivered: " + reason, effects: .none,
                owner: "notify/deliveries.json", code: "notification_not_delivered")
        }
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
