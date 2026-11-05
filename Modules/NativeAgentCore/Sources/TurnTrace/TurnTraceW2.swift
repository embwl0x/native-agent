import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `TurnTraceW2.swift` | `TurnTraceRedactor`, `InspectorThinkingLane`: Redaction and opt-in display |

// Shared trace/preview redaction runs before bounding and bus emission. Summarized thinking is a per-surface display opt-in; provider requests and liveness are
// independent.

// MARK: - TurnTraceRedactor

/// Scrub named secrets without digests so diagnostics cannot correlate credentials across events. Local previews stay bounded and redacted; compact receipts
/// and phone summaries expose narrower projections.
public enum TurnTraceRedactor {
    public static func redactText(_ value: String) -> String {
        TurnSecretRedactor.redactText(value)
    }

    public static func redactValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            return .object(Dictionary(uniqueKeysWithValues: fields.map { key, value in
                (key, TurnSecretRedactor.isCredentialName(key) ? .string("[REDACTED_NAMED_SECRET]") : redactValue(value))
            }))
        case .array(let values): return .array(values.map(redactValue))
        case .string(let text): return .string(redactText(text))
        default: return value
        }
    }
}

// MARK: - InspectorThinkingLane (summarized-thinking display opt-in)

private enum InspectorThinkingPart: LLMCallPart { static let unset = false }

extension LLMCall {
    /// The request's display opt-in, held through provider tasks and callbacks.
    public var inspectorThinkingSummarized: Bool {
        get { self[InspectorThinkingPart.self] }
        set { self[InspectorThinkingPart.self] = newValue }
    }
}

/// Summarized-thinking visibility is an explicit model-call choice, enabled only for the Mac chat surface.
public enum InspectorThinkingLane {
    public static let defaultsKey = "inspectorThinkingSummarized"

    /// Other surfaces cannot opt into this display.
    public static let eligibleSurface = "chat"

    /// Unset preferences and ineligible surfaces stay disabled; reading the display gate must not change provider behavior.
    public static func isEnabledForSurface(
        _ surface: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard surface == eligibleSurface else { return false }
        return defaults.bool(forKey: defaultsKey)
    }
}
