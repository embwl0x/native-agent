import Foundation
import NativeAgentCore
import PersistenceCore
import DoctorChecks
// Blueprint: | `BackgroundWorkPorts.swift` | Background effect ports; typed content-only `AssistanceCardContent`, `BackupTrigger` and maintenance part invocation seams |

public protocol BackgroundWorkNotificationPort: Sendable {
    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String,
        summary: String, source: String, severity: String
    ) async
}

public protocol MaintenanceBackgroundWorkPort: BackgroundWorkNotificationPort {
    func assistanceCard(dataRoot: URL, input: JSONValue) async throws -> AssistanceCardContent
    func backupDeadline(dataRoot: URL, input: JSONValue) async throws -> Double?
    func backupTrigger(dataRoot: URL, input: JSONValue) async throws -> BackupTrigger
    func diskStorageOwners(dataRoot: URL) -> [DiskStorageOwner]
    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> [CheckResult]
    func routeDoctorAsk(eventID: String, title: String, detail: String) async throws
    var unavailableSkipPrefix: String { get }
    func offDiskBackupParent() -> URL
    func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)]
    func createOffDiskBackup(reason: String, dataRoot: URL, parent: URL, now: Date) async throws -> URL
}

/// Editable content only. Identity, action eligibility, saved scope and delivery
/// stay with the native card owner.
public struct AssistanceCardContent: Codable, Sendable {
    public let title: String
    public let summary: String
    public let detail: String
}

public enum BackupTrigger: String, Codable, Sendable {
    case daily
    case identity = "identity change"
    case current
}

public protocol DelegationBackgroundWorkPort: BackgroundWorkNotificationPort {
    func letGoReplies(deliveryIDs: Set<String>, outcome: String, dataRoot: URL, configRoot: URL) async throws
    func reconcileReplyDeliveries(dataRoot: URL) async throws
    func retryRequestedResults(dataRoot: URL) async throws
    var agentSubject: String { get }
    func observeMotorActionState(_ model: MotorActionReadModel) async
    func reconcileAgentConversations() async throws
    func stopAgentConversations() async
    func nextConversationDeadline(after now: Date) -> Date?
}
