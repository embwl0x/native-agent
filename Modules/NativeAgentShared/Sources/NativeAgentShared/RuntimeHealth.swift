// Blueprint: | `RuntimeHealth.swift` | RuntimeHealth: Doctor verdict, independent runtime reachability and report availability |

import Foundation

public struct RuntimeHealth: Codable, Hashable, Sendable {
    public var ok: Bool
    /// Missing reachability or Doctor metadata in a retained snapshot is unknown, independent of its ok verdict.
    public var reachable: Bool?
    public var doctorStatus: String?
    public var doctorIssue: String?
    public var app: String
    public var version: String
    public var dataDir: String
    /// The engine's launch, independent of when health is read or drawn.
    public var launchedAt: Date

    public init(ok: Bool, reachable: Bool?, doctorStatus: String?, doctorIssue: String?,
                app: String, version: String, dataDir: String, launchedAt: Date) {
        self.ok = ok
        self.reachable = reachable
        self.doctorStatus = doctorStatus
        self.doctorIssue = doctorIssue
        self.app = app
        self.version = version
        self.dataDir = dataDir
        self.launchedAt = launchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case ok, reachable, doctorStatus, doctorIssue, app, version, dataDir, launchedAt, startedAt, uptimeSeconds
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
                  reachable: try values.decodeIfPresent(Bool.self, forKey: .reachable),
                  doctorStatus: try values.decodeIfPresent(String.self, forKey: .doctorStatus),
                  doctorIssue: try values.decodeIfPresent(String.self, forKey: .doctorIssue),
                  app: try values.decode(String.self, forKey: .app),
                  version: try values.decode(String.self, forKey: .version),
                  dataDir: try values.decode(String.self, forKey: .dataDir), launchedAt: launchedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ok, forKey: .ok)
        try values.encodeIfPresent(reachable, forKey: .reachable)
        try values.encodeIfPresent(doctorStatus, forKey: .doctorStatus)
        try values.encodeIfPresent(doctorIssue, forKey: .doctorIssue)
        try values.encode(app, forKey: .app)
        try values.encode(version, forKey: .version)
        try values.encode(dataDir, forKey: .dataDir)
        try values.encode(launchedAt, forKey: .launchedAt)
        // Installed phones 61/63 require these keys. Their elapsed sample belongs to this encoding, never health equality.
        try values.encode(launchedAt, forKey: .startedAt)
        try values.encode(max(0, Date().timeIntervalSince(launchedAt)), forKey: .uptimeSeconds)
    }
}
