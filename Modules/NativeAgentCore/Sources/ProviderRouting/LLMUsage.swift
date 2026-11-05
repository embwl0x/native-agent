import Foundation
import PersistenceCore
import NativeAgentCore
import os
import TurnTrace
// Blueprint: | `LLMUsage.swift` | Provider usage parsing, counter semantics, streaming accumulation and saturating logical input totals |

// MARK: - LLMUsage
// Field names are Anthropic-canonical; the OpenAI parsers map equivalents:   - Responses API: input_tokens / output_tokens /
// input_tokens_details.cached_tokens → cacheReadInputTokens   - Chat Completions: prompt_tokens / completion_tokens /
// prompt_tokens_details.cached_tokens → cacheReadInputTokens OpenAI write counters are subsets of input, distinct from Anthropic's additive creation count.
public struct LLMUsage: Sendable, Equatable {
    /// Set by the wire parser and retained in receipts: Anthropic counters are disjoint on every host.
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

    /// Anthropic counters are disjoint; OpenAI cached tokens are a subset of input, so adding them would double-count occupancy.
    public func logicalInputTokens(provider: String) -> Int? {
        guard let inputTokens, inputTokens >= 0 else { return nil }
        if additiveInputCounters {
            guard let read = cacheReadInputTokens, read >= 0,
                  let created = cacheCreationInputTokens, created >= 0 else { return nil }
            let (subtotal, firstOverflow) = inputTokens.addingReportingOverflow(read)
            guard !firstOverflow else { return nil }
            let (total, overflow) = subtotal.addingReportingOverflow(created)
            return overflow ? nil : total
        }
        return inputTokens
    }

    /// Counts remain unknown unless the provider gave an exact nonnegative integer.
    static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int, i >= 0 { return i }
        if let d = raw as? Double, d.isFinite, d >= 0 { return Int(exactly: d) }
        return nil
    }

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

    /// Streaming accumulator: Anthropic splits usage across `message_start` (input + cache fields) and `message_delta` (output_tokens). Later non-nil
    /// fields win; nil never clobbers a captured value.
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
