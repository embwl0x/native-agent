// Blueprint: | `RuntimeHealth.swift` | RuntimeHealth: shared runtime liveness metadata; lifecycle facts remain with their owners |

import Foundation

public struct RuntimeHealth: Codable, Hashable, Sendable {
    public var ok: Bool
    public var app: String
    public var version: String
    public var dataDir: String
    /// The engine's launch, independent of when health is read or drawn.
    public var launchedAt: Date

    public init(ok: Bool, app: String, version: String, dataDir: String, launchedAt: Date) {
        self.ok = ok
        self.app = app
        self.version = version
        self.dataDir = dataDir
        self.launchedAt = launchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case ok, app, version, dataDir, launchedAt, startedAt, uptimeSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Existing Mac snapshots carry the same launch fact under startedAt. A damaged launchedAt must still fail.
        let launchedAt: Date
        if values.contains(.launchedAt) {
            launchedAt = try values.decode(Date.self, forKey: .launchedAt)
        } else {
            launchedAt = try values.decode(Date.self, forKey: .startedAt)
        }
        self.init(ok: try values.decode(Bool.self, forKey: .ok),
                  app: try values.decode(String.self, forKey: .app),
                  version: try values.decode(String.self, forKey: .version),
                  dataDir: try values.decode(String.self, forKey: .dataDir), launchedAt: launchedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ok, forKey: .ok)
        try values.encode(app, forKey: .app)
        try values.encode(version, forKey: .version)
        try values.encode(dataDir, forKey: .dataDir)
        try values.encode(launchedAt, forKey: .launchedAt)
        // Installed phones 61/63 require these keys. Their elapsed sample belongs to this encoding, never health equality.
        try values.encode(launchedAt, forKey: .startedAt)
        try values.encode(max(0, Date().timeIntervalSince(launchedAt)), forKey: .uptimeSeconds)
    }
}
