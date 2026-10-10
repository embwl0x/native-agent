import EngineRuntime
import Connectors
import DoctorChecks
import TrustPersistence
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

typealias BackupRecord = TrustPersistence.BackupRecord
typealias BackupRestoreResult = TrustPersistence.BackupRestoreResult

extension TrustBackupHost {
    /// Backups and exports stamp the running app's version.
    static let app = TrustBackupHost(applicationVersion: {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    })
}

typealias ConnectorRecord = EngineRuntime.ConnectorRecord

typealias WorkspaceRecord = Connectors.WorkspaceRecord

typealias ReleaseChecklistItem = DoctorChecks.ReleaseChecklistItem

typealias ReleaseChecklist = DoctorChecks.ReleaseChecklist
