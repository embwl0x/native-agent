import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.chat.runtime.refreshModels`.
///
/// The model picker keeps the last proven catalog when its iCloud snapshot is
/// absent. A deliberate refresh must make that retained/stale state visible
/// instead of leaving the menu unchanged without explanation.
@MainActor
final class ChatRefreshModelsEvalTests: XCTestCase {
    /// Coverage-ledger fence `ios.providers.refreshButton`.
    /// A provider-refresh failure must remain visible after the spinner stops.
    func test_providerRefreshButtonKeepsSnapshotFailuresInItsStatusText() {
        XCTAssertEqual(ProviderRefreshPresentation.statusText(for: .refreshed), "")
        XCTAssertFalse(ProviderRefreshPresentation.statusText(for: .unavailable).isEmpty)
        XCTAssertFalse(ProviderRefreshPresentation.statusText(for: .superseded).isEmpty)
    }

    func test_refreshModelsReportsAnUnavailableSnapshotAndStaysQuietOnSuccess() async throws {
        let engine = iCloudSyncEngine.shared
        let priorSnapshotDir = engine.snapshotDir
        let priorSyncError = engine.syncError
        defer {
            engine.snapshotDir = priorSnapshotDir
            engine.syncError = priorSyncError
        }

        engine.snapshotDir = nil
        var feedback: [String] = []
        await ChatRuntimeControlPresentation.refreshModels(
            refresh: { await engine.refreshProviderControlsSnapshot() },
            presentError: { feedback.append($0) }
        )

        XCTAssertEqual(
            feedback,
            ["Couldn't refresh models. Provider snapshots are still downloading from iCloud. Try again in a moment."]
        )

        feedback.removeAll()
        await ChatRuntimeControlPresentation.refreshModels(
            refresh: { .refreshed },
            presentError: { feedback.append($0) }
        )
        XCTAssertTrue(feedback.isEmpty)

        await ChatRuntimeControlPresentation.refreshModels(
            refresh: { .superseded },
            presentError: { feedback.append($0) }
        )
        XCTAssertEqual(
            feedback,
            ["Couldn't refresh models because iCloud sync was reconfigured. Try again."]
        )
    }

    func test_refreshModelsMenuUsesTheFeedbackProducingActionSeam() throws {
        let source = try MobileEvalSources.mobileSource("ChatView.swift")
        XCTAssertTrue(source.contains("await ChatRuntimeControlPresentation.refreshModels("))
        XCTAssertTrue(source.contains("refresh: { await sync.refreshProviderControlsSnapshot() }"))
        XCTAssertTrue(source.contains("presentError: { iOSSystemToastCenter.shared.push(error: $0) }"))
    }
}
