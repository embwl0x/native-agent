import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Desk runs diagnostics lifecycle", .serialized)
struct DeskRunsDiagnosticsLifecycleTests {
    @Test("Runs presentation reacts only to the runs endpoint and retains proven rows")
    @MainActor func runsPresentationOwnsItsRefreshTruth() throws {
        let now = Date()
        let row = try JSONDecoder().decode(
            RunRecord.self,
            from: Data(#"{"id":"known-run","kind":"mission","status":"succeeded","createdAt":"2026-08-29T00:00:00Z"}"#.utf8)
        )
        let unrelatedFailure = AppModel.PanelRefreshStatus(
            lastAttemptAt: now,
            lastSuccessAt: now,
            failedEndpoints: ["watchdog"]
        )
        let runsFailure = AppModel.PanelRefreshStatus(
            lastAttemptAt: now,
            lastSuccessAt: now.addingTimeInterval(-60),
            failedEndpoints: ["runs"]
        )

        guard case .loading = RunsPresentation.state(
            runs: [], refresh: nil
        ) else {
            Issue.record("cold Runs state did not remain loading")
            return
        }
        guard case .rows(let current) = RunsPresentation.state(
            runs: [row], refresh: unrelatedFailure
        ) else {
            Issue.record("an unrelated Diagnostics failure hid current runs")
            return
        }
        #expect(current.map(\.id) == ["known-run"])
        guard case .stale(let retained, let notice) = RunsPresentation.state(
            runs: [row], refresh: runsFailure
        ) else {
            Issue.record("a failed runs read hid its retained rows")
            return
        }
        #expect(retained.map(\.id) == ["known-run"])
        #expect(notice.contains("previously loaded runs"))
    }

    @Test("Diagnostics refresh requests stay sequential and preserve pending edges")
    func diagnosticsRefreshesCoalesceWithoutDroppingFiniteBursts() throws {
        var coalescer = DiagnosticsRefreshCoalescer()
        let startsInitial = coalescer.requestRefresh()
        #expect(startsInitial)
        let startsOverlapping = coalescer.requestRefresh()
        #expect(!startsOverlapping)
        let startsTrailing = coalescer.completeRefresh()
        #expect(startsTrailing)
        let startsDuringTrailing = coalescer.requestRefresh()
        #expect(!startsDuringTrailing)
        let startsNewest = coalescer.completeRefresh()
        #expect(startsNewest)
        let startsAfterBurst = coalescer.completeRefresh()
        #expect(!startsAfterBurst)
        #expect(!coalescer.isRefreshing)

        let diagnostics = try AppSourceScraping.appSource("DiagnosticsView.swift")
        #expect(diagnostics.contains("StatusView(\n                        loadsOnAppear: false"))
        #expect(diagnostics.contains("RunsView(\n                        isRefreshing: isRefreshingSnapshot"))
        let content = try AppSourceScraping.appSource("ContentView.swift")
        #expect(content.contains("if item.normalized == .diagnostics"))
        #expect(content.contains("Avoid racing a second"))
    }

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

        let partial = RunStatusBadgePresentation.badge(for: "partial")
        #expect(partial.label == "Partially completed")
        #expect(partial.themeStatus == "warn")
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
