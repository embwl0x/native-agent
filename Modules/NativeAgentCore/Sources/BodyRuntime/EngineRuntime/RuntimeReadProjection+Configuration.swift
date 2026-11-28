import Foundation
import MacNerves
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
// Blueprint: | `RuntimeReadProjection+Configuration.swift` | `RuntimeReadouts.Configuration`; Checked search and routing configuration reads |

extension RuntimeReadouts {
    public final class Configuration: Sendable {
        public nonisolated init() {}

        @discardableResult
        @concurrent public nonisolated func readSearXNG(dataRoot: URL) async throws -> String {
            try SwiftNativeResearchClient.checkedSearxngBaseURL(root: dataRoot) ?? ""
        }
    }

    public static func configuration(engine: NativeAgentEngine) async throws {
        let dataRoot = engine.dataRoot
        try await engine.configuration.readSearXNG(dataRoot: dataRoot)
        _ = try await engine.providers.routing.checkedRoutingSnapshot()
    }
}
