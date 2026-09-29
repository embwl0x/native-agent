/// Platform metadata read at the point a backup manifest is written.
/// Launch coordination and restore choices remain with the calling app.
public struct TrustBackupHost: Sendable {
    public let applicationVersion: @Sendable () -> String

    public init(applicationVersion: @escaping @Sendable () -> String) {
        self.applicationVersion = applicationVersion
    }
}
