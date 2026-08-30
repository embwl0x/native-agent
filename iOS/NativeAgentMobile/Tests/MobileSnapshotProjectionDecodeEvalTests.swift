import Foundation
import NativeAgentShared
import XCTest
@testable import NativeAgentMobile

/// iOS consumption proof for the exact bytes asserted by
/// MobileSnapshotProjectionEvalTests on the Mac writer side.
@MainActor
final class MobileSnapshotProjectionDecodeEvalTests: XCTestCase {
    func test_exactMacFixturesFlowThroughRealIOSLoadersAndMalformedFilesFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("b09-ios-mobile-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = iCloudSyncEngine.shared
        let priorSnapshotDir = engine.snapshotDir
        let priorHealth = engine.health
        let priorOrganism = engine.organismLivingStatus
        let priorLastSyncAt = engine.lastSyncAt
        let priorSyncError = engine.syncError
        defer {
            engine.snapshotDir = priorSnapshotDir
            engine.health = priorHealth
            engine.organismLivingStatus = priorOrganism
            engine.lastSyncAt = priorLastSyncAt
            engine.syncError = priorSyncError
        }

        let fixtures = try MobileEvalSources.repoRoot()
            .appendingPathComponent("tests/fixtures/mobile_snapshot_projection", isDirectory: true)
        try Data(contentsOf: fixtures.appendingPathComponent("organism_living_status.json"))
            .write(to: root.appendingPathComponent("organism_living_status.json"), options: .atomic)
        try Data(#"{"app":"NativeAgent","dataDir":"fixture","ok":true,"uptimeSeconds":1,"version":"test"}"#.utf8)
            .write(to: root.appendingPathComponent("health.json"), options: .atomic)
        try Data(contentsOf: fixtures.appendingPathComponent("turn_summaries.json"))
            .write(to: root.appendingPathComponent("turn_summaries.json"), options: .atomic)

        engine.snapshotDir = root
        engine.health = nil
        engine.organismLivingStatus = nil
        engine.lastSyncAt = nil
        engine.syncError = "fixture not loaded"
        let completeOutcome = await engine.refreshHealthSnapshot()
        XCTAssertEqual(completeOutcome, .refreshed)

        let organism = try XCTUnwrap(engine.organismLivingStatus)
        XCTAssertEqual(organism.generatedAt, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(organism.availabilityState, .live)
        XCTAssertEqual(organism.posture, "careful")
        XCTAssertEqual(organism.counters.fieldNodes, 7)
        XCTAssertEqual(organism.reflexCandidates?.map(\.id), ["review-candidate"])
        XCTAssertNotNil(engine.health)
        XCTAssertNil(engine.syncError)

        let turns: TurnSummaryFile? = await engine.loadSnapshotObjectAsync(
            named: "turn_summaries.json",
            as: TurnSummaryFile.self
        )
        XCTAssertEqual(turns?.totalTurnsSeen, 2)
        XCTAssertEqual(turns?.summaries.map(\.id), ["turn-new", "turn-old"])
        XCTAssertEqual(turns?.summaries.first?.kinds["other"], 1)
        XCTAssertEqual(turns?.summaries.first?.llmTokens, 10)

        // Adverse controls: a wrong required organism type must clear the prior
        // mobile projection, and a missing required turn id must reject the
        // complete object rather than render a plausible partial card.
        try Data(#"{"enabled":"true"}"#.utf8)
            .write(to: root.appendingPathComponent("organism_living_status.json"), options: .atomic)
        let partialOutcome = await engine.refreshHealthSnapshot()
        XCTAssertEqual(partialOutcome, .partial)
        XCTAssertNil(engine.organismLivingStatus)
        XCTAssertNotNil(engine.health)
        XCTAssertEqual(engine.syncError, "Some Health snapshots are still downloading from iCloud.")

        try Data("not json".utf8)
            .write(to: root.appendingPathComponent("health.json"), options: .atomic)
        try FileManager.default.removeItem(at: root.appendingPathComponent("organism_living_status.json"))
        let unavailableOutcome = await engine.refreshHealthSnapshot()
        XCTAssertEqual(unavailableOutcome, .unavailable)
        XCTAssertNil(engine.health)
        XCTAssertNil(engine.organismLivingStatus)

        try Data(#"{"summaries":[{"eventCount":1}],"totalTurnsSeen":1,"truncated":false}"#.utf8)
            .write(to: root.appendingPathComponent("turn_summaries.json"), options: .atomic)
        let malformedTurns: TurnSummaryFile? = await engine.loadSnapshotObjectAsync(
            named: "turn_summaries.json",
            as: TurnSummaryFile.self
        )
        XCTAssertNil(malformedTurns)
    }
}
