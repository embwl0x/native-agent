import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `TurnTraceW2.swift` | `TurnTraceRedactor` and `InspectorThinkingLane`: shared trace redaction and per-surface summarized-thinking visibility gate |

// Shared trace/preview redaction runs before bounding and bus emission.
// Summarized thinking is a per-surface display opt-in; provider requests and
// liveness are independent.

// MARK: - TurnTraceRedactor

/// Compact non-digest secret scrubber shared by turn-trace and chat preview/
/// receipt projection boundaries. It intentionally includes named-secret
/// detection and omits match digests so diagnostics cannot correlate a
/// credential across events.
///
/// Local traces may retain bounded, credential-redacted content previews.
/// Compact dispatch receipts and phone summaries carry narrower projections.
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

/// Per-surface opt-in for the Turn Inspector's summarized-thinking lane.
///
/// `isEnabledForSurface` is the persisted per-surface setting (Mac chat surface
/// only for now), read from `UserDefaults` under the
/// `inspectorThinkingSummarized` key. The chat-streaming engine consults it and
/// binds the task-local ONLY when both (a) the surface is the Mac chat surface
/// AND (b) the setting is on. Do NOT flip this on anywhere by default.
public enum InspectorThinkingLane {
    /// UserDefaults key for the per-surface opt-in (Mac chat only for now).
    public static let defaultsKey = "inspectorThinkingSummarized"

    /// Only the Mac chat surface is eligible for summarized thinking.
    public static let eligibleSurface = "chat"

    /// Display gate inherited by the adapter's inner Task; it controls only
    /// thinking.delta emission to the Inspector bus.
    @TaskLocal public static var summarizedThinking: Bool = false

    /// True when the persisted per-surface setting is on AND `surface` is the
    /// eligible Mac chat surface. Pure read; defaults to FALSE on any
    /// non-eligible surface or unset key. `defaults` is injectable for tests.
    public static func isEnabledForSurface(
        _ surface: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard surface == eligibleSurface else { return false }
        return defaults.bool(forKey: defaultsKey)
    }
}
