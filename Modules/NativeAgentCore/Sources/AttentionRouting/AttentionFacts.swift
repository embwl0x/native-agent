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
// Blueprint: | `AttentionFacts.swift` | Attention importance, origin, surface, delivery and outcome values with transport-derived delivery projection |

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

    /// One projection of the transport outcome; saving the card is a separate fact.
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
