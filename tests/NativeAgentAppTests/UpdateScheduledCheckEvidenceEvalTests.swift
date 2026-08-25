import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / loop.sparkleScheduledUpdater

@MainActor
@Suite("Sparkle scheduled updater evidence", .serialized)
struct UpdateScheduledCheckEvidenceEvalTests {
    private let launchedAt = Date(timeIntervalSince1970: 1_000_000)

    private var publishedInfo: [String: Any] {
        [
            "CFBundleShortVersionString": "1.2.3",
            "SUFeedURL": "https://updates.nativeagent.dev/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "NativeAgentUpdateFeedPublished": true,
            "SUScheduledCheckInterval": 3_600,
        ]
    }

    private func schedulerPreferences(
        completedAt: Date? = nil,
        failedAt: Date? = nil
    ) -> [String: Any] {
        var values: [String: Any] = [
            UpdateController.scheduledCheckContextKey: "1.2.3\u{1F}https://updates.nativeagent.dev/appcast.xml",
            UpdateController.scheduledCheckActivatedAtKey: launchedAt,
            "SUEnableAutomaticChecks": true,
        ]
        if let completedAt {
            values[UpdateController.scheduledCheckCompletedAtKey] = completedAt
        }
        if let failedAt {
            values[UpdateController.scheduledCheckFailureAtKey] = failedAt
        }
        return values
    }

    @Test("a completed background cycle stays healthy only for its configured interval")
    func freshAndStaleScheduledCyclesAreDistinct() {
        let completedAt = launchedAt.addingTimeInterval(600)
        let fresh = UpdateController.scheduledCheckEvidence(
            info: publishedInfo,
            preferences: schedulerPreferences(completedAt: completedAt),
            now: completedAt.addingTimeInterval(3_599)
        )
        #expect(fresh == .healthy(lastCompletedAt: completedAt))

        let stale = UpdateController.scheduledCheckEvidence(
            info: publishedInfo,
            preferences: schedulerPreferences(completedAt: completedAt),
            now: completedAt.addingTimeInterval(3_601)
        )
        #expect(stale == .stale(
            lastCompletedAt: completedAt,
            expectedBy: completedAt.addingTimeInterval(3_600)
        ))
    }

    @Test("a configured scheduler with no landed cycle becomes stale after its first window")
    func missingScheduledCycleCannotRemainUnmeasuredForever() {
        let beforeDeadline = UpdateController.scheduledCheckEvidence(
            info: publishedInfo,
            preferences: schedulerPreferences(),
            now: launchedAt.addingTimeInterval(3_599)
        )
        #expect(beforeDeadline == .awaitingFirstCheck(
            expectedBy: launchedAt.addingTimeInterval(3_600)
        ))

        let afterDeadline = UpdateController.scheduledCheckEvidence(
            info: publishedInfo,
            preferences: schedulerPreferences(),
            now: launchedAt.addingTimeInterval(3_601)
        )
        #expect(afterDeadline == .stale(
            lastCompletedAt: nil,
            expectedBy: launchedAt.addingTimeInterval(3_600)
        ))
    }

    @Test("a background failure remains adverse even though a cycle did land")
    func scheduledFailureIsNotMistakenForFreshness() {
        let failedAt = launchedAt.addingTimeInterval(600)
        let evidence = UpdateController.scheduledCheckEvidence(
            info: publishedInfo,
            preferences: schedulerPreferences(completedAt: failedAt, failedAt: failedAt),
            now: failedAt.addingTimeInterval(60)
        )
        #expect(evidence == .failed(lastCompletedAt: failedAt, failedAt: failedAt))
    }

    @Test("disabled and unpublished builds do not claim an expected scheduled check")
    func unavailableAndDisabledStatesStayHonest() {
        let disabled = UpdateController.scheduledCheckEvidence(
            info: publishedInfo,
            preferences: ["SUEnableAutomaticChecks": false],
            now: launchedAt
        )
        #expect(disabled == .automaticChecksDisabled)

        var unpublished = publishedInfo
        unpublished["NativeAgentUpdateFeedPublished"] = false
        let unavailable = UpdateController.scheduledCheckEvidence(
            info: unpublished,
            preferences: schedulerPreferences(),
            now: launchedAt.addingTimeInterval(86_400)
        )
        #expect(unavailable == .unavailable(.feedNotPublished))
    }
}
