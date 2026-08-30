import CognitiveSubstrate
import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Ledger rows:
/// - feeds.turn_summaries.snapshot
/// - store.snapshots/organism_living_status.json
///
/// These are production-path evals, not source-shape checks. They feed isolated
/// owner inputs through MacSyncEngine's real projection encoders and coordinated
/// digest-aware writer, then compare the exact bytes published under the two
/// canonical mobile snapshot filenames.
@Suite("B09 mobile snapshot projection", .serialized)
struct MobileSnapshotProjectionEvalTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    @Test("fixture traces become the exact bounded turn_summaries.json production snapshot")
    func turnSummarySourceProjectsAndWritesExactSnapshot() async throws {
        let root = try temporaryRoot("turn-summaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

        let today = TurnTraceReplayReader.fileURL(for: now, root: root)
        let yesterdayDate = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let yesterday = TurnTraceReplayReader.fileURL(for: yesterdayDate, root: root)
        try FileManager.default.createDirectory(
            at: today.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let currentEvents = [
            event(
                turn: "turn-new",
                kind: "assembly.stage",
                at: now,
                surface: "ios",
                session: "session-new"
            ),
            event(
                turn: "turn-new",
                kind: "llm.call",
                at: now.addingTimeInterval(1),
                surface: "ios",
                session: "session-new",
                payload: .object([
                    "inputTokens": .int(7),
                    "outputTokens": .int(3),
                    "ttftMs": .int(120),
                ])
            ),
            event(
                turn: "turn-new",
                kind: "private marker must never cross the snapshot boundary",
                at: now.addingTimeInterval(2),
                surface: "ios",
                session: "session-new"
            ),
        ]
        try writeTraceLines(
            currentEvents.map(traceRow) + ["{malformed fixture row"],
            to: today
        )
        try writeTraceLines([
            traceRow(event(
                turn: "turn-old",
                kind: "tool.dispatch",
                at: now.addingTimeInterval(-86_400),
                surface: "telegram",
                session: "session-old"
            )),
        ], to: yesterday)

        let engine = MacSyncEngine(
            stateDataRootOverride: root,
            organismSnapshotProvider: { Self.disabledOrganismSnapshot }
        )
        engine.isActive = true
        engine.snapshotDir = snapshots
        let projected = try #require(
            await engine.turnSummariesSnapshotData(sourceRoot: root, now: now)
        )
        let firstWrite = await engine.writeSnapshotData(
            projected,
            to: MacSyncEngine.turnSummariesSnapshotFilename,
            in: snapshots,
            lifecycleGeneration: engine.snapshotLifecycleGeneration
        )

        let output = snapshots.appendingPathComponent(MacSyncEngine.turnSummariesSnapshotFilename)
        let written = try Data(contentsOf: output)
        let expected = try fixture(named: "turn_summaries.json")
        #expect(firstWrite == .changed)
        #expect(output.lastPathComponent == "turn_summaries.json")
        #expect(written == expected)
        #expect(!String(decoding: written, as: UTF8.self).contains("private marker"))
        #expect(!String(decoding: written, as: UTF8.self).contains("malformed fixture"))

        let decoded = try TurnSummaryComputer.makeDecoder().decode(TurnSummaryFile.self, from: written)
        #expect(decoded.totalTurnsSeen == 2)
        #expect(decoded.summaries.map(\.id) == ["turn-new", "turn-old"])
        #expect(decoded.summaries[0].kinds == [
            "assembly.stage": 1,
            "llm.call": 1,
            TurnSummaryComputer.otherKindBucket: 1,
        ])
        #expect(decoded.summaries[0].llmTokens == 10)
        #expect(decoded.summaries[0].ttftMs == 120)

        // Mutation teeth: identical bytes must digest-skip, while one new valid
        // source turn must force a changed write and a three-turn projection.
        let unchanged = await engine.writeSnapshotData(
            projected,
            to: MacSyncEngine.turnSummariesSnapshotFilename,
            in: snapshots,
            lifecycleGeneration: engine.snapshotLifecycleGeneration
        )
        #expect(unchanged == .unchanged)

        let mutatedEvents = currentEvents + [event(
            turn: "turn-mutated",
            kind: "memory.commit",
            at: now.addingTimeInterval(3),
            surface: "chat",
            session: "session-mutated"
        )]
        try writeTraceLines(mutatedEvents.map(traceRow), to: today)
        let mutated = try #require(
            await engine.turnSummariesSnapshotData(sourceRoot: root, now: now)
        )
        #expect(mutated != projected)
        #expect(await engine.writeSnapshotData(
            mutated,
            to: MacSyncEngine.turnSummariesSnapshotFilename,
            in: snapshots,
            lifecycleGeneration: engine.snapshotLifecycleGeneration
        ) == .changed)
        let mutatedFile = try TurnSummaryComputer.makeDecoder().decode(
            TurnSummaryFile.self,
            from: Data(contentsOf: output)
        )
        #expect(mutatedFile.totalTurnsSeen == 3)
        #expect(mutatedFile.summaries.first?.id == "turn-mutated")
    }

    @MainActor
    @Test("malformed-only trace input publishes an explicit empty snapshot instead of retaining stale turns")
    func malformedTraceInputReplacesStaleSnapshotWithExplicitEmptyFile() async throws {
        let root = try temporaryRoot("turn-summaries-malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let today = TurnTraceReplayReader.fileURL(for: now, root: root)
        try FileManager.default.createDirectory(
            at: today.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTraceLines(["{bad", "[]", "null"], to: today)

        let output = snapshots.appendingPathComponent(MacSyncEngine.turnSummariesSnapshotFilename)
        try Data("{\"stale\":true}".utf8).write(to: output)
        let engine = MacSyncEngine(
            stateDataRootOverride: root,
            organismSnapshotProvider: { Self.disabledOrganismSnapshot }
        )
        engine.isActive = true
        engine.snapshotDir = snapshots
        let malformedProjection = try #require(
            await engine.turnSummariesSnapshotData(sourceRoot: root, now: now)
        )

        #expect(await engine.writeSnapshotData(
            malformedProjection,
            to: MacSyncEngine.turnSummariesSnapshotFilename,
            in: snapshots,
            lifecycleGeneration: engine.snapshotLifecycleGeneration
        ) == .changed)
        let exactEmptyProjection = Data(
            #"{"summaries":[],"totalTurnsSeen":0,"truncated":false}"#.utf8
        )
        #expect(try Data(contentsOf: output) == exactEmptyProjection)

        // Isolation teeth: make the engine's injected/default source root
        // observably non-empty before asking for an explicitly empty sibling.
        // Ignoring `sourceRoot` must now return the populated projection and
        // fail both the exact-empty and inequality assertions below.
        try writeTraceLines([
            traceRow(event(
                turn: "turn-populated-root",
                kind: "assembly.stage",
                at: now,
                surface: "ios",
                session: "session-populated-root"
            )),
        ], to: today)
        let populatedProjection = try #require(
            await engine.turnSummariesSnapshotData(sourceRoot: root, now: now)
        )
        let populatedFile = try TurnSummaryComputer.makeDecoder().decode(
            TurnSummaryFile.self,
            from: populatedProjection
        )
        #expect(populatedFile.totalTurnsSeen == 1)
        #expect(populatedFile.summaries.map(\.id) == ["turn-populated-root"])

        let otherRoot = try temporaryRoot("turn-summaries-other-root")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let isolated = try #require(
            await engine.turnSummariesSnapshotData(sourceRoot: otherRoot, now: now)
        )
        #expect(isolated == exactEmptyProjection)
        #expect(
            isolated != populatedProjection,
            "an explicit source root must not read sibling fixture traces"
        )
    }

    @MainActor
    @Test("organism builder and writer publish exact shared transport bytes and fail closed on desk loss")
    func organismBuilderWritesExactSharedSnapshotAndUnavailableReplacement() async throws {
        let root = try temporaryRoot("organism-living-status")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let source = Self.organismSnapshot
        let engine = MacSyncEngine(
            stateDataRootOverride: root,
            organismSnapshotProvider: { source }
        )
        engine.isActive = true
        engine.snapshotDir = snapshots

        let status = await engine.organismLivingStatusSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(status)
        #expect(await engine.writeSnapshotData(
            encoded,
            to: MacSyncEngine.organismLivingStatusSnapshotFilename,
            in: snapshots,
            lifecycleGeneration: engine.snapshotLifecycleGeneration
        ) == .changed)

        let output = snapshots.appendingPathComponent(
            MacSyncEngine.organismLivingStatusSnapshotFilename
        )
        let written = try Data(contentsOf: output)
        let expected = try fixture(named: "organism_living_status.json")
        #expect(output.lastPathComponent == "organism_living_status.json")
        #expect(written == expected)
        let shared = try sharedDecoder().decode(OrganismLivingStatusFile.self, from: written)
        #expect(shared.generatedAt == source.generatedAt)
        #expect(shared.posture == "careful")
        #expect(shared.behaviorLine == "receiptRequired / verifyBeforeRetry / conserve")
        #expect(shared.needsAttention == true)
        #expect(shared.counters.fieldNodes == 7)
        #expect(shared.counters.pendingPredictions == 2)
        #expect(shared.reflexCandidates?.map(\.id) == ["review-candidate"])
        #expect(shared.standingViewProposals?.map(\.id) == ["standing-proposal"])

        var unavailable = MacSyncEngine.organismLivingStatusAfterDeskRead(
            status,
            deskReadSucceeded: false
        )
        #expect(unavailable.availabilityState == .unavailable)
        #expect(unavailable.unavailableReason == "desk_status_unavailable")
        let unavailableData = try encoder.encode(unavailable)
        #expect(await engine.writeSnapshotData(
            unavailableData,
            to: MacSyncEngine.organismLivingStatusSnapshotFilename,
            in: snapshots,
            lifecycleGeneration: engine.snapshotLifecycleGeneration
        ) == .changed)
        unavailable = try sharedDecoder().decode(
            OrganismLivingStatusFile.self,
            from: Data(contentsOf: output)
        )
        #expect(unavailable.availabilityState == .unavailable)
        #expect(unavailable.generatedAt == source.generatedAt)
        #expect(unavailable.counters.fieldNodes == 7)

        let disabled = MacSyncEngine.organismLivingStatusSnapshot(
            from: Self.disabledOrganismSnapshot
        )
        #expect(disabled.availabilityState == .disabled)
        #expect(disabled.posture == "off")
        #expect(disabled.behaviorLine == "off")
        #expect(disabled.needsAttention == false)
    }

    private func event(
        turn: String,
        kind: String,
        at: Date,
        surface: String,
        session: String,
        payload: JSONValue = .object([:])
    ) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: turn,
            ts: at,
            kind: kind,
            sessionId: session,
            surface: surface,
            payload: payload
        )
    }

    private func traceRow(_ event: TurnTraceEvent) throws -> String {
        try event.jsonRow.serialize(pretty: false)
    }

    private func writeTraceLines(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("b09-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(named name: String) throws -> Data {
        var data = try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("tests/fixtures/mobile_snapshot_projection", isDirectory: true)
            .appendingPathComponent(name))
        if data.last == 0x0A { data.removeLast() }
        return data
    }

    private func sharedDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static let organismSnapshot: OrganismSnapshot = {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let candidate = OrganismReflexCandidate(
            id: "review-candidate",
            pattern: "Verify the mobile projection before claiming sync.",
            trustClass: .lowRisk,
            evidenceCount: 4,
            successCount: 3,
            failureCount: 1,
            confidence: 0.75,
            reviewRequired: true,
            autoActivationAllowed: false,
            firstSeenAt: generatedAt.addingTimeInterval(-300),
            lastUpdatedAt: generatedAt
        )
        let proposal = OrganismStandingViewProposal(
            id: "standing-proposal",
            title: "Review mobile continuity",
            rationale: "The body found a recurring cross-device continuity pattern.",
            evidenceIDs: ["evidence-1"],
            reviewRequired: true
        )
        return OrganismSnapshot(
            generatedAt: generatedAt,
            enabled: true,
            chemicalState: .neutral,
            bodySchema: BodySchema(
                macAwake: true,
                iPhoneReachable: false,
                providersHealthy: false,
                memoryHealthy: true,
                dreamHealthy: false,
                toolHandsAvailable: false,
                approvalChannelsOpen: true,
                notificationPathHealthy: false,
                resourcePressure: .elevated
            ),
            fieldSummary: OrganismFieldSummary(nodeCount: 7),
            predictionSummary: OrganismPredictionSummary(
                pendingCount: 2,
                strategyCaution: 0.5
            ),
            dreamRepairSummary: OrganismDreamRepairSummary(
                receiptCount: 3,
                proposedStandingViews: 1,
                standingViewProposals: [proposal]
            ),
            reflexSummary: OrganismReflexSummary(
                candidateCount: 1,
                reviewRequiredCount: 1,
                approvedLowRiskCount: 0,
                lowRiskCount: 1,
                highestConfidence: 0.75,
                lastCandidatePattern: candidate.pattern,
                lastUpdatedAt: generatedAt
            ),
            reflexCandidates: [candidate],
            projectedBodyLine: "- Body: phone and tool paths need verified receipts.",
            signalCount: 12,
            lastSignalAt: generatedAt.addingTimeInterval(-10)
        )
    }()

    private static let disabledOrganismSnapshot = OrganismSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        enabled: false,
        chemicalState: .neutral,
        bodySchema: .neutral,
        signalCount: 0,
        lastSignalAt: nil
    )
}

private extension TurnSummaryComputer {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
