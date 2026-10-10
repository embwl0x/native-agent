import Foundation
import Research

@MainActor
extension AppModel {
    /// SearXNG is a real external service. Write it to the canonical research
    /// store first, then update the observable preference so failed validation
    /// or persistence never replaces a working URL in the UI.
    @discardableResult
    func saveSearXNGBaseURL(_ value: String) async throws -> String {
        let normalized = try SwiftNativeResearchClient.normalizedSearXNGBaseURL(value)
        try await SwiftNativeResearchClient(dataRoot: engine.dataRoot).saveSearXNGBaseURL(normalized)
        searxngBaseURL = normalized
        return normalized
    }

    /// Config refreshes are reads, not permission to replace a working local
    /// setting with malformed endpoint text. Missing configuration leaves the
    /// current value alone; malformed non-empty configuration remains visible
    /// as unavailable and preserves the last committed endpoint.
    @discardableResult
    func applyRefreshedSearXNGBaseURL(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        do {
            searxngBaseURL = try SwiftNativeResearchClient.normalizedSearXNGBaseURL(value)
            return true
        } catch {
            statusText = "SearXNG configuration unavailable: \(error.localizedDescription)"
            return false
        }
    }
}
