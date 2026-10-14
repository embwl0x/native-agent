import DoctorChecks
import Foundation
import TelegramBot

extension RuntimeReadProjection {
    public static func configuration(dataRoot: URL) async throws -> (
        searxngBaseURL: String, autoDoctor: AutoDoctorConfig,
        telegram: TelegramConfigurationSummary?, codexAuth: CodexAuthStatus?, modelRouting: ModelRoutingConfig
    ) {
        let researchPath = dataRoot.appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        let searxngBaseURL: String
        if let data = try? Data(contentsOf: researchPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = parsed["searxng_base_url"] as? String {
            searxngBaseURL = raw
        } else {
            searxngBaseURL = ""
        }
        let autoDoctor = DoctorStatusProjection.readAutoDoctorConfig(dataRoot: dataRoot)
        let telegram = await TelegramFacade(dataRoot: dataRoot).configuration()
        let codexAuth = try? await ProvidersFacade(dataRoot: dataRoot).codexAuthStatus()
        let modelRouting = try await ProvidersFacade.readModelRoutingConfig(dataRoot: dataRoot)
        return (searxngBaseURL, autoDoctor, telegram, codexAuth, modelRouting)
    }
}
