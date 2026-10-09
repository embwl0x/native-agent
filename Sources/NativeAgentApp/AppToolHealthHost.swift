import Foundation
import AppToolRuntime
import PersistenceCore
import ToolRegistry

/// Reads app-owned live diagnostics for Core's health-tool envelopes.
enum AppToolHealthHost {
    /// Read the last report, or explicitly run checks (false) or repair (true).
    @MainActor
    static func doctorStatus(repair: Bool?) async throws -> JSONValue {
        guard let appModel = QuietSelfAdmin.shared.appModel else {
            return AppToolExecutor.unattachedFailure()
        }
        if let repair {
            if case .unavailable(let reason) = await appModel.runDoctor(repair: repair, repairScope: .button) {
                return AppToolExecutor.failure("doctor_unavailable", "Doctor did not run: \(reason)")
            }
        }
        guard let report = appModel.engine.doctor.report else {
            return AppToolExecutor.failure("doctor_not_run", "No Doctor report yet. Run doctor.run, then read this page.")
        }
        return try await envelope(report)
    }

    private static func envelope(_ report: DoctorReport) async throws -> JSONValue {
        try await AppToolExecutor.doctorStatus(report: report) { dataRoot in
            try await ProvidersFacade(dataRoot: dataRoot).list().map {
                AppToolProviderHealth(providerID: $0.provider_id, authState: $0.auth_status.state)
            }
        }
    }

    static func telegramStatus() async throws -> JSONValue {
        let status = try await TelegramFacade(dataRoot: PersistenceCore.defaultDataRoot()).load()
        return AppToolExecutor.telegramStatusEnvelope(status: status, now: Date())
    }
}
