import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SlimSettings.embeddingsRetryAndReleaseButtons

@MainActor
private final class EmbeddingsSettingsActionFixture {
    var fetchResults: [Result<EmbeddingsStatus, Error>]
    var releaseResults: [Result<EmbeddingsToggleResult, Error>]
    private(set) var fetchCount = 0
    private(set) var releaseCount = 0

    init(
        fetchResults: [Result<EmbeddingsStatus, Error>],
        releaseResults: [Result<EmbeddingsToggleResult, Error>]
    ) {
        self.fetchResults = fetchResults
        self.releaseResults = releaseResults
    }

    func fetchStatus() async throws -> EmbeddingsStatus {
        fetchCount += 1
        guard !fetchResults.isEmpty else { throw FixtureError.exhausted }
        return try fetchResults.removeFirst().get()
    }

    func releaseMemory() async throws -> EmbeddingsToggleResult {
        releaseCount += 1
        guard !releaseResults.isEmpty else { throw FixtureError.exhausted }
        return try releaseResults.removeFirst().get()
    }

    enum FixtureError: LocalizedError {
        case statusUnavailable
        case exhausted

        var errorDescription: String? {
            switch self {
            case .statusUnavailable: "Embedding status service is unavailable."
            case .exhausted: "No fixture result was supplied."
            }
        }
    }
}

private func embeddingsActionStatus(
    loaded: Bool?,
    installState: EmbeddingsInstallState? = nil
) -> EmbeddingsStatus {
    EmbeddingsStatus(
        libraryAvailable: true,
        modelLoadable: true,
        configBackend: ManagedEmbeddingProvider.coreMLBackend,
        envEnabled: true,
        effectiveBackend: "local",
        modelName: "Test MiniLM",
        requestedEnabled: true,
        memoryMode: "balanced",
        memoryModeDetail: nil,
        idleUnloadSeconds: nil,
        modelState: .init(
            mode: "balanced",
            loaded: loaded,
            parentLoaded: loaded,
            workerRunning: false,
            workerPid: nil,
            lastUsedAt: nil,
            lastLoadedAt: nil,
            lastUnloadedAt: nil,
            unloadReason: nil,
            loadCount: nil,
            unloadCount: nil,
            cacheSize: nil,
            cacheMaxSize: nil
        ),
        installState: installState,
        reindexState: nil,
        extrasPath: nil
    )
}

@Suite("Slim Settings embeddings retry and release controls")
struct SlimSettingsEmbeddingsRetryAndReleaseButtonsEvalTests {
    @Test("retry recovers status, then Release now removes the resident-model control")
    @MainActor
    func retryThenReleaseUpdatesTheActionState() async throws {
        let loaded = embeddingsActionStatus(loaded: true)
        let released = embeddingsActionStatus(loaded: false)
        let fixture = EmbeddingsSettingsActionFixture(
            fetchResults: [.failure(EmbeddingsSettingsActionFixture.FixtureError.statusUnavailable), .success(loaded)],
            releaseResults: [.success(.init(
                ok: true,
                error: nil,
                detail: "Released Swift CoreML embedding model memory.",
                status: released
            ))]
        )
        let failedRefresh: EmbeddingsSettingsActionPresentation.Update
        do {
            failedRefresh = EmbeddingsSettingsActionPresentation.refreshed(
                try await fixture.fetchStatus()
            )
        } catch {
            failedRefresh = EmbeddingsSettingsActionPresentation.refreshFailed(error, preserving: nil)
        }
        let retryControls = EmbeddingsSettingsActionPresentation.controls(
            status: failedRefresh.status,
            errorMessage: failedRefresh.errorMessage
        )
        #expect(retryControls.showsRetryMemoryStatus)
        #expect(!retryControls.showsReleaseNow)

        let recovered = EmbeddingsSettingsActionPresentation.refreshed(
            try await fixture.fetchStatus()
        )
        let loadedControls = EmbeddingsSettingsActionPresentation.controls(
            status: recovered.status,
            errorMessage: recovered.errorMessage
        )
        #expect(!loadedControls.showsRetryMemoryStatus)
        #expect(loadedControls.showsReleaseNow)

        let release = EmbeddingsSettingsActionPresentation.released(
            try await fixture.releaseMemory()
        )
        let releasedControls = EmbeddingsSettingsActionPresentation.controls(
            status: release.status,
            errorMessage: release.errorMessage
        )
        #expect(!releasedControls.showsReleaseNow)
        #expect(release.errorMessage == nil)
        #expect(fixture.fetchCount == 2)
        #expect(fixture.releaseCount == 1)
    }

