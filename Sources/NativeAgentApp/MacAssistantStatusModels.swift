import Foundation
import MacAssistantStatus

/// The watch panel must distinguish a current inventory from one that merely
/// survived a failed refresh. Keeping this presentation state outside SwiftUI
/// makes the failure posture executable and prevents a stale ready badge from
/// being mistaken for current permission/readiness evidence.
enum MacAssistantWatchSetupLoadState: Equatable {
    case loading
    case current(MacAssistantStatusResult)
    case stale(MacAssistantStatusResult, message: String)
    case unavailable(message: String)

    var response: MacAssistantStatusResult? {
        switch self {
        case .current(let response), .stale(let response, _): response
        case .loading, .unavailable: nil
        }
    }

    var badgeText: String {
        switch self {
        case .loading: "Loading"
        case .current(let response): response.status.replacingOccurrences(of: "_", with: " ").capitalized
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
    }

    var badgeStatus: String {
        switch self {
        case .loading: "unknown"
        case .current(let response): response.status
        case .stale: "attention"
        case .unavailable: "failed"
        }
    }

    var diagnosticText: String? {
        switch self {
        case .stale(_, let message), .unavailable(let message): message
        case .loading, .current: nil
        }
    }

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }

    func afterFailure(_ message: String) -> Self {
        guard let response else { return .unavailable(message: message) }
        return .stale(response, message: message)
    }
}
