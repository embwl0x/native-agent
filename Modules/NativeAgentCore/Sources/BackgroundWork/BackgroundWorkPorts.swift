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
}

public protocol MaintenanceBackgroundWorkPort: BackgroundWorkNotificationPort {
    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> [CheckResult]
    var unavailableSkipPrefix: String { get }
    func autoDoctorConfig(dataRoot: URL) -> (enabled: Bool?, intervalSeconds: Int?)
    func offDiskBackupParent() -> URL
    func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)]
    func createOffDiskBackup(reason: String, dataRoot: URL, parent: URL, now: Date) async throws -> URL
    /// Skill, tool and sense retirement under the posture that allows it.
    func capabilityUpkeep(dataRoot: URL) async
}

public protocol DelegationBackgroundWorkPort: BackgroundWorkEventPort, BackgroundWorkNotificationPort {
    func retryRequestedResults(dataRoot: URL) async throws
    var agentSubject: String { get }
    func observeMotorActionState(_ model: MotorActionReadModel) async
    func reconcileAgentConversations() async throws
    func nextConversationDeadline(after now: Date) -> Date?
}
