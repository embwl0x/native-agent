import Foundation
import AppToolRuntime
import PersistenceCore
import ToolRegistry

/// Reads app-owned live diagnostics for Core's health-tool envelopes.
enum AppToolHealthHost {
    /// The Doctor page's rows. `repair` is its Repair button: the same run,
    /// leaving the same report on the page.
    @MainActor
    static func doctorStatus(repair: Bool) async throws -> JSONValue {
        let report: DoctorReport
        guard let appModel = QuietSelfAdmin.shared.appModel else {
            if repair { return AppToolExecutor.unattachedFailure() }
            return try await envelope(NativeClient(baseURL: "").runDoctor(repair: false))
        }
        if repair {
            if case .unavailable(let reason) = await appModel.runDoctor(repair: true, repairScope: .button) {
                return AppToolExecutor.failure("doctor_unavailable", "Repair did not run: \(reason) If checks were already running, do doctor.repair again once they finish.")
            }
            guard let repaired = appModel.engine.doctor.report else {
                return AppToolExecutor.failure("doctor_unavailable", "Repair ran but left no report. Read \(AppToolExecutor.doorDoctor) for the rows.")
            }
            report = repaired
        } else {
            let checks = try await NativeClient(baseURL: "").runDoctor(repair: false)
            report = await NativeClient.mergeDoctorReport(checks, liveChecks: DoctorStatusChecks.run(appModel: appModel, repairDesk: false).checks)
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
