import Foundation
import NativeAgentCore
import BackgroundLoops
import BackgroundWork
import PersistenceCore
import ChatOrchestration
import DoctorChecks
import NotificationInbox
import AttentionRouting

// App composition delegates background decisions and receipts to Core.
extension BackgroundLoopsAssembly {
    static func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil,
        freshMeasurement: Bool = false
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).makeAutoDoctorLoop(dataRoot: dataRoot, intervalSeconds: intervalSeconds, freshMeasurement: freshMeasurement)
    }

    static func makeTurnTraceRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).makeTurnTraceRetentionLoop(dataRoot: dataRoot, intervalSeconds: intervalSeconds)
    }

    static func makeOffDiskBackupLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).makeOffDiskBackupLoop(dataRoot: dataRoot)
    }

    static func selfImprovementSwitchOn() -> Bool {
        MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).selfImprovementSwitchOn()
    }

    static func makeWeeklySelfImprovementLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> WeeklySelfImprovementLoop {
        MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).makeWeeklySelfImprovementLoop(dataRoot: dataRoot, llm: llm)
    }

    static func makeEvolutionProposalRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> EvolutionProposalRetentionLoop {
        MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).makeEvolutionProposalRetentionLoop(dataRoot: dataRoot)
    }

    static func makeDataRootDiskHygieneLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DataRootDiskHygieneCheck {
        MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).makeDataRootDiskHygieneLoop(dataRoot: dataRoot)
    }

    static func fileDiskHygieneNotice(dataRoot: URL, report: DiskHygieneReport) async -> Bool {
        await MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).fileDiskHygieneNotice(dataRoot: dataRoot, report: report)
    }

    static func cleanUpDiskHygiene(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        try await MaintenanceBackgroundWork(port: AppBackgroundWorkPort()).cleanUpDiskHygiene(dataRoot: dataRoot)
    }
}

extension AppBackgroundWorkPort: MaintenanceBackgroundWorkPort {
    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> [CheckResult] {
        let client = NativeClient(dataRootOverride: dataRoot)
        let rows = try await DoctorActionRuntime(port: client).runDoctor(repair: true, repairScope: .automatic, checks: checks).checks
        let asksFiled = await Self.fileDoctorAsk(dataRoot: dataRoot, rows: rows)
        NativeClient.acknowledgeDoctorTransitions(rows, asksFiled: asksFiled)
        return rows
    }

    /// What Doctor could not repair itself — sign-ins and permissions — goes
    /// to User as ONE inbox card listing every step. The card updates in place,
    /// keeps his read/dismiss status while the list is unchanged, and is
    /// archived and marked cleared once nothing is left to ask.
    static func fileDoctorAsk(dataRoot: URL, rows: [CheckResult]) async -> Bool {
        let cardID = "doctor-ask"
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        let asks = rows.filter(DoctorSafeRepairPolicy.isUserAsk).compactMap { row in
            row.human_action.map { "• \(row.title): \($0)" }
        }.sorted()
        do {
            guard !asks.isEmpty else {
                // Cleared whatever User did with the card (read, archived or
                // dismissed), so a recurrence surfaces fresh.
                let uncleared = try await inbox.rows().contains { row in
                    guard case .object(let card) = row, card["id"] == .string(cardID) else { return false }
                    return card["resolved_reason"] != .string("doctor_clear")
                }
                if uncleared {
                    try await inbox.updateStatus(id: cardID, status: "archived", readAt: nil,
                                                 metadata: ["resolved_reason": .string("doctor_clear")])
                }
                return true
            }
            let detail = asks.joined(separator: "\n")
            let now = ISO8601DateFormatter().string(from: Date())
            let title = asks.count == 1 ? "Doctor needs one thing from you" : "Doctor needs \(asks.count) things from you"
            let newOccurrence = try await inbox.upsert(id: cardID) { existing in
                var card: [String: JSONValue] = [
                    "id": .string(cardID),
                    "created_at": .string(now),
                    "source": .string("doctor_ask"),
                    "severity": .string("actionable"),
                    "title": .string(title),
                    "summary": .string("Sign-ins and permissions Doctor cannot do itself."),
                    "detail": .string(detail),
                    "related_mission_id": .null,
                    "related_approval_id": .null,
                    "related_paths": .array([]),
                    "related_groups": .array([]),
                    "actions": .array([
                        .object(["id": .string("archive"), "label": .string("Archive"),
                                 "description": .string("Archive this card")]),
                        .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                                 "description": .string("Dismiss this card")]),
                    ]),
                    "status": .string("unread"),
                    "read_at": .null,
                ]
                // Same list User already saw: keep his status, no resurfacing.
                if case .object(let previous)? = existing, previous["detail"] == .string(detail),
                   previous["resolved_reason"] != .string("doctor_clear") {
                    for key in ["status", "read_at", "created_at"] {
                        if let value = previous[key] { card[key] = value }
                    }
                    return (.object(card), false)
                }
                return (.object(card), true)
            }
            // Card filing acknowledges Doctor's transition independently of
            // transport acceptance. Unread failed sends remain eligible.
            do {
                guard let value = try await inbox.rows().first(where: {
                    if case .object(let card) = $0 { return card["id"] == .string(cardID) }
                    return false
                }), case .object(let card) = value, card["detail"] == .string(detail),
                    newOccurrence || card["status"] == .string("unread"),
                    case .string(let createdAt)? = card["created_at"] else { return true }
                let eventID = "\(cardID):\(createdAt):\(AttentionRouter.stableDigest(detail))"
                try await AttentionRouter.shared.route(
                    eventId: eventID, importance: .ownerWaiting, title: title, body: detail,
                    userInfo: ["screen": "inbox", "source": "doctor_ask", "itemId": cardID, "dedupKey": eventID]
                )
            } catch {
                nativeLog("[Doctor] sign-in ask push failed: %@", error.localizedDescription)
            }
            return true
        } catch {
            nativeLog("[Doctor] sign-in ask card write failed: %@", error.localizedDescription)
            return false
        }
    }

    var unavailableSkipPrefix: String { DoctorLoopHealth.unavailableSkipPrefix }

    func autoDoctorConfig(dataRoot: URL) -> (enabled: Bool?, intervalSeconds: Int?) {
        let config = NativeClient.readAutoDoctorConfig(dataRoot: dataRoot)
        return (config.enabled, config.intervalSeconds)
    }

    func offDiskBackupParent() -> URL { NativeClient.offDiskBackupParent() }

    func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)] {
        try NativeClient.offDiskAutomaticBackups(in: parent)
    }

    func createOffDiskBackup(reason: String, dataRoot: URL, parent: URL, now: Date) async throws -> URL {
        try await NativeClient.createOffDiskBackup(reason: reason, dataRoot: dataRoot, parent: parent, now: now)
    }
}
