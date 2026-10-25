import DoctorChecks
import Foundation
import TelegramBot
import Research
import Observation
import NativeAgentCore
// Blueprint: | `RuntimeReadProjection+Configuration.swift` | `RuntimeReadProjection.Configuration`: publishes and returns its own saved SearXNG URL read; configuration reads use the engine projection and the provider owner's `LatestRead` for Codex authentication, while editors retain separate drafts |

extension RuntimeReadProjection {
    @MainActor @Observable
    public final class Configuration {
        public private(set) var searxngBaseURL = ""
        @ObservationIgnored private let latest = LatestRead()
        public nonisolated init() {}
        @discardableResult
        public func readSearXNG(dataRoot: URL) async throws -> String {
            try await latest.read({ try SwiftNativeResearchClient.checkedSearxngBaseURL(root: dataRoot) ?? "" },
                                  publish: { searxngBaseURL = $0 })
        }
    }

    public static func configuration(engine: NativeAgentEngine) async throws -> (
        searxngBaseURL: String, autoDoctor: AutoDoctorConfig,
        telegram: TelegramConfigurationSummary?, codexAuth: CodexAuthStatus?, modelRouting: ModelRoutingConfig
    ) {
        let dataRoot = engine.dataRoot
        let searxngBaseURL = try await engine.configuration.readSearXNG(dataRoot: dataRoot)
        let autoDoctor = DoctorStatusProjection.readAutoDoctorConfig(dataRoot: dataRoot)
        let telegram = await TelegramFacade(dataRoot: dataRoot).configuration()
        let codexAuth = try? await engine.providers.refreshCodexAuth()
        let modelRouting = try await ProvidersFacade.readModelRoutingConfig(dataRoot: dataRoot)
        return (searxngBaseURL, autoDoctor, telegram, codexAuth, modelRouting)
    }
}