    @Test("the failed-install retry status control invokes the same status recovery path")
    @MainActor
    func failedInstallRetryRestoresAStatusInsteadOfLeavingAnInertButton() async throws {
        let failed = EmbeddingsInstallState(
            state: "failed",
            currentStep: nil,
            progress: nil,
            error: "model load failed",
            detail: "The model resources could not be opened.",
            startedAt: nil,
            failedAt: nil,
            completedAt: nil,
            extrasPath: nil,
            hfCachePath: nil,
            total: nil,
            candidates: nil,
            embedded: nil,
            skipped: nil,
            failed: nil,
            reason: nil,
            lastUpdatedAt: nil
        )
        let fixture = EmbeddingsSettingsActionFixture(
            fetchResults: [
                .success(embeddingsActionStatus(loaded: false, installState: failed)),
                .success(embeddingsActionStatus(loaded: false)),
            ],
            releaseResults: []
        )
        let failedStatus = EmbeddingsSettingsActionPresentation.refreshed(
            try await fixture.fetchStatus()
        )
        #expect(EmbeddingsSettingsActionPresentation.controls(
            status: failedStatus.status,
            errorMessage: failedStatus.errorMessage
        ).showsRetryStatus)

        let recovered = EmbeddingsSettingsActionPresentation.refreshed(
            try await fixture.fetchStatus()
        )
        #expect(!EmbeddingsSettingsActionPresentation.controls(
            status: recovered.status,
            errorMessage: recovered.errorMessage
        ).showsRetryStatus)
        #expect(fixture.fetchCount == 2)
    }

    @Test("a release verification failure remains visible and keeps the release control available")
    @MainActor
    func releaseFailureDoesNotPretendMemoryWasFreed() async throws {
        let loaded = embeddingsActionStatus(loaded: true)
        let fixture = EmbeddingsSettingsActionFixture(
            fetchResults: [.success(loaded)],
            releaseResults: [.success(.init(
                ok: false,
                error: "Embedding model is still loaded after release.",
                detail: "The embedding runtime still reports a resident CoreML model.",
                status: loaded
            ))]
        )
        let initial = EmbeddingsSettingsActionPresentation.refreshed(
            try await fixture.fetchStatus()
        )
        #expect(EmbeddingsSettingsActionPresentation.controls(
            status: initial.status,
            errorMessage: initial.errorMessage
        ).showsReleaseNow)

        let release = EmbeddingsSettingsActionPresentation.released(
            try await fixture.releaseMemory()
        )
        #expect(release.errorMessage == "Embedding model is still loaded after release.")
        #expect(EmbeddingsSettingsActionPresentation.controls(
            status: release.status,
            errorMessage: release.errorMessage
        ).showsReleaseNow)
        #expect(fixture.releaseCount == 1)
    }

    @Test("the real managed runtime unload is verified, while stale or unavailable confirmation is refused")
    func runtimeReleaseVerificationRequiresAnUnloadedPostcondition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embeddings-release-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = ManagedEmbeddingProvider(
            dataRoot: root,
            loader: { _ in MockEmbeddingProvider() },
            availabilityProbe: { true }
        )
        _ = try await provider.embed(["warm the managed embedding provider"])
        #expect(provider.snapshot().coreMLLoaded)

        let released = provider.release(reason: "manual release")
        #expect(!released.coreMLLoaded)
        let confirmed = EmbeddingsMemoryReleaseVerification.verify(
            releasedSnapshot: released,
            reportedStatus: embeddingsActionStatus(loaded: false)
        )
        #expect(confirmed.ok)
        #expect(confirmed.error == nil)

        let stale = EmbeddingsMemoryReleaseVerification.verify(
            releasedSnapshot: released,
            reportedStatus: embeddingsActionStatus(loaded: true)
        )
        #expect(!stale.ok)
        #expect(stale.error == "Embedding memory release could not be confirmed.")

        let unavailable = EmbeddingsMemoryReleaseVerification.verify(
            releasedSnapshot: nil,
            reportedStatus: embeddingsActionStatus(loaded: false)
        )
        #expect(!unavailable.ok)
        #expect(unavailable.error == "Embedding runtime was unavailable, so memory release could not be verified.")
    }
}
