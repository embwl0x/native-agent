import Foundation
import PersistenceCore
import Skills

public enum NativeSkillRegistryActions {
    public static func deleteSkill(id: String, dataRoot: URL) async throws {
        // wave 32 W15: gate to SwiftNativeSkillsClient.deleteSkill (registry
        // delete + body-file cleanup + manifest fallback + record_activity, all
        // flocked). The daemon route returns `{id, deleted:true[, source]}`;
        // the Mac caller discards the body (EmptyResponse), so we just run the
        // mutation and ignore the returned object.
        let impl = makeSkillsClient(root: dataRoot)
        _ = try await impl.deleteSkill(id: id)
    }

    /// Enable a skill. `admitScript` admits a script skill's exact digest as
    /// User's (the one he reviewed, refused if the script changed since); an
    /// approved card turns on only what needs no admission.
    public static func enableSkill(
        name: String, dataRoot: URL, reviewedDigest: String?, admitScript: Bool
    ) async throws {
        _ = try await SwiftNativeSkillsClient(root: dataRoot).enableSkill(
            name: name, admittedBy: admitScript ? "user" : nil, reviewedDigest: reviewedDigest)
    }

    public static func disableSkill(name: String, dataRoot: URL) async throws {
        _ = try await makeSkillsClient(root: dataRoot).disableSkill(name: name)
    }
}
