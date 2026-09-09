import Foundation

/// The Settings row is a receipt for the effective runtime configuration, not
/// a restatement of the toggle's requested value. In particular, the
/// reflection route and every resident lane must be live before the UI calls
/// Subconscious "running".
enum SlimSettingsSubconsciousStatusLine {
    enum Recovery: Equatable {
        case configureProvider
        case selectModel
        case reapply
    }

    enum Tone: Equatable {
        case neutral
        case progress
        case healthy
        case warning
        case unavailable
    }

    struct State: Equatable {
        let text: String
        let detail: String?
        let tone: Tone
        let systemImage: String
        var recovery: Recovery? = nil

        var requiresAttention: Bool {
            switch tone {
            case .warning, .unavailable:
                true
            case .neutral, .progress, .healthy:
                false
            }
        }
    }

    static func state(
        runtime: NativeSubconsciousRuntimeState?,
        reflectionRoute: NativeReflectionRouteStatus?,
        enableRequested: Bool = false
    ) -> State {
        guard let runtime else {
            return State(
                text: "Checking background activity…",
                detail: nil,
                tone: .progress,
                systemImage: "hourglass"
            )
        }

        guard runtime.enabled || enableRequested else {
            return State(text: "Off", detail: nil, tone: .neutral, systemImage: "circle")
        }

        guard let reflectionRoute else {
            return State(
                text: "Checking the reflection model…",
                detail: nil,
                tone: .progress,
                systemImage: "hourglass"
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
                systemImage: "exclamationmark.triangle.fill",
                recovery: reflectionRoute.providerReady ? .selectModel : .configureProvider
            )
        }

        let inactiveLanes = inactiveLaneNames(runtime)
        guard inactiveLanes.isEmpty else {
            return State(
                text: "Not active: " + inactiveLanes.joined(separator: ", ") + ". Try enabling again.",
                detail: nil,
                tone: .warning,
                systemImage: "exclamationmark.triangle.fill",
                recovery: .reapply
            )
        }

        return State(
            text: "Running with " + bounded(reflectionRoute.model),
            detail: nil,
            tone: .healthy,
            systemImage: "checkmark.circle.fill"
        )
    }

    private static func inactiveLaneNames(_ runtime: NativeSubconsciousRuntimeState) -> [String] {
        var lanes: [String] = []
        if !runtime.enabled { lanes.append("background activity") }
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
