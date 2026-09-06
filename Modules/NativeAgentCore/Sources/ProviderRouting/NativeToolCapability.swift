import Foundation

/// SINGLE AUTHORITATIVE PREDICATE for "may this provider receive a native
/// `tools` array on the wire?" (2026-07-20, docs/build_plans/kimi-native-tools.md;
/// extended 2026-09-01, docs/build_plans/fable51-sweep-2026-09-01.md item 34).
///
/// TWO providers qualify, and the difference between them is the whole point
/// of this file:
///
///   * `kimi-code` — Kimi's coding endpoint, built for Claude-Code-style
///     requests, live-probed 2026-07-20 serving the full Anthropic tools
///     contract (tool_use blocks, tool_result round-trip, parallel calls,
///     streaming input_json_delta).
///   * `anthropic` — the Anthropic **API-KEY** adapter (api.anthropic.com/v1
///     /messages with `x-api-key`). This is the documented public Messages API:
///     `tools[]` is its published contract, not a harness tell. Opted in
///     2026-09-01 so Claude turns on the api-key path stop parsing tool calls
///     out of prose.
///
/// EVERY other provider — most importantly the Claude OAUTH-DIRECT adapter
/// (`anthropic_oauth_direct`) — stays on the text-compatibility marker
/// protocol. That is not an oversight: Anthropic's subscription connection
/// runs a harness detector that rejects a request body carrying `tools`, so
/// the OAuth adapter must NEVER be handed a tools array by the native lane.
/// Keeping the answer in one function (instead of scattered
/// `providerId == "…"` checks) is what makes that guarantee auditable — and
/// it is why the api-key opt-in below is spelled as an EXACT id match on the
/// api-key provider id rather than a "starts with anthropic" test, which would
/// have swept the OAuth id in with it.
///
/// Future providers (e.g. moonshot via OpenAI function calling) opt in HERE,
/// after their own live wire probe — never by a caller-local special case.
public enum NativeToolCapability {
    /// Provider ids whose wire contract we have probed and wired. Exact,
    /// normalized ids only — see the OAuth note above for why no prefix or
    /// family match is allowed here.
    private static let nativeToolProviderIDs: Set<String> = [
        "kimi-code",
        "anthropic",
    ]

    /// True only for providers whose wire contract we have probed and wired.
    public static func providerSupportsNativeTools(_ providerId: String?) -> Bool {
        guard let providerId else { return false }
        return nativeToolProviderIDs.contains(normalized(providerId))
    }

    /// Shared id folding: trims, lowercases, and treats `_` as `-` so
    /// "kimi_code" and "KIMI-CODE " resolve like "kimi-code". Deliberately does
    /// NOT collapse provider families (LLMClient+Real's `normalizeProviderId`
    /// maps `anthropic_oauth_direct` → `anthropic` for ADAPTER CHOICE; doing
    /// that here would hand the OAuth connection a tools array).
    private static func normalized(_ providerId: String) -> String {
        providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    /// Model-id fallback for callers that only know the requested model (the
    /// chat loop resolves provider id first and uses this only as a backstop).
    /// Mirrors the model→provider mapping in LLMClient+Real.swift.
    ///
    /// DELIBERATELY kimi-only, and it must stay that way: a `claude-*` model id
    /// says nothing about WHICH Claude transport is bound — the same id is
    /// served by the api-key adapter and by the OAuth-direct adapter. Admitting
    /// Claude model ids here would let the backstop turn an OAuth turn native.
    /// The api-key path opts in through `providerSupportsNativeTools` on a
    /// resolved PROVIDER id only.
    public static func modelImpliesNativeToolProvider(_ model: String?) -> Bool {
        guard let model else { return false }
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FirstPartyModelCatalog.kimiCodeModelIDSet.contains(lower)
    }
}

/// User, 2026-09-06: "is an OAuth adapter WIRED?" and "is a user SIGNED IN to
/// it?" are different questions, and the unpinned model-prefix fallback in
/// `LLMClient+Real.resolveAdapterAndModel` used to answer the second with the
/// first. Production constructs every OAuth adapter unconditionally, so a user
/// whose only Anthropic credential was an API key had `claude-*` routed to
/// `anthropic_oauth_direct` and got `notConfigured` from a provider it never
/// asked for. Each direct adapter answers for its own credential file, honoring
/// the path override it was built with.
protocol OAuthCredentialPresence {
    var hasStoredOAuthCredential: Bool { get }
}

extension AnthropicOAuthDirectAdapter: OAuthCredentialPresence {}
extension OpenAIOAuthDirectAdapter: OAuthCredentialPresence {}
extension XAIOAuthDirectAdapter: OAuthCredentialPresence {}
