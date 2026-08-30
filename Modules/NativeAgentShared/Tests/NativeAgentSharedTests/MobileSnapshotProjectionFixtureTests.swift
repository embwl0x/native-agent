import Foundation
import Testing
@testable import NativeAgentShared

@Suite("B09 shared mobile snapshot fixture")
struct MobileSnapshotProjectionFixtureTests {
    @Test("the exact Mac organism fixture decodes through the shared wire contract")
    func exactMacOrganismFixtureDecodesAndMalformedRequiredFieldsFail() throws {
        let data = try fixture(named: "organism_living_status.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(OrganismLivingStatusFile.self, from: data)

        #expect(status.generatedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(status.availabilityState == .live)
        #expect(status.posture == "careful")
        #expect(status.behaviorLine == "receiptRequired / verifyBeforeRetry / conserve")
        #expect(status.needsAttention == true)
        #expect(status.signalCount == 12)
        #expect(status.body.providersHealthy == false)
        #expect(status.body.resourcePressure == "elevated")
        #expect(status.counters == OrganismLivingCountersFile(
            fieldNodes: 7,
            pendingPredictions: 2,
            dreamRepairs: 3,
            reflexCandidates: 1,
            reflexesNeedReview: 1,
            approvedReflexBiases: 0,
            standingViewProposals: 1
        ))
        #expect(status.reflexCandidates?.map(\.id) == ["review-candidate"])
        #expect(status.standingViewProposals?.map(\.id) == ["standing-proposal"])

        var malformed = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        malformed["enabled"] = "true"
        let malformedData = try JSONSerialization.data(withJSONObject: malformed)
        #expect(throws: (any Error).self) {
            try decoder.decode(OrganismLivingStatusFile.self, from: malformedData)
        }
    }

    private func fixture(named name: String) throws -> Data {
        let testFile = URL(fileURLWithPath: #filePath)
        let repo = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repo
            .appendingPathComponent("tests/fixtures/mobile_snapshot_projection", isDirectory: true)
            .appendingPathComponent(name))
    }
}
