import Foundation
import NativeAgentShared
// Blueprint: | `MacToolsPresentation.swift` | Shared Mac action policy hints, requested volume, notification feedback and Spotlight results |

/// A missing trust projection requires publication, while disabled Mac Control requires a policy change; do not conflate the two.
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

/// Keep each privilege fail-closed and its explanation alongside the decision so disabled controls retain a remedy.
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

/// Volume is a requested target; never imply the slider monitors live Mac volume.
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

/// Name notification operation and outcome so feedback cannot look like an unlabeled disabled control.
enum MacNotificationSendPresentation {
    enum Feedback: Equatable {
        case sent
        case failed(String)
        case unconfirmed(String)

        var text: String {
            switch self {
            case .sent: "Notification sent to the Mac."
            case .failed(let detail): "Couldn’t send notification: \(detail)"
            case .unconfirmed(let detail): "Notification outcome is not confirmed: \(detail)"
            }
        }
    }
}

/// Empty Spotlight response means unavailable; a nonempty response without usable rows proves a completed zero-result search.
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
