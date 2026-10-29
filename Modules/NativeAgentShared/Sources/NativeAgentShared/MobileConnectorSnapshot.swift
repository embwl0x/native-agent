// Blueprint: | `MobileConnectorSnapshot.swift` | MobileConnectorSnapshot: credential-free connector state and available phone controls |

import Foundation

public struct MobileConnectorSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String?
    public var enabled: Bool?
    public var healthStatus: String?
    public var updatedAt: String?
    public var authState: String?
    public var canToggle: Bool?
    public var canDisconnect: Bool?
    public var supportsSetup: Bool?
    public init(id: String, name: String, kind: String? = nil, enabled: Bool? = nil,
                healthStatus: String? = nil, updatedAt: String? = nil, authState: String? = nil,
                canToggle: Bool? = nil, canDisconnect: Bool? = nil, supportsSetup: Bool? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled
        self.healthStatus = healthStatus; self.updatedAt = updatedAt; self.authState = authState
        self.canToggle = canToggle; self.canDisconnect = canDisconnect; self.supportsSetup = supportsSetup
    }
}
