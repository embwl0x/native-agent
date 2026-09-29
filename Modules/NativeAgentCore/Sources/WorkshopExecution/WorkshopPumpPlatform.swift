import Foundation

/// Resource and artifact access supplied by the pump's platform host.
public protocol WorkshopPumpPlatform: Sendable {
    func isUnderResourcePressure() -> Bool
    func artifactIsReadable(dataRoot: URL, handle: String, relativePath: String) -> Bool
    func validateArtifactComponent(_ value: String) throws -> String
}
