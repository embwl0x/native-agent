import Foundation
import Testing
@testable import NativeAgentApp

// The Missions→Workshop naming sweep (2026-07-11) renamed Swift identifiers
// while pinning serialized keys to their original strings ("compatibility
// wire IDs"). These tests prove the pins: old-key JSON must keep decoding into
// the renamed properties, or existing local state silently loses data.
//
// P2-3 (2026-08-05) moved the ROUTING surface key from `missions` to
// `workshop`. `AgentGraphCounts` (persisted graphs/index.json) is untouched and
// still pins the old key.
@Suite("Mission wire-ID compatibility pins")
struct WireIDCompatibilityTests {

    /// Cross-vocabulary decode: a routing payload produced by 0.3.x (or an iOS
    /// build a version behind) still carries `missions`, and must land in
    /// `executions` even though the encoder now emits `workshop`.
    @Test func modelRoutingCurrentDecodesLegacyMissionsKey() throws {
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
        #expect(reencoded?["workshop"] != nil, "must emit the canonical wire key")
        #expect(reencoded?["missions"] == nil, "the legacy key is read-only now")
        #expect(reencoded?["executions"] == nil, "never the Swift property name")
    }

    /// The other direction: a payload from the current runtime, decoded by the
    /// same type. Both vocabularies must reach `executions`.
    @Test func modelRoutingCurrentDecodesCanonicalWorkshopKey() throws {
        let new = Data("""
        {"chat":{"provider":"p","model":"m","reasoningEffort":"low"},
         "telegram":{"provider":"p","model":"m","reasoningEffort":"low"},
         "workshop":{"provider":"p","model":"workshop-model","reasoningEffort":"high"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(ModelRoutingCurrent.self, from: new)
        #expect(decoded.executions?.model == "workshop-model")
    }

    /// Both keys present (an older writer racing a newer one): the canonical
    /// key wins, deterministically — never a coin flip over which model routes.
    @Test func modelRoutingCurrentPrefersCanonicalKeyWhenBothPresent() throws {
        let both = Data("""
        {"chat":{"provider":"p","model":"m","reasoningEffort":"low"},
         "telegram":{"provider":"p","model":"m","reasoningEffort":"low"},
         "missions":{"provider":"p","model":"stale-model","reasoningEffort":"low"},
         "workshop":{"provider":"p","model":"fresh-model","reasoningEffort":"high"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(ModelRoutingCurrent.self, from: both)
        #expect(decoded.executions?.model == "fresh-model")
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
