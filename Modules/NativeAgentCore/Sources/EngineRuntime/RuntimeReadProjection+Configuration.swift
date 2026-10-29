import DoctorChecks
import Foundation
import TelegramBot
import Research
import Observation
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
// Blueprint: | `RuntimeReadProjection+Configuration.swift` | `RuntimeReadouts.Configuration`: publishes and returns its own saved SearXNG URL read; configuration reads use the engine projection and the provider owner's `LatestRead` for Codex authentication, while editors retain separate drafts |

extension RuntimeReadouts {
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

    public static func configuration(engine: NativeAgentEngine) async throws {
        let dataRoot = engine.dataRoot
        try await engine.configuration.readSearXNG(dataRoot: dataRoot)
        _ = try? await engine.providers.refreshCodexAuth()
        _ = try await engine.providers.routing.checkedRoutingSnapshot()
    }
}
