import Foundation
import PersistenceCore
import Skills
import Senses
import TrustCenter

public enum NativeSkillRegistryActions {
    public static func installDemoCapabilityPack(dataRoot: URL) async throws -> CapabilityPackInstall {
        let host = AppScriptRunner.Host(call: { _ in .null }, toolHost: true, dataRoot: dataRoot)
        return try await OwnedProgramInvocation.$host.withValue(host) {
            try await CapabilityPackInstall.installDemo(dataRoot: dataRoot)
        }
    }

    public static func deleteSkill(id: String, dataRoot: URL) async throws {
        let impl = makeSkillsClient(root: dataRoot)
        _ = try await impl.deleteSkill(id: id, ownerAuthorized: true)
    }

    /// Enable a skill. `admitScript` binds the complete candidate digest as
    /// User's (the one he reviewed, refused if any artifact changed since); an
    /// approved card binds the complete candidate, including fixtures and dependencies.
    public static func enableSkill(
        name: String, dataRoot: URL, reviewedDigest: String?, admitScript: Bool
    ) async throws {
        let host = AppScriptRunner.Host(call: { _ in .null }, toolHost: true, dataRoot: dataRoot)
        _ = try await OwnedProgramInvocation.$host.withValue(host) {
            try await SwiftNativeSkillsClient(root: dataRoot).enableSkill(
                name: name, admittedBy: admitScript ? "user" : nil, reviewedDigest: reviewedDigest, ownerAuthorized: true)
        }
    }

    public static func disableSkill(name: String, dataRoot: URL) async throws {
        _ = try await makeSkillsClient(root: dataRoot).disableSkill(name: name)
    }
}
