import Foundation
// Blueprint: | `TrustBackupHost.swift` | `TrustBackupHost`; running-bundle version factory |

/// Platform metadata read at the point a backup manifest is written.
/// Launch coordination and restore choices remain with the calling app.
public struct TrustBackupHost: Sendable {
    public let applicationVersion: @Sendable () -> String

    public init(applicationVersion: @escaping @Sendable () -> String) {
        self.applicationVersion = applicationVersion
    }
}

extension TrustBackupHost {
    /// Backups and exports stamp the running app's version.
    public static let app = TrustBackupHost(applicationVersion: {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    })
}
