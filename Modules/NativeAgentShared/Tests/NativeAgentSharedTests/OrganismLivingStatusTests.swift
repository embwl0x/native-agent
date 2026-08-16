import Foundation
import Testing
@testable import NativeAgentShared

@Suite("Shared organism living-status transport")
struct OrganismLivingStatusTests {
    @Test("legacy status without later optional fields still decodes")
    func legacyProjectionDecodes() throws {
        let data = Data(#"""
        {
          "generatedAt": 0,
          "enabled": true,
          "posture": "steady",
          "behaviorLine": "careful",
          "needsUser": false,
          "signalCount": 2,
          "body": {
            "macAwake": true,
            "iPhoneReachable": false,
            "providersHealthy": true,
            "memoryHealthy": true,
            "dreamHealthy": true,
            "toolHandsAvailable": true,
            "approvalChannelsOpen": true,
            "notificationPathHealthy": true,
            "resourcePressure": "normal"
          },
          "counters": {
            "fieldNodes": 3,
            "pendingPredictions": 1,
            "dreamRepairs": 0,
            "reflexCandidates": 0,
            "reflexesNeedReview": 0
          }
        }
        """#.utf8)

        let status = try JSONDecoder().decode(OrganismLivingStatusFile.self, from: data)

        #expect(status.needsAttention == nil)
        #expect(status.reflexCandidates == nil)
        #expect(status.standingViewProposals == nil)
        #expect(status.counters.approvedReflexBiases == nil)
        #expect(status.counters.standingViewProposals == nil)
    }

    @Test("current Mac projection preserves the established wire keys")
    func currentProjectionRoundTrips() throws {
        let status = OrganismLivingStatusFile(
            generatedAt: Date(timeIntervalSinceReferenceDate: 42),
            enabled: true,
            posture: "steady",
            bodyLine: "settled",
            behaviorLine: "careful / verify / bounded",
            needsUser: false,
            needsAttention: true,
            signalCount: 4,
            lastSignalAt: nil,
            body: OrganismLivingBodyFile(
                macAwake: true,
                iPhoneReachable: true,
                providersHealthy: true,
                memoryHealthy: true,
                dreamHealthy: true,
                toolHandsAvailable: true,
                approvalChannelsOpen: true,
                notificationPathHealthy: true,
                resourcePressure: "normal"
            ),
            counters: OrganismLivingCountersFile(
                fieldNodes: 7,
                pendingPredictions: 2,
                dreamRepairs: 1,
                reflexCandidates: 3,
                reflexesNeedReview: 1,
                approvedReflexBiases: 2,
                standingViewProposals: 1
            ),
            reflexCandidates: [],
            standingViewProposals: []
        )

        let data = try JSONEncoder().encode(status)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let counters = try #require(object["counters"] as? [String: Any])

        #expect(object["needsUser"] as? Bool == false)
        #expect(object["needsAttention"] as? Bool == true)
        #expect(object["reflexCandidates"] != nil)
        #expect(object["standingViewProposals"] != nil)
        #expect(counters["approvedReflexBiases"] as? Int == 2)
        #expect(counters["standingViewProposals"] as? Int == 1)
        #expect(try JSONDecoder().decode(OrganismLivingStatusFile.self, from: data) == status)
    }
}
