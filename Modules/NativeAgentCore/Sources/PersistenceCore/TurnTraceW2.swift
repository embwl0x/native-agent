import Foundation

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
    private static let patterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            (
                "PRIVATE_KEY",
                "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                [.dotMatchesLineSeparators]
            ),
            ("GITHUB_TOKEN", "\\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\\b", []),
            ("OPENAI_KEY", "\\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\\b", []),
            ("ANTHROPIC_KEY", "\\bsk-ant-[A-Za-z0-9_-]{20,}\\b", []),
            ("STRIPE_KEY", "\\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\\b", []),
            ("SLACK_TOKEN", "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b", []),
            ("GOOGLE_API_KEY", "\\bAIza[0-9A-Za-z_-]{25,}\\b", []),
            ("BEARER_TOKEN", "\\bBearer\\s+[A-Za-z0-9._~+/=-]{20,}\\b", [.caseInsensitive]),
            (
                "NAMED_SECRET",
                "((?:OPENAI|ANTHROPIC|GH|GITHUB|API|TOKEN|SECRET|PASSWORD)[\\w]*[_\\s-]*(?:KEY|TOKEN|SECRET|PASSWORD)?\\s*[=:]\\s*)[^\\s\"']{8,}",
                [.caseInsensitive]
            ),
        ]
        return specs.map { kind, pattern, options in
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
                preconditionFailure("TurnTraceRedactor pattern failed: \(kind)")
            }
            return (kind, re)
        }
    }()

    public static func redactText(_ value: String) -> String {
        var text = value
        for (kind, re) in patterns {
            let ns = text as NSString
            let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                text = (text as NSString).replacingCharacters(
                    in: match.range,
                    with: "[REDACTED_\(kind)]"
                )
            }
        }
        return text
    }

    public static func redactValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            return .string(redactText(string))
        case .array(let items):
            return .array(items.map { redactValue($0) })
        case .object(let object):
            return .object(object.mapValues { redactValue($0) })
        default:
            return value
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
