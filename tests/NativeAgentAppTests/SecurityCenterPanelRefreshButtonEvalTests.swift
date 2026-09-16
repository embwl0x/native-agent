import Foundation
import Testing
import TrustCenter
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SecurityCenterPanel.refreshButton
@MainActor
@Suite("Security Center refresh button", .serialized)
struct SecurityCenterPanelRefreshButtonEvalTests {
    @Test("scroll appearances retain a completed read while manual refresh still runs")
    func appearanceDoesNotRepeatStatusOrFailureReads() async throws {
        let reader = ScriptedSecurityStatusReader(results: [.failure, .status(try fixtureStatus())])
        let state = SecurityCenterRefreshState(statusReader: { try await reader.read(limit: $0) })
        await state.loadOnAppearance()
        state.cancelAppearanceRead()
        await state.loadOnAppearance()
        #expect(await reader.readCount == 1)
        #expect(state.presentation == .unavailable(detail: "fixture security status read failed"))
        await state.refresh()
        await state.loadOnAppearance()
        #expect(await reader.readCount == 2)
        #expect(state.presentation == .current)
    }

    @Test("a cancelled first appearance retries and ignores a noncooperative late failure")
    func cancelledAppearanceDoesNotPoisonRetry() async throws {
        let reader = SuspendedSecurityStatusReader(status: try fixtureStatus())
        let state = SecurityCenterRefreshState(statusReader: { try await reader.read(limit: $0) })
        let first = Task { await state.loadOnAppearance() }
        for await _ in reader.started.stream { break }
        first.cancel()
        state.cancelAppearanceRead()
        #expect(!state.isRefreshing)
        await state.loadOnAppearance()
        #expect(state.presentation == .current)
        await reader.finishFirstRead()
        await first.value
        #expect(state.presentation == .current)
        #expect(!state.isRefreshing)
    }

    @Test("a failed first refresh is unavailable, not loading or empty receipts")
    func failedFirstReadRemainsExplicitInRefreshState() async throws {
        let reader = ScriptedSecurityStatusReader(results: [.failure])
        let state = SecurityCenterRefreshState(statusReader: { limit in
            try await reader.read(limit: limit)
        })
        await state.refresh()

        #expect(state.status?.mode == nil)
        #expect(state.presentation == .unavailable(detail: "fixture security status read failed"))
        #expect(SecurityCenterRefreshPresentation.message(for: state.presentation)
            == "Security status unavailable: fixture security status read failed")
    }

    @Test("a later failed refresh retains the last readable root snapshot and names it stale")
    func failedRefreshDoesNotDiscardLastSecuritySnapshot() async throws {
        let reader = ScriptedSecurityStatusReader(results: [.status(try fixtureStatus()), .failure])
        let state = SecurityCenterRefreshState(statusReader: { limit in
            try await reader.read(limit: limit)
        })
        await state.refresh()
        #expect(state.status?.mode == "fixture-balanced")
        #expect(state.presentation == .current)

        await state.refresh()
        #expect(state.status?.mode == "fixture-balanced", "the last successful security status must remain visible")
        #expect(state.presentation == .stale(detail: "fixture security status read failed"))
        #expect(SecurityCenterRefreshPresentation.message(for: state.presentation)
            == "Showing the last security status; refresh failed: fixture security status read failed")
    }

    @Test("presentation distinguishes loading, current, stale, and unavailable reads")
    func refreshPresentationKeepsReadProvenanceHonest() {
        #expect(SecurityCenterRefreshPresentation.state(
            hasStatus: false,
            isRefreshing: true,
            lastError: nil
        ) == .loading)
        #expect(SecurityCenterRefreshPresentation.state(
            hasStatus: true,
            isRefreshing: false,
            lastError: nil
        ) == .current)
        #expect(SecurityCenterRefreshPresentation.state(
            hasStatus: true,
            isRefreshing: false,
            lastError: "reader stopped"
        ) == .stale(detail: "reader stopped"))
        #expect(SecurityCenterRefreshPresentation.state(
            hasStatus: false,
            isRefreshing: false,
            lastError: "reader stopped"
        ) == .unavailable(detail: "reader stopped"))
    }

    private func fixtureStatus() throws -> SecurityCenterStatus {
        try JSONDecoder().decode(SecurityCenterStatus.self, from: Data("""
        {
          "status": "ready",
          "mode": "fixture-balanced",
          "developerMode": false,
          "fullMac": false,
          "killSwitchEnabled": false,
          "trustedOrigins": 1,
          "auditReceiptsPath": "/tmp/security-audit.jsonl",
          "flags": [],
          "recentReceipts": []
        }
        """.utf8))
    }

}

private actor ScriptedSecurityStatusReader {
    enum Result {
        case status(SecurityCenterStatus)
        case failure
    }

    private var results: [Result]
    private(set) var readCount = 0

    init(results: [Result]) {
        self.results = results
    }

    func read(limit: Int) throws -> SecurityCenterStatus {
        readCount += 1
        precondition(limit == 10, "Security Center must request its visible receipt limit")
        guard !results.isEmpty else { throw SecurityReadFailure() }
        switch results.removeFirst() {
        case .status(let status): return status
        case .failure: throw SecurityReadFailure()
        }
    }
}

private actor SuspendedSecurityStatusReader {
    nonisolated let started = AsyncStream<Void>.makeStream()
    private let status: SecurityCenterStatus
    private var firstRead: CheckedContinuation<SecurityCenterStatus, any Error>?
    private var didStart = false

    init(status: SecurityCenterStatus) { self.status = status }

    func read(limit: Int) async throws -> SecurityCenterStatus {
        guard !didStart else { return status }
        didStart = true
        return try await withCheckedThrowingContinuation { continuation in
            firstRead = continuation
            started.continuation.yield(())
            started.continuation.finish()
        }
    }

    func finishFirstRead() {
        firstRead?.resume(throwing: SecurityReadFailure())
        firstRead = nil
    }
}

private struct SecurityReadFailure: LocalizedError {
    var errorDescription: String? { "fixture security status read failed" }
}
