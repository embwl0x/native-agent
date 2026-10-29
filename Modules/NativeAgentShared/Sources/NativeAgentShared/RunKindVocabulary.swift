// Blueprint: | `RunKindVocabulary.swift` | Shared safe display names and recognized symbols for extensible run-kind wire values; unknown symbols stay platform-owned |

/// Human-facing vocabulary for the durable `RunRecord.kind` wire field.
///
/// The field remains forward-compatible rather than a closed enum, so readers
/// must never expose an unknown raw identifier as product text. Mac and iOS
/// intentionally retain their existing wording for the legacy `mission` kind
/// while sharing the compatibility and fallback rules.
public enum RunKindVocabulary {
    public enum Surface: Sendable {
        case mac
        case iOS
    }

    public static func symbol(_ kind: String) -> String? {
        switch kind.lowercased() {
        case "codex": return "terminal"
        case "claude": return "sparkles"
        case "swarm": return "circle.hexagongrid.fill"
        case "mission": return "target"
        default: return nil
        }
    }

    public static func displayName(_ kind: String, on surface: Surface) -> String {
        switch kind.lowercased() {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "swarm": return "Swarm"
        case "mission":
            switch surface {
            case .mac: return "Desk"
            case .iOS: return "Workshop"
            }
        default: return "Other run"
        }
    }
}
