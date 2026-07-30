import Foundation
import Testing
@testable import NativeAgentApp

// The Missions→Workshop naming sweep (2026-07-11) renamed Swift identifiers
// while pinning serialized keys to their original strings ("compatibility
// wire IDs"). These tests prove the two pins the sweep review caught missing:
// old-key JSON must keep decoding into the renamed properties, and encoding
// must keep emitting the old key, or existing local state silently loses data.
@Suite("Mission wire-ID compatibility pins")
struct WireIDCompatibilityTests {

    @Test func modelRoutingCurrentKeepsMissionsKey() throws {
        let old = Data("""
        {"chat":{"provider":"p","model":"m","reasoningEffort":"low"},
         "telegram":{"provider":"p","model":"m","reasoningEffort":"low"},
         "missions":{"provider":"p","model":"workshop-model","reasoningEffort":"high"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(ModelRoutingCurrent.self, from: old)
        #expect(decoded.executions?.model == "workshop-model")

        let reencoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)
        ) as? [String: Any]
        #expect(reencoded?["missions"] != nil, "must emit the wire key, not the Swift name")
        #expect(reencoded?["executions"] == nil)
    }

    @Test func agentGraphCountsKeepsMissionsKey() throws {
        let old = Data(#"{"nodes":3,"edges":2,"missions":7}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentGraphCounts.self, from: old)
        #expect(decoded.executions == 7)

        let reencoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)
        ) as? [String: Any]
        #expect(reencoded?["missions"] as? Int == 7, "persisted graphs/index.json key must not drift")
        #expect(reencoded?["executions"] == nil)
    }
}
