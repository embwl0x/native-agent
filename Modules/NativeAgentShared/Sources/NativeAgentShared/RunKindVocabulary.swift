// Blueprint: | `RunKindVocabulary.swift` | Safe display names for extensible run kinds |

/// Unknown run-kind identifiers must never reach product text; each platform owns its display wording.
public enum RunKindVocabulary {
    public static func displayName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "mission": return "Mission"
        case "rem_weekly_consolidation": return "REM consolidation"
        default: return "Other run"
        }
    }
}
