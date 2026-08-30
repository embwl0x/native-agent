import Foundation
import Testing
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`, ledger row `desk.inbox.errorBanner`.
// This drives InboxView's mounted load-state boundary with a fail-then-success
// reader, proving retained cards are labeled stale and a healthy retry removes
// the error rather than leaving a ghost banner behind.

private func inboxRecord(_ id: String) throws -> InboxItemRecord {
    let data = Data("""
    {
      "id": "\(id)",
      "created_at": "2026-08-24T00:00:00Z",
      "source": "idle_checkin",
      "severity": "info",
      "title": "Inbox item \(id)",
      "summary": "summary",
      "actions": [],
      "status": "unread"
    }
    """.utf8)
    return try JSONDecoder().decode(InboxItemRecord.self, from: data)
}

@MainActor
@Test("inbox failures label retained rows and a successful retry clears the error banner")
func inboxErrorBannerTracksTheActualLoadOutcome() async throws {
    let stale = try inboxRecord("stale")
    let fresh = try inboxRecord("fresh")
    let state = InboxLoadState(items: [stale])

    let failed = await state.reload {
        throw NSError(
            domain: "InboxEval",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Inbox file is unreadable"])
    }
    #expect(!failed)
    #expect(state.items.map(\.id) == ["stale"])
    #expect(state.errorText == "Inbox couldn't refresh — showing 1 previously loaded item. Inbox file is unreadable")

    let succeeded = await state.reload { [fresh] }
    #expect(succeeded)
    #expect(state.items.map(\.id) == ["fresh"])
    #expect(state.errorText == nil)
}

@MainActor
@Test("inbox distinguishes an unchecked or failed lane from a confirmed empty lane")
func inboxEmptyStateRequiresASuccessfulRead() async {
    let state = InboxLoadState()
    #expect(state.contentPresentation(hasVisibleItems: false) == .loading)
    #expect(!(await state.reload { throw NSError(domain: "InboxEval", code: 1) }))
    #expect(state.contentPresentation(hasVisibleItems: false) == .unavailable)
    #expect(await state.reload { [] })
    #expect(state.contentPresentation(hasVisibleItems: false) == .empty)
}

@MainActor
@Test("retry retains known rows and their failed-read warning until it really succeeds")
func inboxRetryPreservesLastKnownEvidence() async throws {
    let item = try inboxRecord("known")
    let state = InboxLoadState(items: [item])
    #expect(!(await state.reload { throw NSError(domain: "InboxEval", code: 1) }))
    var continuation: CheckedContinuation<[InboxItemRecord], Never>?
    let retry = Task { @MainActor in
        await state.reload { await withCheckedContinuation { continuation = $0 } }
    }
    while continuation == nil { await Task.yield() }
    #expect(state.isLoading)
    #expect(state.errorText != nil)
    #expect(state.contentPresentation(hasVisibleItems: true) == .content)
    #expect(state.contentPresentation(hasVisibleItems: false) == .unavailable)
    continuation?.resume(returning: [item])
    #expect(await retry.value)
    #expect(!state.isLoading)
    #expect(state.errorText == nil)
}

@MainActor
@Test("older and canceled inbox reads cannot publish rows, errors, or tombstones")
func outdatedInboxReadsCannotChangeTheMountedSnapshot() async throws {
    let item = try inboxRecord("current")
    let state = InboxLoadState(items: [item])
    var continuation: CheckedContinuation<[InboxItemRecord], any Error>?
    let oldRead = Task { @MainActor in
        await state.reload { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    while continuation == nil { await Task.yield() }
    #expect(await state.reload { [item] })
    continuation?.resume(returning: [])
    #expect(!(await oldRead.value))
    #expect(state.items == [item])
    #expect(state.locallyResolvedIDs.isEmpty)

    continuation = nil
    let canceledRead = Task { @MainActor in
        await state.reload { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    while continuation == nil { await Task.yield() }
    canceledRead.cancel()
    continuation?.resume(throwing: CancellationError())
    #expect(!(await canceledRead.value))
    #expect(state.items == [item])
    #expect(state.errorText == nil)
    #expect(!state.isLoading)
}
