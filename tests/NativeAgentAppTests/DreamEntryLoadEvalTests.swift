import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / logic.dreams.loadEntry

@MainActor
@Suite("Dream diary entry loading")
struct DreamEntryLoadEvalTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-entry-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("an uncached missing entry resolves to a selected-entry failure, never the unselected detail state")
    func missingEntryHasAnHonestFailureDetail() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let date = "2026-08-24"

        var load = DreamEntryLoadGeneration()
        let request = load.begin()
        let fetched = await app.fetchDreamEntry(date: date)

        #expect(fetched?.date == nil)
        #expect(app.dreamError?.contains("Load entry \(date) failed:") == true)
        #expect(load.settle(request: request, entry: fetched) == .current(nil))
        #expect(!load.isLoading)

        let detail = DreamEntryDetailPresentation.resolve(
            selectedDate: date,
            hasSelectedEntry: false,
            isLoading: load.isLoading,
            error: app.dreamError
        )
        #expect(detail == .failed(app.dreamError ?? DreamEntryDetailPresentation.missingEntryDetail))
        #expect(detail != .unselected)
    }

    @Test("a late cancelled request cannot stop or replace a newer entry request")
    func staleEntryCompletionCannotClearCurrentLoadingState() {
        var load = DreamEntryLoadGeneration()
        let older = load.begin()
        let newer = load.begin()
        let newerEntry = DreamEntry(date: "2026-08-24", content: "Current dream")

        #expect(load.settle(request: older, entry: nil) == .superseded)
        #expect(load.isLoading)
        #expect(load.settle(request: newer, entry: newerEntry) == .current(newerEntry))
        #expect(!load.isLoading)

        #expect(DreamEntryDetailPresentation.resolve(
            selectedDate: newerEntry.date,
            hasSelectedEntry: true,
            isLoading: load.isLoading,
            error: nil
        ) == .entry)
    }
}
