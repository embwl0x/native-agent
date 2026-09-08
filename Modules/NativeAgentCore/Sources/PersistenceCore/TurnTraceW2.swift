import Foundation
import NativeAgentCore

// MARK: - Turn Inspector W2 (turn-inspector build plan, ledger d6143561)
//
// W2 adds richer per-turn EMISSION points on top of the W1 spine
// (TurnTrace.swift): assembly.stage, stream.tick, file.touch, and the gated
// summarized-thinking lane (thinking.delta). The emission sites themselves live
// next to the code they observe (ChatOrchestration + ProviderRouting); this
// file holds the two cross-module primitives those sites need and that must
// live in the LOWEST common module (PersistenceCore):
//
//   1. TurnTraceRedactor — a compact secret scrubber shared by the thinking
//      lane and ChatOrchestration preview/trace boundaries so text is redacted
//      BEFORE it is bounded and fired onto the bus. Same redaction-at-emission
//      discipline as ChatToolDispatchTracer: redact, THEN truncate.
//
//   2. InspectorThinkingLane — the per-surface opt-in GATE for the summarized
//      thinking request-body change. A @TaskLocal default-FALSE flag (same
//      propagation mechanism as MessagesCacheHint.withinTurnReuse /
//      LLMCallContext.sessionId): the chat surface binds it TRUE around the
//      synchronous request construction ONLY when the per-surface setting is on;
//      the Anthropic adapter reads it at body-assembly time. Unbound everywhere
//      else → FALSE → the request body is BYTE-IDENTICAL to today (the U1
//      cache-prefix contract — `thinking` is part of the request body, so the
//      flag-OFF path must not add it).

// MARK: - TurnTraceRedactor

/// Compact non-digest secret scrubber shared by turn-trace and chat preview/
/// receipt projection boundaries. It intentionally includes named-secret
/// detection and omits match digests so diagnostics cannot correlate a
/// credential across events.
///
/// Used by the thinking lane in ProviderRouting. The bus already bounds every
/// string leaf (TurnTraceEvent.boundString); this adds the redaction half so a
/// token that slips under the length cap never lands in turn_traces verbatim.
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

// MARK: - InspectorThinkingLane (gated summarized-thinking opt-in)

/// Per-surface opt-in for the Turn Inspector's summarized-thinking lane.
///
/// THE U1 CONTRACT: `thinking` is part of the Anthropic request BODY. When this
/// gate is OFF (the default), the body MUST be byte-identical to pre-W2 — so the
/// default is a `@TaskLocal` that is FALSE unless a surface explicitly binds it
/// TRUE around its synchronous request construction. The Anthropic OAuth adapter
/// reads `summarizedThinking` at `makeMessagesRequestBody` time; unbound → false
/// → no `thinking` key is added → byte-identical body.
///
/// `isEnabledForSurface` is the persisted per-surface setting (Mac chat surface
/// only for now), read from `UserDefaults` under the
/// `inspectorThinkingSummarized` key. The chat-streaming engine consults it and
/// binds the task-local ONLY when both (a) the surface is the Mac chat surface
/// AND (b) the setting is on. Do NOT flip this on anywhere by default.
public enum InspectorThinkingLane {
    /// UserDefaults key for the per-surface opt-in (Mac chat only for now).
    public static let defaultsKey = "inspectorThinkingSummarized"

    /// The ONLY surface eligible for the summarized-thinking lane in W2.
    /// (W2 scope: Mac chat surface only — `surface == "chat"`.)
    public static let eligibleSurface = "chat"

    /// Request-body gate, propagated the same way as
    /// `MessagesCacheHint.withinTurnReuse`: bound TRUE around the SYNCHRONOUS
    /// request construction; the adapter's inner Task inherits it. Default
    /// FALSE → request body byte-identical to pre-W2 (no `thinking` key).
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
