import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Desk runs diagnostics lifecycle", .serialized)
struct DeskRunsDiagnosticsLifecycleTests {
    @Test("mounted runs translate every registered raw status and warn on unknown ledger vocabulary")
    @MainActor func runsStatusBadgesNeverUseRawVocabularyAsTheirTint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskRunsStatusBadges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let known = RunStatusBadgePresentation.knownRawStatuses.sorted()
        for (index, status) in known.enumerated() {
            await RunLedger.append(
                id: "known-\(index)", kind: "mission", status: status,
                createdAt: Date(timeIntervalSince1970: 1_800_100_000 + Double(index)), dataRoot: root)
        }
        await RunLedger.append(
            id: "future-status", kind: "mission", status: "needs_human_review",
            createdAt: Date(timeIntervalSince1970: 1_800_200_000), dataRoot: root)
        await RunLedger.append(
            id: "missing-status", kind: "mission", status: "   ",
            createdAt: Date(timeIntervalSince1970: 1_800_200_001), dataRoot: root)

        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await model.refreshForSidebarItem(.diagnostics)
        #expect(Set(model.runs.map(\.status)).isSuperset(of: Set(known)))

        for run in model.runs where RunStatusBadgePresentation.knownRawStatuses.contains(run.status) {
            let badge = RunStatusBadgePresentation.badge(for: run.status)
            #expect(!badge.label.isEmpty)
            #expect(!badge.label.hasPrefix("Unrecognized status:"))
            #expect(["ok", "info", "running", "failed", "timeout", "interrupted", "blocked", "warn"].contains(badge.themeStatus))
        }

        let future = RunStatusBadgePresentation.badge(for: "needs_human_review")
        #expect(future.label == "Unrecognized status: needs_human_review")
        #expect(future.themeStatus == "warn")
        let missing = RunStatusBadgePresentation.badge(for: "   ")
        #expect(missing.label == "Status unavailable")
        #expect(missing.themeStatus == "warn")
    }

    @Test("Diagnostics refresh reads the canonical runs ledger that RunsView lists")
    @MainActor func diagnosticsRefreshPublishesThePersistedRunRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskRunsDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel()
        model.dataRootOverride = root
        let runsDirectory = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        await RunLedger.append(
            id: "older", kind: "codex", status: "succeeded", output: "finished",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), dataRoot: root)
        await RunLedger.append(
            id: "newer", kind: "swarm", status: "timeout", error: "deadline elapsed",
            createdAt: Date(timeIntervalSince1970: 1_800_001_000), dataRoot: root)
        await model.refreshForSidebarItem(.diagnostics)
        #expect(model.runs.map(\.id) == ["newer", "older"])
        #expect(model.runs.first?.status == "timeout")
        #expect(model.runs.first?.error == "deadline elapsed")
    }
}
