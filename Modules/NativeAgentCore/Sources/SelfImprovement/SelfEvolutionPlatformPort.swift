import Foundation

/// Only the installer, running app bundle and OS notification delivery belong
/// to the host. Approval policy, persistence and recovery stay in Core.
public protocol SelfEvolutionPlatformPort: Sendable {
    var bundleURL: URL { get }
    func currentBundleSha() -> String?
    func fireRebuild() async throws -> String
    func notify(dataRoot: URL, itemId: String, title: String, summary: String, source: String, severity: String) async
}
