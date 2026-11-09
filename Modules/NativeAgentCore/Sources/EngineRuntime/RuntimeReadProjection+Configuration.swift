import DoctorChecks
import Foundation
import TelegramBot
import Research
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
// Blueprint: | `RuntimeReadProjection+Configuration.swift` | `RuntimeReadouts.Configuration`, `LatestRead`; Checked saved configuration |

extension RuntimeReadouts {
    @MainActor
    public final class Configuration {
        public var searxngBaseURL: String { checkedSearchURL ?? "" }
        private let latest = LatestRead()
        private var settingsFeed: SettingsFeedProjection?
        private var checkedSearchURL: String?
        private var searchIssue: String?
        public func bindSettingsFeed(_ feed: SettingsFeedProjection) {
            settingsFeed = feed
            feed.updateSearch(checkedSearchURL, issue: searchIssue)
        }
        public nonisolated init() {}
        @discardableResult
        public func readSearXNG(dataRoot: URL) async throws -> String {
            let result: Result<String, Error> = await latest.read({
                await Task.detached(priority: .userInitiated) {
                    Result { try SwiftNativeResearchClient.checkedSearxngBaseURL(root: dataRoot) ?? "" }
                }.value
            }, publish: { result in
                switch result {
                case .success(let value):
                    checkedSearchURL = value
                    searchIssue = nil
                case .failure(let error): searchIssue = error.localizedDescription
                }
                settingsFeed?.updateSearch(checkedSearchURL, issue: searchIssue)
            })
            return try result.get()
        }
    }

    public static func configuration(engine: NativeAgentEngine) async throws {
        let dataRoot = engine.dataRoot
        try await engine.configuration.readSearXNG(dataRoot: dataRoot)
        _ = try? await engine.providers.refreshCodexAuth()
        _ = try await engine.providers.routing.checkedRoutingSnapshot()
    }
}
