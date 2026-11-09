import Foundation
// Blueprint: | `ConnectorSetup.swift` | Canonical connector identity, entry routes and Slack allowlist text parsing |

public enum ConnectorSetup: String, Sendable, Equatable {
    case manualToken
    case unavailable

    public static func canonicalID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func resolve(_ raw: String) -> Self {
        switch canonicalID(raw) {
        case "slack", "telegram": .manualToken
        default: .unavailable
        }
    }
}

public enum ConnectorWizardSetupRoute: Equatable, Sendable {
    case manualToken
    case unavailable

    public static func resolve(provider: String) -> Self {
        let id = ConnectorSetup.canonicalID(provider)
        return switch ConnectorSetup.resolve(id) {
        case .manualToken where id == "slack": .manualToken
        case .manualToken, .unavailable: .unavailable
        }
    }
}

public enum SlackAllowlist {
    public static func parseIDs(_ raw: String) -> Set<String> {
        Set(raw.split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }
}
