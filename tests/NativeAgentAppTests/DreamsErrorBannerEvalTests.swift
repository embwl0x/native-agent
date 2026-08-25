import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.dreams.errorBanner
@MainActor
@Suite("Dreams error banner", .serialized)
struct DreamsErrorBannerEvalTests {
    @Test("a real diary read failure remains visible until a successful reader clears it")
    func canonicalDiaryFailureAndRecoveryDriveBannerState() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diary = root.appendingPathComponent("dream_diary")
        try Data("not a directory".utf8).write(to: diary)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let failedRead = await app.fetchDreamDiary(limit: 10)
        #expect(failedRead == nil)
        let failureBanner = try #require(DreamErrorBannerPresentation.banner(for: app.dreamError))
        #expect(failureBanner.text.contains("Load dream diary failed:"))
        #expect(!failureBanner.isTruncated)

        // DreamsView renders this exact shared presentation from `app.dreamError`.
        // Assert the production failure state and its bounded banner model directly;
        // SwiftUI's detached AppKit tree is not the view's semantic contract.

        try FileManager.default.removeItem(at: diary)
        try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
        try "# Grounded dream\n\nA real diary entry.\n"
            .write(to: diary.appendingPathComponent("2026-08-24.md"), atomically: true, encoding: .utf8)

        let recoveredRead = await app.fetchDreamDiary(limit: 10)
        #expect(recoveredRead?.entries.map(\.date) == ["2026-08-24"])
        #expect(DreamErrorBannerPresentation.banner(for: app.dreamError) == nil)
    }

    @Test("blank and oversized diagnostics remain honest, bounded banner states")
    func missingAndOversizedDiagnosticsDoNotDisappearOrOverflow() {
        #expect(DreamErrorBannerPresentation.banner(for: nil) == nil)

        let missing = DreamErrorBannerPresentation.banner(for: " \n\t ")
        #expect(missing == .init(
            text: DreamErrorBannerPresentation.missingDetailText,
            isTruncated: false
        ))

        let oversized = DreamErrorBannerPresentation.banner(
            for: String(repeating: "x", count: DreamErrorBannerPresentation.maximumDetailCharacters + 1)
        )
        #expect(oversized?.isTruncated == true)
        #expect(oversized?.text.count == DreamErrorBannerPresentation.maximumDetailCharacters + 1)
        #expect(oversized?.text.hasSuffix("…") == true)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dreams-error-banner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
