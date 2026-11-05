// Blueprint: | `MacIntegrationAccess.swift` | `MacIntegrationAccess`, `MacIntegrationPermissionMode`: a tool's declared integration and axis |

public enum MacIntegrationPermissionMode: String, Sendable, Codable {
    case read
    case write
}

/// Local declaration only; the permission store remains the authority for the named integration's switches.
public struct MacIntegrationAccess: Sendable, Equatable {
    public let integration: String
    public let mode: MacIntegrationPermissionMode

    public init(_ integration: String, _ mode: MacIntegrationPermissionMode) {
        self.integration = integration
        self.mode = mode
    }
}
