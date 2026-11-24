import Foundation
// Blueprint: | `ProviderFamilyIdentity.swift` | `ProviderFamilyIdentity` enum; `normalize` |

// Family projection for matching, not transport or adapter selection.
package enum ProviderFamilyIdentity {
    package static func normalize(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic", "anthropic_oauth_direct":
            return "anthropic"
        case "openai", "openai_oauth_direct":
            return "openai"
        case "xai_oauth_direct":
            return "xai"
        case "moonshot":
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
