import Foundation
import NativeAgentShared
// Blueprint: | `MacToolsPresentation.swift` | Mac policy remedies, requested volume and off-main Spotlight result decoding |

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

/// Volume is a requested target, never a live Mac gauge.
enum MacVolumeControlPresentation {
    static let currentVolumeDisclosure = "Pick a volume target to send to your Mac. This field doesn’t track later changes on the Mac."

    static func isValid(percent: Int) -> Bool {
        (0...100).contains(percent)
    }

    static func acknowledgement(percent: Int) -> String {
        "The Mac completed the request to set volume to \(percent)%."
    }
}

/// Only a decoded result array can prove a zero-result search.
enum MacToolsSpotlightPresentation {
    enum Outcome: Equatable, Sendable {
        case noResults
        case results([String])

        var rows: [String] {
            switch self {
            case .results(let results): results
            case .noResults: []
            }
        }

        var statusText: String {
            switch self {
            case .noResults:
                "No Spotlight results."
            case .results(let results):
                "\(results.count) Spotlight result(s)."
            }
        }

    }

    @concurrent nonisolated static func outcome(from rawResponse: String) async throws -> Outcome {
        guard !rawResponse.isEmpty else {
            throw PartCallError(code: "spotlight_empty_response", message: "Mac returned an empty Spotlight response; results are unavailable.")
        }

        struct SearchResponse: Decodable {
            let results: [String]
        }
        let response = try JSONDecoder().decode(SearchResponse.self, from: Data(rawResponse.utf8))
        let results = response.results

        return results.isEmpty ? .noResults : .results(results)
    }
}
