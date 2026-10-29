// Blueprint: | `RuntimeHealth.swift` | RuntimeHealth: shared runtime liveness metadata; lifecycle facts remain with their owners |

import Foundation

public struct RuntimeHealth: Codable, Hashable, Sendable {
    public var ok: Bool
    public var app: String
    public var version: String
    public var dataDir: String
    public var uptimeSeconds: Double

    public init(ok: Bool, app: String, version: String, dataDir: String, uptimeSeconds: Double) {
        self.ok = ok
        self.app = app
        self.version = version
        self.dataDir = dataDir
        self.uptimeSeconds = uptimeSeconds
    }
}
