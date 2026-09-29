import Foundation
import NativeAgentCore
import BackgroundLoops
import BackgroundWork
import PersistenceCore
import ChatOrchestration
import DoctorChecks

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
        let client = NativeClient(baseURL: "", dataRootOverride: dataRoot)
        return try await DoctorActionRuntime(port: client).runDoctor(repair: true, repairScope: .automatic, checks: checks).checks
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
