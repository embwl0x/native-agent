import Foundation
import PersistenceCore
import NativeAgentCore
import os
import TurnTrace
// Blueprint: | `LLMUsage.swift` | Provider usage parsing, counter semantics, streaming accumulation and saturating logical input totals |

// MARK: - LLMUsage
//
// Field names are Anthropic-canonical; the OpenAI parsers map equivalents:
//   - Responses API: input_tokens / output_tokens /
//     input_tokens_details.cached_tokens → cacheReadInputTokens
//   - Chat Completions: prompt_tokens / completion_tokens /
//     prompt_tokens_details.cached_tokens → cacheReadInputTokens
// OpenAI write counters are subsets of input, distinct from Anthropic's additive creation count.
public struct LLMUsage: Sendable, Equatable {
    /// Set by the wire parser and retained in receipts: Anthropic counters
    /// are disjoint on every host.
    public var additiveInputCounters: Bool
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var cacheWriteInputTokens: Int?
    public var cacheWrite30mInputTokens: Int?
    public var cacheWrite12hInputTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil,
        cacheWrite30mInputTokens: Int? = nil,
        cacheWrite12hInputTokens: Int? = nil,
        additiveInputCounters: Bool = false
    ) {
        self.additiveInputCounters = additiveInputCounters
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.cacheWrite30mInputTokens = cacheWrite30mInputTokens
        self.cacheWrite12hInputTokens = cacheWrite12hInputTokens
    }

    public var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil
            && cacheReadInputTokens == nil && cacheCreationInputTokens == nil
            && cacheWriteInputTokens == nil && cacheWrite30mInputTokens == nil && cacheWrite12hInputTokens == nil
    }

    /// Retained receipts use their explicit flag or the provider's known counter shape.
    public static func persistedAdditiveInputCounters(_ value: JSONValue?, provider: String) -> Bool {
        if case .bool(let flag)? = value { return flag }
        return provider.lowercased().contains("anthropic")
    }

    /// Logical input occupancy for one provider request.
    ///
    /// Anthropic reports uncached, cache-read, and cache-created input as
    /// disjoint counters. OpenAI-compatible APIs report `inputTokens` as the
    /// total and expose cached tokens only as a subset, so adding that subset
    /// would double-count it.
    public func logicalInputTokens(provider: String) -> Int? {
        let hasAnyInput = inputTokens != nil
            || cacheReadInputTokens != nil
            || cacheCreationInputTokens != nil
        guard hasAnyInput else { return nil }

        if additiveInputCounters {
            // Nonnegative usage totals saturate at Int.max on overflow.
            func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
                let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
                return overflowed ? Int.max : sum
            }
            var total = max(0, inputTokens ?? 0)
            total = saturatingAdd(total, max(0, cacheReadInputTokens ?? 0))
            total = saturatingAdd(total, max(0, cacheCreationInputTokens ?? 0))
            return total
        }
        return max(0, inputTokens ?? 0)
    }

    /// Int/Double wire counts return nil or clamp for malformed values without trapping.
    static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double {
            guard d.isFinite else { return nil }
            if d >= Double(Int.max) { return Int.max }
            if d <= Double(Int.min) { return Int.min }
            return Int(d)
        }
        return nil
    }

    /// Anthropic Messages API `usage` object (non-streaming response body,
    /// or streaming `message_start.message.usage` / `message_delta.usage`).
    public static func fromAnthropic(_ obj: [String: Any]?) -> LLMUsage {
        guard let obj else { return LLMUsage() }
        return LLMUsage(
            inputTokens: intValue(obj["input_tokens"]),
            outputTokens: intValue(obj["output_tokens"]),
            cacheReadInputTokens: intValue(obj["cache_read_input_tokens"]),
            cacheCreationInputTokens: intValue(obj["cache_creation_input_tokens"]),
            additiveInputCounters: true
        )
    }

    /// OpenAI Responses API `response.usage` (arrives on the
    /// `response.completed` SSE event).
    public static func fromOpenAIResponses(_ obj: [String: Any]?) -> LLMUsage {
        guard let obj else { return LLMUsage() }
        let details = obj["input_tokens_details"] as? [String: Any]
        let writes = details?["cache_write_tokens_details"] as? [String: Any]
        return LLMUsage(
            inputTokens: intValue(obj["input_tokens"]),
            outputTokens: intValue(obj["output_tokens"]),
            cacheReadInputTokens: intValue(details?["cached_tokens"]),
            cacheWriteInputTokens: intValue(details?["cache_write_tokens"]),
            cacheWrite30mInputTokens: intValue(writes?["ttl_30m_tokens"]),
            cacheWrite12hInputTokens: intValue(writes?["ttl_12h_tokens"])
        )
    }

    /// OpenAI Chat Completions `usage` (api-key adapter, non-streaming).
    public static func fromOpenAIChatCompletions(_ obj: [String: Any]?) -> LLMUsage {
        guard let obj else { return LLMUsage() }
        let details = obj["prompt_tokens_details"] as? [String: Any]
        return LLMUsage(
            inputTokens: intValue(obj["prompt_tokens"]),
            outputTokens: intValue(obj["completion_tokens"]),
            cacheReadInputTokens: intValue(details?["cached_tokens"]),
            cacheCreationInputTokens: nil
        )
    }

    /// Streaming accumulator: Anthropic splits usage across `message_start`
    /// (input + cache fields) and `message_delta` (output_tokens). Later
    /// non-nil fields win; nil never clobbers a captured value.
    public mutating func merge(_ other: LLMUsage) {
        additiveInputCounters = additiveInputCounters || other.additiveInputCounters
        if let v = other.inputTokens { inputTokens = v }
        if let v = other.outputTokens { outputTokens = v }
        if let v = other.cacheReadInputTokens { cacheReadInputTokens = v }
        if let v = other.cacheCreationInputTokens { cacheCreationInputTokens = v }
        if let v = other.cacheWriteInputTokens { cacheWriteInputTokens = v }
        if let v = other.cacheWrite30mInputTokens { cacheWrite30mInputTokens = v }
        if let v = other.cacheWrite12hInputTokens { cacheWrite12hInputTokens = v }
    }
}
