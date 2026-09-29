import Foundation
import PersistenceCore
import ApprovalInbox
import ApprovalTransactions
import SelfImprovement
import SystemOps

extension NativeClient {
    static let selfEvolutionAction = SelfEvolutionApprovalExecutor.selfEvolutionAction

    static func selfEvolutionDeps(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> SelfEvolutionApprovalExecutor.SelfEvolutionDeps {
        .production(dataRoot: dataRoot, platform: AppSelfEvolutionPlatform())
    }

    static func evolutionRepoRoot(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        SelfEvolutionApprovalExecutor.evolutionRepoRoot(dataRoot: dataRoot)
    }

    static func applyFullMacAdmittedSelfEvolution(
        payload: JSONValue, deps: SelfEvolutionApprovalExecutor.SelfEvolutionDeps
    ) async {
        await SelfEvolutionApprovalExecutor.applyFullMacAdmittedSelfEvolution(payload: payload, deps: deps)
    }
}

private struct AppSelfEvolutionPlatform: SelfEvolutionPlatformPort {
    var bundleURL: URL { Bundle.main.bundleURL }

    func currentBundleSha() -> String? {
        Bundle.main.resourceURL.flatMap {
            EvolutionVerifyRevert.readBundleVersionSha(resourcesDir: $0)
        }
    }

    func fireRebuild() async throws -> String {
        let result = try await makeSystemRebuildClient().systemRebuild()
        guard result.ok else {
            throw NSError(domain: "NativeAgentSelfEvolution", code: 500, userInfo: [
                NSLocalizedDescriptionKey: result.error ?? "rebuild refused"])
        }
        return result.message ?? "rebuild started"
    }

    func notify(dataRoot: URL, itemId: String, title: String, summary: String, source: String, severity: String) async {
        await InboxPushNotifier.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity)
    }
}
