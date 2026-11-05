import Foundation
// Blueprint: | `NotificationDeliveryOutcome.swift` | A transport's classified verdict for one door; the door's `deliver:` obligation records it |

/// Delivery proves acceptance by the named destination, never that a person read it.
public enum NotificationDeliveryOutcome: Codable, Sendable, Equatable {
    case delivered
    case notDelivered(reason: String)
    case suppressed(preference: String)
    case unknown(sent: Bool, reason: String)

    public var mayAttempt: Bool {
        if case .notDelivered = self { return true }
        return false
    }

    public var settled: Bool {
        switch self {
        case .delivered, .suppressed: return true
        case .notDelivered, .unknown: return false
        }
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
