import Cognition
import Foundation
// Blueprint: | `SettingsInnerLifeStatus.swift` | Settings inner-life runtime status and its provider, model or reapply remedy |

/// Requested configuration is not runtime proof; reflection and every resident lane must be live before claiming running.
enum SettingsInnerLifeStatus {
    enum Recovery: Equatable {
        case configureProvider
        case selectModel
        case reapply
    }

    enum Tone: Equatable {
        case neutral
        case healthy
        case warning
        case unavailable
    }

    struct State: Equatable {
        let text: String
        let detail: String?
        let tone: Tone
        var recovery: Recovery? = nil
    }

    static func state(
        runtime: NativeSubconsciousRuntimeState?,
        reflectionRoute: NativeReflectionRouteStatus?
    ) -> State {
        guard let runtime else {
            return State(
                text: "Inner-life runtime unavailable.",
                detail: nil,
                tone: .unavailable
            )
        }

        guard runtime.enabled else {
            return State(text: "Off", detail: nil, tone: .neutral)
        }

        guard let reflectionRoute else {
            return State(
                text: "The reflection route is unavailable.",
                detail: nil,
                tone: .unavailable
            )
        }

        guard reflectionRoute.isReady else {
            let detail = bounded(reflectionRoute.detail)
            let isUnavailable = detail.localizedCaseInsensitiveContains("unavailable")
                || detail.localizedCaseInsensitiveContains("failed")
            return State(
                text: reflectionRoute.providerReady
                    ? "The selected model is no longer available for reflection."
                    : (isUnavailable ? "The reflection connection is unavailable." : "Reflection needs a ready provider connection."),
                detail: detail,
                tone: isUnavailable ? .unavailable : .warning,
                recovery: reflectionRoute.providerReady ? .selectModel : .configureProvider
            )
        }

        let inactiveLanes = inactiveLaneNames(runtime)
        guard inactiveLanes.isEmpty else {
            return State(
                text: "Not active: " + inactiveLanes.joined(separator: ", ") + ". Try enabling again.",
                detail: nil,
                tone: .warning,
                recovery: .reapply
            )
        }

        return State(
            text: "Running with " + bounded(reflectionRoute.model),
            detail: nil,
            tone: .healthy
        )
    }

    private static func inactiveLaneNames(_ runtime: NativeSubconsciousRuntimeState) -> [String] {
        var lanes: [String] = []
        if !runtime.capsuleEnabled { lanes.append("reflection context") }
        if !runtime.backgroundEnabled { lanes.append("between-conversation activity") }
        if !runtime.reflectionEnabled { lanes.append("reflection") }
        if runtime.reflectionBudget <= 0 { lanes.append("daily reflection allowance") }
        if !runtime.organismEnabled { lanes.append("moods and energy") }
        return lanes
    }

    private static func bounded(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let fallback = normalized.isEmpty ? "No detail was supplied." : normalized
        let limit = 180
        return fallback.count > limit ? String(fallback.prefix(limit)) + "…" : fallback
    }
}
