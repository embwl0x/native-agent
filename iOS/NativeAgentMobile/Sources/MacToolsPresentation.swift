import Foundation
import NativeAgentShared
// Blueprint: | `MacToolsPresentation.swift` | Policy hints for shared executable phone actions, volume target wording, notification feedback and Spotlight results |

/// The iPhone must not treat a missing Mac trust projection as evidence that
/// Mac Control was intentionally disabled. The two cases have different owner
/// actions: wait for publishing versus change a policy on the Mac.
enum MacToolsPolicyGatePresentation {
    enum State: Equatable {
        case snapshotUnavailable
        case macControlDisabled
        case iosRemoteDisabled
        case enabled
    }

    static func state(for policy: MacControlPolicyWireSnapshot?) -> State {
        guard let policy else { return .snapshotUnavailable }
        guard policy.enabled else { return .macControlDisabled }
        return policy.remoteFromIosAllowed ? .enabled : .iosRemoteDisabled
    }

    static func disabledDescription(for policy: MacControlPolicyWireSnapshot?) -> String {
        switch state(for: policy) {
        case .snapshotUnavailable:
            "No Mac Control policy snapshot yet. Keep the Mac app open until it publishes Trust settings."
        case .macControlDisabled:
            "Mac Control is disabled by policy. Enable Agent Access → Full Mac or turn on Mac Control in the Mac app's Trust tab."
        case .iosRemoteDisabled:
            "iOS remote control is disabled by policy. Enable iOS remote control in the Mac app's Trust tab under Mac Control."
        case .enabled:
            "Mac Tools are available."
        }
    }
}

/// The individual Mac privileges remain independently fail-closed even after
/// the enclosing Mac Control policy has enabled this screen. Keeping their
/// decision and owner-facing explanation together prevents a dimmed control
/// from losing the reason it is unavailable.
enum MacToolsPrivilegePresentation {
    static func isAllowed(_ privilege: PhoneMacControlAction, policy: MacControlPolicyWireSnapshot?) -> Bool {
        guard let policy else { return false }
        return switch privilege {
        case .notification: policy.notificationsAllowed
        case .volume: policy.systemControlAllowed
        case .spotlight: policy.spotlightAllowed
        default: false
        }
    }

    static func disabledDescription(for privilege: PhoneMacControlAction) -> String {
        switch privilege {
        case .notification: "Notifications are disabled by Mac Control policy."
        case .volume: "System controls are disabled by Mac Control policy."
        case .spotlight: "Spotlight is disabled by Mac Control policy."
        default: "This action is unavailable in Mac Tools."
        }
    }
}

/// The slider is a requested target, rather than a live Mac volume monitor.
enum MacVolumeControlPresentation {
    static let defaultTargetFraction = 0.5
    static let currentVolumeDisclosure = "Pick a volume target to send to your Mac. The slider doesn’t track later changes on the Mac."

    static func targetPercent(for fraction: Double) -> Int {
        guard fraction.isFinite else { return 50 }
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    static func isValid(percent: Int) -> Bool {
        (0...100).contains(percent)
    }

    static func acknowledgement(percent: Int) -> String {
        "The Mac completed the request to set volume to \(percent)%."
    }
}

/// Explicit presentation state for the notification composer. A result must
/// identify both the operation and its outcome instead of appearing as an
/// unlabeled line beside a disabled-looking control.
enum MacNotificationSendPresentation {
    enum Feedback: Equatable {
        case sent
        case failed(String)

        var text: String {
            switch self {
            case .sent: "Notification sent to the Mac."
            case .failed(let detail): "Couldn’t send notification: \(detail)"
            }
        }
    }
}

/// Spotlight's empty string means the Mac did not provide a search response.
/// That is different from a nonempty response whose lines contain no usable
/// results, which is a completed zero-result search.
enum MacToolsSpotlightPresentation {
    static let collapsedResultLimit = 8

    enum Outcome: Equatable {
        case emptyResponse
        case invalidResponse
        case noResults
        case results([String])

        var rows: [String] {
            switch self {
            case .results(let results): results
            case .emptyResponse, .invalidResponse, .noResults: []
            }
        }

        var statusText: String {
            switch self {
            case .emptyResponse:
                "Mac returned an empty Spotlight response; results are unavailable."
            case .invalidResponse:
                "Mac returned an unreadable Spotlight response; results are unavailable."
            case .noResults:
                "No Spotlight results."
            case .results(let results):
                "\(results.count) Spotlight result(s)."
            }
        }

        var resultCount: Int { rows.count }

        func visibleRows(showingAll: Bool) -> [String] {
            guard !showingAll else { return rows }
            return Array(rows.prefix(MacToolsSpotlightPresentation.collapsedResultLimit))
        }

        var hiddenResultCount: Int {
            max(0, resultCount - MacToolsSpotlightPresentation.collapsedResultLimit)
        }

        func truncationText(showingAll: Bool) -> String? {
            guard hiddenResultCount > 0 else { return nil }
            return showingAll
                ? "Showing all \(resultCount) Spotlight results."
                : "Showing \(MacToolsSpotlightPresentation.collapsedResultLimit) of \(resultCount) Spotlight results."
        }
    }

    static func outcome(from rawResponse: String) -> Outcome {
        guard !rawResponse.isEmpty else { return .emptyResponse }

        struct SearchResponse: Decodable {
            let results: [String]
        }
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: Data(rawResponse.utf8)) else {
            return .invalidResponse
        }
        let results = response.results

        return results.isEmpty ? .noResults : .results(results)
    }
}
