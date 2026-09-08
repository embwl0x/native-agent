import Foundation

// Family projection for matching, not transport or adapter selection.
package enum ProviderFamilyIdentity {
    package static func normalize(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic", "anthropic_oauth_direct", "anthropic_mcp":
            return "anthropic"
        case "openai", "openai_oauth_direct":
            return "openai"
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai"
        case "moonshot", "kimi":
            return "moonshot"
        case "openrouter":
            return "openrouter"
        case "codex":
            return "codex"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
