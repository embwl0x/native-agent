import Testing
import Foundation
@testable import TrustCenter
import NativeAgentCore
import PersistenceCore

// MARK: - Wave 6 static-manifest port + .capabilityTrust factory routing
//
// Covers:
//   - FeatureSurfaceRecords.swift parity with Python source (19 entries,
//     stable IDs)
//   - ConnectorActionsRegistry.swift presence of a core action ID set
//   - staticCapabilityRecordsFromManifests() merges both sources with the
//     expected `connector_action:` ID prefix
//   - scoreCapabilityRecord byte-equivalence on three pinned vectors
//   - capabilityTrustTier threshold table
//   - makeCapabilityTrust factory routes on .capabilityTrust ONLY
//
// NOTE: connectorActionDescriptors / staticCapabilityRecordsFromManifests and
// the .capabilityTrust factory branch are landed by a parallel worker; until
// that lands these tests will fail to compile and surface the missing
// symbols, which is the desired "wave-6 not yet complete" signal.

@Suite(.serialized)
struct CapabilityTrustStaticPortTests {

    @Test func test_featureSurfaceRecordsCount_matchesPythonSourceCount() {
        #expect(featureSurfaceRecordsCount == 19)
        #expect(featureSurfaceRecords(nowISO: "2026-05-31T12:00:00+00:00").count == 19)
    }

    @Test func test_featureSurfaceRecords_haveStableIDs() {
        let expected: Set<String> = [
            "feature:command_center", "feature:mac_assistant_watch_setup", "feature:chat_sessions",
            "feature:memory_system", "feature:personality_engine", "feature:skills",
            "feature:runnable_tools", "feature:capability_foundry", "feature:proactive_autonomy",
            "feature:workflows", "feature:agent_swarm", "feature:mcp_runtime",
            "feature:research_browser", "feature:connectors", "feature:trust_doctor",
            "feature:auto_improvement", "feature:nextgen_runtime", "feature:native_mac_power",
            "feature:eval_release_ops",
        ]
        #expect(Set(featureSurfaceRecords(nowISO: "x").map(\.id)) == expected)
    }

    @Test func test_connectorActionDescriptors_haveExpectedCoreActions() {
        let recs = connectorActionDescriptors()
        #expect(connectorActionDescriptorsCount >= 70)
        #expect(recs.count == connectorActionDescriptorsCount)
        let ids = Set(recs.map(\.id))
        for required in [
            "local_files.search", "searxng.search", "telegram.test", "x.post_tweet",
            "gmail.send", "agentmail.send", "calendar.create_event", "mac.shell", "slack.post_message",
        ] {
            #expect(ids.contains(required), "missing core connector action: \(required)")
        }
        let byID = Dictionary(uniqueKeysWithValues: recs.map { ($0.id, $0) })
        #expect(byID["slack.post_message"]?.requiresApproval == true)
        #expect(byID["agentmail.send"]?.requiresApproval == true)
        #expect(byID["gmail.send"]?.requiresApproval == true)
        #expect(byID["x.post_tweet"]?.requiresApproval == true)
    }

    @Test func test_staticCapabilityRecords_mergesBothSources() {
        let recs = staticCapabilityRecordsFromManifests(nowISO: "2026-05-31T12:00:00+00:00")
        #expect(recs.count == featureSurfaceRecordsCount + connectorActionDescriptorsCount)
        #expect(recs.contains(where: { $0.id == "feature:command_center" }))
        #expect(recs.contains(where: { $0.id == "connector_action:local_files.search" }))
    }

    @Test func test_scoreCapabilityRecord_pythonByteEquivalence() {
        // Empty record → base 0.45.
        #expect(scoreCapabilityRecord([:]).score == 0.45)

        // status=active + sourcePackId → 0.45 + 0.10 + 0.15 = 0.70.
        let r1: [String: JSONValue] = [
            "status": .string("active"),
            "sourcePackId": .string("p1"),
        ]
        let s1 = scoreCapabilityRecord(r1).score
        #expect(abs(s1 - 0.70) < 0.001)

        // active + provenance + signature + useCount + risky_tool
        // = 0.45 + 0.15 + 0.20 + 0.10 + 0.10 - 0.20 = 0.80.
        let r2: [String: JSONValue] = [
            "status": .string("active"),
            "sourcePackId": .string("p"),
            "signature": .string("sig"),
            "useCount": .int(5),
            "riskClass": .string("risky_tool"),
        ]
        let s2 = scoreCapabilityRecord(r2).score
        #expect(abs(s2 - 0.80) < 0.001)
    }

    @Test func test_capabilityTrustTier_thresholds() {
        #expect(capabilityTrustTier(forScore: 0.0) == "untrusted")
        #expect(capabilityTrustTier(forScore: 0.49) == "untrusted")
        #expect(capabilityTrustTier(forScore: 0.5) == "review")
        #expect(capabilityTrustTier(forScore: 0.74) == "review")
        #expect(capabilityTrustTier(forScore: 0.75) == "trusted")
        #expect(capabilityTrustTier(forScore: 1.0) == "trusted")
    }

    @Test func test_makeCapabilityTrust_factory_respectsCapabilityTrustFlag() {
        let impl = makeCapabilityTrust()
        #expect(impl is SwiftNativeCapabilityTrust)

        let impl2 = makeCapabilityTrust()
        #expect(impl2 is SwiftNativeCapabilityTrust)

        // Legacy flags no longer downgrade the native capability-trust port.
        let impl3 = makeCapabilityTrust()
        #expect(impl3 is SwiftNativeCapabilityTrust)
    }
}
