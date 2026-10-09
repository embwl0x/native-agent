import Foundation
import NativeAgentCore
import PersistenceCore
import DoctorChecks

public protocol BackgroundWorkEventPort: Sendable {
    func storeAndFileEvents(paths: [URL], loopId: String?) -> AsyncStream<Void>
}

public protocol BackgroundWorkNotificationPort: Sendable {
    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String,
        summary: String, source: String, severity: String
    ) async
}

public protocol HeartbeatBackgroundWorkPort: BackgroundWorkEventPort, BackgroundWorkNotificationPort {
    var selfEvolutionAction: String { get }
    func applyFullMacAdmittedSelfEvolution(payload: JSONValue, dataRoot: URL) async
    func evolutionRepoRoot(dataRoot: URL) -> URL
}

public protocol MaintenanceBackgroundWorkPort: BackgroundWorkNotificationPort {
    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> [CheckResult]
    var unavailableSkipPrefix: String { get }
    func autoDoctorConfig(dataRoot: URL) -> (enabled: Bool?, intervalSeconds: Int?)
    func offDiskBackupParent() -> URL
    func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)]
    func createOffDiskBackup(reason: String, dataRoot: URL, parent: URL, now: Date) async throws -> URL
}

public protocol DelegationBackgroundWorkPort: BackgroundWorkEventPort, BackgroundWorkNotificationPort {
    func retryRequestedResults(dataRoot: URL) async throws
    var agentSubject: String { get }
    func observeMotorActionState(_ model: MotorActionReadModel) async
    func reconcileAgentConversations() async throws
    func nextConversationDeadline(after now: Date) -> Date?
}
