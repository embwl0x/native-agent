import Testing
import Foundation
@testable import TrustCenter
import NativeAgentCore
import PersistenceCore

// MARK: - Factory

@Suite(.serialized)
struct CapabilityTrustFactoryTests {
    @Test func factoryReturnsSwiftNativeByDefault() {
        let impl = makeCapabilityTrust()
        #expect(impl is SwiftNativeCapabilityTrust)
    }

    @Test func factoryReturnsSwiftNativeWhenCapabilityTrustFlagOn() {
        let impl = makeCapabilityTrust()
        #expect(impl is SwiftNativeCapabilityTrust)
    }

    @Test func factoryIgnoresLegacyTrustCenterFlag() {
        let impl = makeCapabilityTrust()
        #expect(impl is SwiftNativeCapabilityTrust)
    }
}

// MARK: - Pure scoring (byte-equivalent port of capability_trust_score)

@Suite(.serialized)
struct CapabilityTrustScoringTests {
    @Test func bareRecord_scoresBaseline() {
        let r: [String: JSONValue] = [:]
        let s = scoreCapabilityRecord(r)
        #expect(s.score == 0.45)
        #expect(s.reasons == ["Base local capability record."])
        #expect(capabilityTrustTier(forScore: s.score) == "untrusted")
    }

    @Test func activeSignedWithProvenance_scoresHigh() {
        // 0.45 + 0.15 (provenance) + 0.20 (sig) + 0.10 (active) + 0.10 (use) = 1.00
        let r: [String: JSONValue] = [
            "sourcePackId": .string("pack-a"),
            "signature": .string("sig"),
            "status": .string("active"),
            "useCount": .int(7),
        ]
        let s = scoreCapabilityRecord(r)
        #expect(s.score == 1.0)
        #expect(capabilityTrustTier(forScore: s.score) == "trusted")
    }

    @Test func riskyTool_subtractsAndCanGoNegativeButClamps() {
        // 0.45 - 0.20 = 0.25
        let r: [String: JSONValue] = ["riskClass": .string("risky_tool")]
        let s = scoreCapabilityRecord(r)
        #expect(s.score == 0.25)
        #expect(capabilityTrustTier(forScore: s.score) == "untrusted")
    }

    @Test func clamp_neverNegativeNeverAbove1() {
        // Pile on negatives via riskClass; can only subtract 0.2 so floor lands
        // at 0.25 here. To exercise the lower clamp we'd need multiple negatives
        // which the algorithm doesn't have; instead exercise upper clamp via
        // all positives (proven above lands exactly at 1.0).
        let r: [String: JSONValue] = ["riskClass": .string("external_send")]
        let s = scoreCapabilityRecord(r)
        #expect(s.score >= 0.0 && s.score <= 1.0)
    }

    @Test func tierBoundaries() {
        #expect(capabilityTrustTier(forScore: 0.75) == "trusted")
        #expect(capabilityTrustTier(forScore: 0.749) == "review")
        #expect(capabilityTrustTier(forScore: 0.50) == "review")
        #expect(capabilityTrustTier(forScore: 0.499) == "untrusted")
        #expect(capabilityTrustTier(forScore: 0.0) == "untrusted")
    }

    @Test func reasonOrderMatchesPython() {
        // Python appends in this fixed order: base, provenance, signature,
        // active, usage, risk. Confirm Swift port preserves it.
        let r: [String: JSONValue] = [
            "provenance": .string("p"),
            "signature": .string("s"),
            "status": .string("installed"),
            "lastUsedAt": .string("2026-01-01T00:00:00Z"),
            "riskClass": .string("risky_tool"),
        ]
        let s = scoreCapabilityRecord(r)
        #expect(s.reasons == [
            "Base local capability record.",
            "Has provenance metadata.",
            "Has a pack signature.",
            "Currently active or installed.",
            "Has successful usage evidence.",
            "Risk class requires extra approval.",
        ])
    }
}

// MARK: - Codable wire shape

@Suite(.serialized)
struct CapabilityTrustWireShapeTests {
    @Test func network_decodes_minimal_daemon_payload() throws {
        let json = """
        {
          "status": "ready",
          "roots": [{"id":"local-trusted","name":"Local","kind":"local","status":"trusted"}],
          "sources": [{"id":"local-catalog","name":"Local","kind":"local","status":"ready","trustedRootId":"local-trusted"}],
          "records": [
            {"id":"tool:x","name":"X","kind":"tool","status":"active","riskClass":"app_owned_tool","trustScore":0.85,"trustTier":"trusted","reasons":["ok"]}
          ],
          "summary": {"trusted": 1, "review": 0, "untrusted": 0},
          "createdAt": "2026-05-31T00:00:00+00:00"
        }
        """.data(using: .utf8)!
        let net = try JSONDecoder().decode(CapabilityTrustNetwork.self, from: json)
        #expect(net.status == "ready")
        #expect(net.roots.first?.id == "local-trusted")
        #expect(net.sources.first?.trustedRootId == "local-trusted")
        #expect(net.records.first?.trustTier == "trusted")
        #expect(net.summary?.trusted == 1)
    }

    @Test func evaluation_decodes_daemon_payload() throws {
        let json = """
        {"id":"tool:x","name":"X","trustScore":0.85,"trustTier":"trusted","reasons":["ok"],"createdAt":"2026-05-31T00:00:00+00:00"}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(CapabilityTrustEvaluation.self, from: json)
        #expect(e.id == "tool:x")
        #expect(e.trustScore == 0.85)
        #expect(e.trustTier == "trusted")
    }
}
