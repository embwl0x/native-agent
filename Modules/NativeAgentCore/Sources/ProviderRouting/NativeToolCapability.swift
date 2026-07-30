import Foundation

/// SINGLE AUTHORITATIVE PREDICATE for "may this provider receive a native
/// `tools` array on the wire?" (2026-07-20, docs/build_plans/kimi-native-tools.md).
///
/// Today exactly ONE provider qualifies: `kimi-code`. Kimi's coding endpoint is
/// built for Claude-Code-style requests and was live-probed on 2026-07-20
/// serving the full Anthropic tools contract (tool_use blocks, tool_result
/// round-trip, parallel calls, streaming input_json_delta).
///
/// EVERY other provider — most importantly the Claude OAuth-direct adapters —
/// stays on the text-compatibility marker protocol. That is not an oversight:
/// sending provider-native `tools[]` on a Claude subscription connection is a
/// documented behavioral risk in this repo's history, so the OAuth adapters
/// must NEVER be handed a tools array by the native lane. Keeping the answer in
/// one function (instead of scattered `providerId == "kimi-code"` checks) is
/// what makes that guarantee auditable.
///
/// Future providers (e.g. moonshot via OpenAI function calling) opt in HERE,
/// after their own live wire probe — never by a caller-local special case.
public enum NativeToolCapability {
    /// True only for providers whose wire contract we have probed and wired.
    public static func providerSupportsNativeTools(_ providerId: String?) -> Bool {
        guard let providerId else { return false }
        let normalized = providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return normalized == "kimi-code"
    }

    /// Model-id fallback for callers that only know the requested model (the
    /// chat loop resolves provider id first and uses this only as a backstop).
    /// Mirrors the model→provider mapping in LLMClient+Real.swift.
    public static func modelImpliesNativeToolProvider(_ model: String?) -> Bool {
        guard let model else { return false }
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower)
    }
}
