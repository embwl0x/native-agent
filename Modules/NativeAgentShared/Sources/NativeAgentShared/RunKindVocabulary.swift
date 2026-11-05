// Blueprint: | `RunKindVocabulary.swift` | Safe display vocabulary for extensible run kinds; platforms own unknown symbols |

/// Unknown run-kind identifiers must never reach product text; each platform owns its display wording.
public enum RunKindVocabulary {
    public enum Surface: Sendable {
        case mac
        case iOS
    }

    public static func symbol(_ kind: String) -> String? {
        switch kind.lowercased() {
        case "codex": return "terminal"
        case "claude": return "sparkles"
        default: return nil
        }
    }

    public static func displayName(_ kind: String, on surface: Surface) -> String {
        switch kind.lowercased() {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        default: return "Other run"
        }
    }
}
