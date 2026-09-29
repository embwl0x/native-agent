import Foundation
import AppToolRuntime
import PersistenceCore
import ToolRegistry

/// Reads app-owned live diagnostics for Core's health-tool envelopes.
enum AppToolHealthHost {
    static func doctorStatus() async throws -> JSONValue {
        let client = NativeClient(baseURL: "")
        let report = try await client.runDoctor(repair: false)
        return try await AppToolExecutor.doctorStatus(report: report) { dataRoot in
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
