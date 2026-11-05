import Foundation
import ChatTurnContracts
import NativeAgentCore
import PersistenceCore
import DoctorChecks
import Experiences
import AttentionRouting
// Blueprint: | `BackgroundWorkPorts.swift` | Body notices tell one matter through the attention port; episode identity and owner resolution read ForPerson |

public protocol BackgroundWorkNotificationPort: Sendable {
    @discardableResult
    func tell(_ matter: Matter, dataRoot: URL, reach: AttentionRouter.Reach, turn: Turn?) async throws -> AttentionOutcome
}

public protocol MaintenanceBackgroundWorkPort: BackgroundWorkNotificationPort {
    func assistanceCard(dataRoot: URL, input: JSONValue) async throws -> AssistanceCardContent
    func backupDeadline(dataRoot: URL, input: JSONValue) async throws -> Double?
    func backupTrigger(dataRoot: URL, input: JSONValue) async throws -> BackupTrigger
    func diskStorageOwners(dataRoot: URL) -> [DiskStorageOwner]
    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> [CheckResult]
    var unavailableSkipPrefix: String { get }
    func offDiskBackupParent() -> URL
    func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)]
    func createOffDiskBackup(reason: String, dataRoot: URL, parent: URL, now: Date) async throws -> URL
}

/// An episode keeps its identity through refreshes and the person's acknowledgment; only a changed finding or an observed clear starts another.
enum BodyNotice {
    static func tell(key: String, from: String, finding: String, dataRoot: URL,
                     _ body: @escaping @Sendable (String) async throws -> Void) async throws {
        try await BodyNoticeWrites.shared.run(key: dataRoot.standardizedFileURL.path + "#" + key) {
            let id = try await episode(key: key, from: from, finding: finding, dataRoot: dataRoot)
            try await body(id)
        }
    }

    private static func episode(key: String, from: String, finding: String, dataRoot: URL) async throws -> String {
        let forPerson = ForPerson.at(dataRoot)
        let prefix = key + ":" + AttentionRouter.stableDigest(finding) + ":"
        let previous = try await forPerson.matters().first { $0.face?.from == from && $0.id.hasPrefix(key + ":") }
        if let previous, previous.progress != "resolved", previous.outcome?.domain != from, previous.id.hasPrefix(prefix) {
            return previous.id
        }
        if let previous { try await resolve(previous, dataRoot: dataRoot) }
        return prefix + UUID().uuidString.lowercased()
    }

    static func resolve(_ matter: Experience, dataRoot: URL) async throws {
        guard matter.progress != "resolved", matter.outcome?.domain != matter.face?.from else { return }
        let forPerson = ForPerson.at(dataRoot)
        // The person's terminal outcome stays theirs; the owner's clear still ends the episode after the person put it away.
        if matter.outcome != nil {
            try await ExperienceStore.at(dataRoot).append([.progress("resolved")], to: matter.id)
        }
        try await forPerson.answered(matter.id, evidence: nil, letGo: .cancelled)
        try await forPerson.putAway(matter.id, .resolved)
    }

    static func resolve(key: String, from: String, dataRoot: URL) async throws {
        try await BodyNoticeWrites.shared.run(key: dataRoot.standardizedFileURL.path + "#" + key) {
            for matter in try await ForPerson.at(dataRoot).matters()
                where matter.face?.from == from && matter.id.hasPrefix(key + ":") {
                try await resolve(matter, dataRoot: dataRoot)
            }
        }
    }
}

/// Orders publication per episode key without copying any of the owner's state.
private actor BodyNoticeWrites {
    static let shared = BodyNoticeWrites()
    private var pending: [String: (token: UUID, work: Task<Result<Void, Error>, Never>)] = [:]

    func run(key: String, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = pending[key]?.work
        let token = UUID()
        let work = Task { () -> Result<Void, Error> in
            _ = await previous?.value
            do { try await body(); return .success(()) } catch { return .failure(error) }
        }
        pending[key] = (token, work)
        let result = await work.value
        if pending[key]?.token == token { pending[key] = nil }
        try result.get()
    }
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
