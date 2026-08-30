import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / loop.sparkleScheduledUpdater

@MainActor
@Suite("Sparkle scheduled updater evidence", .serialized)
struct UpdateScheduledCheckEvidenceEvalTests {
    private struct ScheduledFailure: Error {}

    @MainActor
    private final class TestClock {
        var value: Date

        init(_ value: Date) {
            self.value = value
        }
    }

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

    private func isolatedPreferences() throws -> (UserDefaults, String) {
        let suiteName = "UpdateScheduledCheckEvidenceEvalTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        return (preferences, suiteName)
    }

    @Test("unavailable builds never construct or activate the scheduled updater")
    func unavailableBuildNeverConstructsScheduledUpdater() throws {
        let (preferences, suiteName) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        var unpublishedInfo = publishedInfo
        unpublishedInfo["NativeAgentUpdateFeedPublished"] = false
        var factoryCalls = 0

        let controller = UpdateController(
            info: unpublishedInfo,
            preferences: preferences,
            now: { self.launchedAt },
            updaterFactory: { _, _ in
                factoryCalls += 1
                return nil
            }
        )

        #expect(!controller.updatesAreAvailable)
        #expect(factoryCalls == 0)
        #expect(preferences.object(forKey: UpdateController.scheduledCheckActivatedAtKey) == nil)
        #expect(preferences.object(forKey: UpdateController.scheduledCheckContextKey) == nil)
    }

    @Test("published lifecycle starts one owned scheduler and persists callback outcomes")
    func publishedLifecycleStartsOnceAndPersistsCallbackOutcomes() throws {
        let (preferences, suiteName) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let clock = TestClock(launchedAt)
        var factoryCalls: [(startingUpdater: Bool, delegate: UpdateController)] = []

        let controller = UpdateController(
            info: publishedInfo,
            preferences: preferences,
            now: { clock.value },
            updaterFactory: { startingUpdater, delegate in
                factoryCalls.append((startingUpdater, delegate))
                return nil
            }
        )

        #expect(controller.updatesAreAvailable)
        #expect(factoryCalls.count == 1)
        #expect(factoryCalls.first?.startingUpdater == true)
        #expect(factoryCalls.first?.delegate === controller)
        #expect(preferences.object(
            forKey: UpdateController.scheduledCheckActivatedAtKey
        ) as? Date == launchedAt)
        #expect(preferences.string(
            forKey: UpdateController.scheduledCheckContextKey
        ) == "1.2.3\u{1F}https://updates.nativeagent.dev/appcast.xml")

        let successfulCheckAt = launchedAt.addingTimeInterval(600)
        clock.value = successfulCheckAt
        controller.handleScheduledCheckCompletion(error: nil)
        #expect(preferences.object(
            forKey: UpdateController.scheduledCheckCompletedAtKey
        ) as? Date == successfulCheckAt)
        #expect(preferences.object(forKey: UpdateController.scheduledCheckFailureAtKey) == nil)

        controller.handleFoundUpdate(displayVersion: "1.2.4")
        #expect(controller.status.availableVersion == "1.2.4")
        let noticeData = try #require(preferences.data(forKey: UpdateController.persistedNoticeKey))
        #expect(UpdateController.restoredNoticeVersion(
            data: noticeData,
            info: publishedInfo
        ) == "1.2.4")

        let failedCheckAt = successfulCheckAt.addingTimeInterval(300)
        clock.value = failedCheckAt
        controller.handleScheduledCheckCompletion(error: ScheduledFailure())
        #expect(preferences.object(
            forKey: UpdateController.scheduledCheckCompletedAtKey
        ) as? Date == failedCheckAt)
        #expect(preferences.object(
            forKey: UpdateController.scheduledCheckFailureAtKey
        ) as? Date == failedCheckAt)
        #expect(controller.status.availableVersion == "1.2.4")

        controller.handleNoUpdate()
        #expect(controller.status.availableVersion == nil)
        #expect(preferences.data(forKey: UpdateController.persistedNoticeKey) == nil)
        #expect(factoryCalls.count == 1)
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
