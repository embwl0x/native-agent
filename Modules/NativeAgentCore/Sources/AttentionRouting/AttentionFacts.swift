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
import ApprovalInbox
// Blueprint: | `AttentionFacts.swift` | Shared transport verdicts drive attention; queued or absent evidence never proves acceptance |

public enum AttentionSurface: String, Sendable, CaseIterable, Codable {
    case chat
    case ios
    case telegram
    case slack
}

/// The one door a pinned caller names; every other matter goes to the person's doors.
public enum AttentionDelivery: String, Sendable, Equatable, Codable {
    case phone
    case mac
    case telegram
    /// Reuse the originating conversation so the reply stays beside the work.
    case conversation
}

/// Authorized destination and thread minted by the originating turn, never an inbound allowlist.
public struct AttentionOrigin: Sendable, Equatable, Codable {
    public let surface: AttentionSurface
    /// Carried in the push payload so a tap opens the fact's own conversation.
    public let sessionId: String?
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

    /// Use the asking turn's live reply route; unsupported surfaces have no return route.
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

    /// Approval origins are written by the chat-tool and live ACP filers; other payloads do not supply a conversation route.
    public init?(approval: ApprovalRecord) throws {
        guard let payload = approval.payload.objectValue,
              payload["kind"] == .string("chat_tool_approval") || payload["kind"] == .string("agent_acp_live_approval"),
              let value = payload["origin"] else { return nil }
        guard let origin = value.objectValue, let raw = origin["surface"]?.stringValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // A supported conversation surface is required for a return route; peer and job surfaces have no person transport here.
        guard let surface = AttentionSurface(rawValue: raw) else { return nil }
        func optional(_ key: String) throws -> String? {
            guard let value = origin[key], value != .null else { return nil }
            guard let string = value.stringValue else { throw CocoaError(.fileReadCorruptFile) }
            return string
        }
        self.init(surface: surface, sessionId: try optional("sessionId"),
                  destinationId: try optional("destinationId"), threadId: try optional("threadId"))
    }

    /// Mac and iOS conversations are payload labels: background actors cannot reply into them.
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
    public let matterID: String
    public let receipt: MobileNotificationDeliveryReceipt?
    let macPost: NativeAgentNotificationPostResult?
    public let destinationOutcomes: [String: NotificationDeliveryOutcome]
    public var suppressed: Bool {
        !destinationOutcomes.isEmpty && destinationOutcomes.values.allSatisfy {
            if case .suppressed = $0 { return true }; return false
        }
    }
    init(
        matterID: String,
        receipt: MobileNotificationDeliveryReceipt?,
        destinationOutcomes: [String: NotificationDeliveryOutcome] = [:],
        macPost: NativeAgentNotificationPostResult? = nil
    ) {
        self.matterID = matterID
        self.receipt = receipt
        self.macPost = macPost
        self.destinationOutcomes = destinationOutcomes
    }

    /// One projection of the transport outcome; saving the card is a separate fact.
    public enum Delivery: String, Sendable, Equatable {
        /// No channel means no send was attempted.
        case noChannel = "no_channel"
        /// The retained intent waits for quiet hours; no send was admitted.
        case deferred
        /// Transport handoff remains unconfirmed at the device.
        case queued
        case accepted
        case failed

    }

    public var destinationProjections: [String: Delivery] {
        destinationOutcomes.mapValues { outcome in
            switch outcome {
            case .delivered: .accepted
            case .suppressed: .noChannel
            case .deferred: .deferred
            case .notDelivered: .failed
            case .unknown: .queued
            }
        }
    }

    /// All unsuppressed destinations must accept; one accepted door cannot settle the others.
    public var deliveryProjection: Delivery {
        let projections = destinationProjections.values
        if projections.contains(.failed) { return .failed }
        if projections.contains(.queued) { return .queued }
        if projections.contains(.deferred) { return .deferred }
        if projections.contains(.accepted) { return .accepted }
        return .noChannel
    }

    public var destinationFields: [String: JSONValue] {
        destinationProjections.mapValues { JSONValue.string($0.rawValue) }
    }

    /// The same recorded hold is projected by Mac, phone, scheduled notices and Desk readouts.
    public var deferredFields: [String: JSONValue]? {
        guard var fields = destinationOutcomes.values.compactMap(\.deferredFields).first else { return nil }
        // A held sibling supplies its instructions, never the verdict or effects of an unconfirmed or refused door.
        if deliveryProjection != .deferred {
            fields = fields.filter { ["deferredUntil", "message", "recorded"].contains($0.key) }
        }
        fields["notificationId"] = .string(matterID)
        return fields
    }

    public func phoneDeliveryFields() throws -> [String: JSONValue] {
        if deliveryProjection == .deferred, let fields = deferredFields { return fields }
        return try requireReceipt().deliveryFields()
    }

    /// A phone-pinned call requires its phone publication receipt; other doors cannot supply one or prove phone display.
    private func requireReceipt() throws -> MobileNotificationDeliveryReceipt {
        if case .suppressed(let preference)? = destinationOutcomes["phone"] {
            throw ToolFailureError("Not sent: this notification channel is off (" + preference + ").", effects: .none,
                owner: preference, code: "notification_suppressed")
        }
        if receipt == nil, case .unknown(_, let reason)? = destinationOutcomes["phone"] {
            throw ToolFailureError("Phone notification outcome is unknown: " + reason, effects: .unknown,
                owner: "experiences", code: "notification_unconfirmed",
                instruction: "Wait for the phone's receipt before requesting another notification.", recovery: .reconcile)
        }
        if case .notDelivered(let reason)? = destinationOutcomes["phone"] {
            throw ToolFailureError("Phone notification was not delivered: " + reason, effects: .none,
                owner: "experiences", code: "notification_not_delivered")
        }
        guard let receipt else {
            throw NSError(domain: "AttentionRouter", code: -503, userInfo: [
                NSLocalizedDescriptionKey:
                    "No paired-device receipt exists; destination outcomes: \(destinationFields)",
            ])
        }
        return receipt
    }
}
