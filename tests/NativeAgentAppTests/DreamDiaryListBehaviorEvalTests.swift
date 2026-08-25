import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Dream diary list behavior", .serialized)
struct DreamDiaryListBehaviorEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-diary-list-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func diary(in root: URL) throws -> URL {
        let diary = root.appendingPathComponent("dream_diary", isDirectory: true)
        try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
        return diary
    }

    // app.mind / ui.dreams.list.diary
    @Test("the real diary reader preserves readable entries and labels unreadable files in its bounded window")
    func partialUnreadableWindowStaysVisibleAndExplicit() async throws {
        let root = try temporaryRoot("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try diary(in: root)
        try "# Grounded dream\n\nVerified outcomes first.\n"
            .write(to: directory.appendingPathComponent("2026-08-24.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x00]).write(to: directory.appendingPathComponent("2026-08-25.md"))

        let response = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getDreamDiary(limit: 60)
        #expect(response.entries.map(\.date) == ["2026-08-24"])
        #expect(response.totalEntries == 2)
        #expect(response.unreadableEntries == 1)
        #expect(DreamDiaryListPresentation.resolve(
            entryCount: response.entries.count,
            unreadableEntries: response.unreadableEntries ?? 0
        ) == .readable)
        #expect(DreamDiaryListPresentation.unreadableLabel(response.unreadableEntries ?? 0)
            == "1 diary file in this window couldn't be read and is not shown.")
    }

    // app.mind / ui.dreams.list.diary
    @Test("an all-unreadable diary window is incomplete rather than a false no-dreams empty state")
    func allUnreadableWindowIsNotAnEmptyDiary() async throws {
        let root = try temporaryRoot("all-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try diary(in: root)
        try Data([0xFF, 0xFE, 0x00]).write(to: directory.appendingPathComponent("2026-08-25.md"))

        let response = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getDreamDiary(limit: 60)
        #expect(response.entries.isEmpty)
        #expect(response.totalEntries == 1)
        #expect(response.unreadableEntries == 1)
        #expect(DreamDiaryListPresentation.resolve(
            entryCount: response.entries.count,
            unreadableEntries: response.unreadableEntries ?? 0
        ) == .incomplete(unreadableEntries: 1))
    }

    // app.mind / ui.dreams.list.diary
    @Test("a readable empty diary remains an honest empty state")
    func emptyDirectoryDoesNotManufactureAnIncompleteState() async throws {
        let root = try temporaryRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try diary(in: root)

        let response = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getDreamDiary(limit: 60)
        #expect(response.entries.isEmpty)
        #expect(response.totalEntries == 0)
        #expect(response.unreadableEntries == 0)
        #expect(DreamDiaryListPresentation.resolve(
            entryCount: response.entries.count,
            unreadableEntries: response.unreadableEntries ?? 0
        ) == .readable)
    }

    // app.mind / ui.dreams.list.diary
    @Test("a missing diary directory is a readable no-entry state, not damaged diary evidence")
    func missingDiaryDirectoryRemainsAnHonestEmptyState() async throws {
        let root = try temporaryRoot("missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let response = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getDreamDiary(limit: 60)
        #expect(response.entries.isEmpty)
        #expect(response.totalEntries == 0)
        #expect(response.unreadableEntries == 0)
        #expect(DreamDiaryListPresentation.resolve(
            entryCount: response.entries.count,
            unreadableEntries: response.unreadableEntries ?? 0
        ) == .readable)
    }
}
