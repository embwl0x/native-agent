import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.settings.forceRefreshFromICloud
final class SettingsForceRefreshFromICloudEvalTests: XCTestCase {
    func testCompletedRefreshAcknowledgesBothPairingAndSettingsSnapshotOutcomes() {
        XCTAssertEqual(
            SettingsICloudRefreshPresentation.statusText(
                pairingMaterialChanged: true,
                snapshotError: nil
            ),
            "New pairing material installed. Settings snapshot reload completed."
        )

        XCTAssertEqual(
            SettingsICloudRefreshPresentation.statusText(
                pairingMaterialChanged: false,
                snapshotError: nil
            ),
            "No new pairing material was installed. Settings snapshot reload completed."
        )
    }

    func testIncompleteSettingsSnapshotIsReportedWithoutPretendingPairingFailed() {
        XCTAssertEqual(
            SettingsICloudRefreshPresentation.statusText(
                pairingMaterialChanged: false,
                snapshotError: "Settings snapshots are still downloading from iCloud. Try again in a moment."
            ),
            "No new pairing material was installed. Settings snapshots are still downloading from iCloud. Try again in a moment."
        )
    }

    func testSettingsActionRefreshesPairingThenSettingsAndPreventsOverlappingRefreshes() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        let settingsView = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "SettingsViewFull", keyword: "struct", in: source)
        )

        XCTAssertTrue(settingsView.contains("await pairingStore.refreshFromKVS()"))
        XCTAssertTrue(settingsView.contains("await store.refresh()"))
        XCTAssertTrue(settingsView.contains("SettingsICloudRefreshPresentation.statusText("))
        XCTAssertTrue(settingsView.contains(".disabled(isForceRefreshing)"))
        XCTAssertTrue(settingsView.contains("snapshotError: settingsOutcome.feedbackMessage"))
        XCTAssertFalse(settingsView.contains("snapshotError: iCloudSyncEngine.shared.syncError"))
        XCTAssertTrue(settingsView.contains("LabeledContent(\"Health snapshot\")"))
        XCTAssertFalse(settingsView.contains("health.ok ? \"Online\" : \"Offline\""))
    }

    func test_settingsOutcomeDistinguishesCompletePartialUnavailableAndSuperseded() {
        let complete = SettingsSnapshotRefreshOutcome(availableFields: Set(SettingsSnapshotRefreshOutcome.Field.allCases))
        XCTAssertEqual(complete.state, .refreshed)
        XCTAssertNil(complete.feedbackMessage)

        let partial = SettingsSnapshotRefreshOutcome(availableFields: [.health, .connectors])
        XCTAssertEqual(partial.state, .partial)
        XCTAssertFalse(partial.availableFields.contains(.trustPolicy))
        XCTAssertFalse(partial.availableFields.contains(.personality))
        XCTAssertNotNil(partial.feedbackMessage)

        XCTAssertEqual(SettingsSnapshotRefreshOutcome(availableFields: []).state, .unavailable)
        XCTAssertEqual(
            SettingsSnapshotRefreshOutcome(availableFields: [], wasSuperseded: true).state,
            .superseded
        )
    }

    @MainActor
    func test_overlappingSettingsCallersAwaitTheSameFocusedCompletion() async {
        var release: CheckedContinuation<Void, Never>?
        var readCount = 0
        let started = expectation(description: "Settings read started")
        let outcome = SettingsSnapshotRefreshOutcome(availableFields: [.health])
        let store = SettingsStore(refreshSnapshot: {
            readCount += 1
            started.fulfill()
            await withCheckedContinuation { release = $0 }
            return outcome
        })

        let first = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 1)
        let secondStarted = expectation(description: "Second Settings caller joined")
        let second = Task {
            secondStarted.fulfill()
            return await store.refresh()
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertTrue(store.isLoading)
        release?.resume()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(firstOutcome, outcome)
        XCTAssertEqual(secondOutcome, outcome)
        XCTAssertEqual(store.error, outcome.feedbackMessage)
        XCTAssertEqual(store.availableFields, [.health])
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func test_settingsLoaderReportsActualFieldPresenceAndNoDirectoryIsNotSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-outcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"app":"NativeAgent","dataDir":"fixture","ok":true,"uptimeSeconds":1,"version":"test"}"#.utf8)
            .write(to: root.appendingPathComponent("health.json"), options: .atomic)
        try Data("[]".utf8).write(to: root.appendingPathComponent("connectors.json"), options: .atomic)

        let sync = iCloudSyncEngine.shared
        let previousDirectory = sync.snapshotDir
        let previousHealth = sync.health
        let previousConnectors = sync.connectors
        let previousError = sync.syncError
        defer {
            sync.snapshotDir = previousDirectory
            sync.health = previousHealth
            sync.connectors = previousConnectors
            sync.syncError = previousError
        }

        sync.snapshotDir = root
        let partial = await sync.refreshSettingsSnapshot()
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.availableFields, [.health, .connectors])

        sync.snapshotDir = nil
        sync.syncError = "Unrelated provider refresh failed"
        let unavailable = await sync.refreshSettingsSnapshot()
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertTrue(unavailable.availableFields.isEmpty)
        XCTAssertNotEqual(unavailable.feedbackMessage, sync.syncError)
    }
}
