import Foundation
// Blueprint: | `NotificationDeliveryOutcome.swift` | One door's delivery or quiet-hours deferral; recorded intent is not transport acceptance |

/// Delivery proves acceptance by the named destination, never that a person read it.
public enum NotificationDeliveryOutcome: Codable, Sendable, Equatable {
    case delivered
    /// The recorded obligation has not entered a transport; the person's quiet-hours end releases it.
    case deferred(until: Date)
    case notDelivered(reason: String)
    case suppressed(preference: String)
    case unknown(sent: Bool, reason: String)

    public var settled: Bool {
        switch self {
        case .delivered, .suppressed: return true
        case .deferred, .notDelivered, .unknown: return false
        }
    }

    /// Shared words and effect evidence for the retained intent, never a claim of device display.
    public var deferredFields: [String: JSONValue]? {
        guard case .deferred(let until) = self else { return nil }
        let time = ISO8601DateFormatter().string(from: until)
        return [
            "status": .string("held"), "delivery": .string("deferred"), "ok": .bool(true),
            "effects": .string("occurred"), "recorded": .bool(true), "delivered": .bool(false), "posted": .bool(false),
            "deferredUntil": .string(time),
            "message": .string("Recorded and owed. It goes when the person's quiet hours end at " + time
                + ". Sending it again would notify twice."),
        ]
    }
}

/// A transport can throw this without losing its classified outcome at a host port.
public struct NotificationDeliveryFailure: Error, LocalizedError, Sendable {
    public let outcome: NotificationDeliveryOutcome
    public let errorDescription: String?
    public init(_ outcome: NotificationDeliveryOutcome, _ description: String) {
        self.outcome = outcome
        self.errorDescription = description
    }
}
