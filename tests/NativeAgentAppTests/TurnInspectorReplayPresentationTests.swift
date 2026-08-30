import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Turn Inspector replay provenance")
struct TurnInspectorReplayPresentationTests {
    @Test func unreadAndRefreshingReplayStatesNeverClaimAnEmptyCompletedRead() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let next = first.addingTimeInterval(86_400)
        let unread = TurnInspectorReplayPresentation.resolve(requested: first, loaded: nil, isLoading: false)
        #expect(unread == .loading(requested: first, retained: nil))
        #expect(unread.isLoading)
        let refreshing = TurnInspectorReplayPresentation.resolve(requested: next, loaded: first, isLoading: true)
        #expect(refreshing == .loading(requested: next, retained: first))
        #expect(refreshing.statusText.contains(first.formatted(date: .abbreviated, time: .omitted)))
        #expect(refreshing.statusText.contains(next.formatted(date: .abbreviated, time: .omitted)))
        #expect(TurnInspectorReplayPresentation.resolve(requested: next, loaded: next, isLoading: false) == .loaded(next))
    }

    @Test @MainActor func pendingDateKeepsLoadedCardsAndLateReadCannotRelabelNewerEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-provenance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = InspectorReplayReadGate()
        let store = TurnInspectorStore(dataRootOverride: root, beforeReplayRead: { await gate.wait(for: $0) })
        let first = store.replayDate
        let second = try #require(Calendar.current.date(byAdding: .day, value: -1, to: first))
        let third = try #require(Calendar.current.date(byAdding: .day, value: -2, to: first))
        for (date, turn) in [(first, "first"), (second, "second"), (third, "third")] {
            let event = TurnTraceEvent(turnId: turn, ts: date, kind: "turn.accepted", sessionId: "fixture", surface: "chat", payload: .object([:]))
            let url = TurnTraceReplayReader.fileURL(for: date, root: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (event.jsonRow.serialize(pretty: false) + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        store.setMode(.replay)
        #expect(store.cards.isEmpty)
        #expect(store.replayPresentation.isLoading)
        try await gate.waitForRequest(first)
        await gate.release(first)
        try await waitUntil { store.replayLoadedDate == first }
        #expect(store.cards.map(\.id) == ["first"])

        let secondRead = Task { await store.loadReplay(for: second) }
        try await gate.waitForRequest(second)
        #expect(store.cards.map(\.id) == ["first"])
        #expect(store.replayPresentation == .loading(requested: second, retained: first))
        let thirdRead = Task { await store.loadReplay(for: third) }
        try await gate.waitForRequest(third)
        await gate.release(third)
        await thirdRead.value
        #expect(store.cards.map(\.id) == ["third"])
        #expect(store.replayPresentation == .loaded(third))
        await gate.release(second)
        await secondRead.value
        #expect(store.cards.map(\.id) == ["third"])
        #expect(store.replayLoadedDate == third)
    }

    @Test func mountedReplayUsesLoadingAndEvidenceProvenanceBeforeEmptyCopy() throws {
        let source = try AppSourceScraping.appSource("InspectorView.swift")
        #expect(source.contains("store.cards.isEmpty, store.replayPresentation.isLoading"))
        #expect(source.contains("ProgressView(store.replayPresentation.statusText)"))
        #expect(source.contains("Text(store.replayPresentation.statusText)"))
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Replay publication timed out")
    }
}

private actor InspectorReplayReadGate {
    private var requests: [Date: CheckedContinuation<Void, Never>] = [:]

    func wait(for date: Date) async {
        await withCheckedContinuation { requests[date] = $0 }
    }

    func release(_ date: Date) {
        requests.removeValue(forKey: date)?.resume()
    }

    func waitForRequest(_ date: Date) async throws {
        for _ in 0..<200 {
            if requests[date] != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(requests[date] != nil, "Replay read did not reach its test gate")
    }
}
