import Foundation
import Testing
@testable import NativeAgentApp

// Pins for the B2.5/B2.6 UI-sweep fence C (2026-07-23):
//   B2.5a  Mac permissions one-home + reciprocal cross-links
//   B2.5b  MemoryView triple status readout collapsed into one block
//   B2.6c  Settings Subconscious/Embeddings demoted to an Advanced disclosure
//   B2.6d  Support Snapshot reuses a fresh Doctor result instead of re-running
@Suite("B2 UI sweep — fence C")
struct B2UISweepFenceCTests {

    // MARK: - B2.5b lossless-controls sweep

    @Test func memoryStatusIsOneBlockAndLosesNoDatum() throws {
        let source = try AppSourceScraping.appSource("MemoryView.swift")

        // The former triple readout (stack panel + summary bar + standalone
        // iCloud badge) is now ONE block: the summary bar renders INSIDE the
        // stack panel and the standalone cloudKitBadge is gone.
        #expect(source.contains("MemoryV2SummaryBar(status: summaryStatus, latest: latestHygiene)"))
        #expect(!source.contains("private var cloudKitBadge"))
        // The single call site feeds the folded-in summary data through.
        #expect(source.contains("summaryStatus: appModel.memoryV2Status"))
        #expect(source.contains("latestHygiene: appModel.latestMemoryHygiene"))

        // Every datum the panel showed before must still render — the four
        // Apple-native stack rows plus the data-root line.
        for title in ["SQLite", "Core ML MiniLM", "CoreSpotlight", "CloudKit"] {
            #expect(source.contains("title: \"\(title)\""))
        }
        #expect(source.contains("data root:"))
        // And the summary bar itself still carries counts + backend + hygiene.
        #expect(source.contains("counts?.active"))
        #expect(source.contains("counts?.pinned"))
        #expect(source.contains("counts?.pendingProposals"))
        #expect(source.contains("Text(backend)"))
        #expect(source.contains("Text(hygieneText)"))
    }

    // MARK: - B2.5a one-home + cross-links (write paths unchanged)

    @Test func macControlWritePathsUnchangedAndTabsCrossLink() throws {
        let macIntegration = try AppSourceScraping.appSource("MacIntegrationView.swift")
        let trust = try AppSourceScraping.appSource("TrustCenterView.swift")

        // Byte-identical MacIntegration write path (no control moved): the
        // optimistic set + rollback + iCloud push are untouched.
        #expect(macIntegration.contains("MacIntegrationPermissionStore.shared.set("))
        #expect(macIntegration.contains("permissions[id] = previous"))
        #expect(macIntegration.contains("MacIntegrationICloudBridge.shared.push("))

        // Trust still owns the Mac Control capability panel exactly once.
        #expect(trust.contains("MacControlPermissionsView()"))

        // Reciprocal cross-links point each tab at the other's one home.
        // 2026-09-06: f4ba3bd8 ("Advanced page kit") reworded both cross-links
        // for the new shell — they are pages, not tabs, and the copy is now
        // sentence-case (MacIntegrationView.swift:354, TrustCenterView.swift:225).
        // The B2.5a pin is the reciprocity, not the old wording.
        #expect(macIntegration.contains("live on the Trust page under Mac control."))
        #expect(trust.contains("live on the Mac integration page."))
    }

    // MARK: - B2.6c Settings demotion

    @Test func settingsAdvancedBlocksAreDemotedBehindABadgedDisclosure() throws {
        let source = try AppSourceScraping.appSource("SlimSettingsView.swift")

        // Persisted, collapsed-by-default Advanced disclosure.
        #expect(source.contains("@AppStorage(\"nativeagent.settingsShowAdvanced\") private var showAdvancedSettings = false"))
        // The two power-user blocks render ONLY when expanded.
        // 2026-09-06: e1f2e6ea ("the classic-only Advanced door hidden in the
        // new shell") added the `classicShell` condition — the disclosure is
        // the classic sidebar's door only; the new shell puts the same controls
        // on the Settings page as cards (SetupFeatureRows.swift). Still gated,
        // still collapsed by default.
        #expect(source.contains("if showAdvancedSettings, classicShell {"))
        #expect(source.contains("EmbeddingsSettingsSection(attention: $embeddingsAttention)"))
        #expect(source.contains("SubconsciousSettingsSection(attention: $subconsciousAttention)"))
        // Error/partial state surfaces a warn badge while collapsed.
        #expect(source.contains("if !showAdvancedSettings, embeddingsAttention || subconsciousAttention {"))
        #expect(source.contains("StatusBadge(text: \"Needs attention\", status: \"warn\")"))
        // Collapsed embeddings still detect fail-closed via the parent seed.
        #expect(source.contains("func seedEmbeddingsAttention()"))
    }

    // MARK: - B2.6d Support Snapshot reuse

    @Test func supportSnapshotReuseReproducesTheOfflineRollupIdentically() {
        // ONLY the app-added `live.*` coverage checks are excluded — the core
        // `runAll` (which a cold Support Snapshot runs) ignores its checkLLM
        // flag, so the `llm` check IS part of the offline pass and must be
        // kept. Excluding it would make a reused snapshot disagree with a cold
        // one whenever the provider/LLM check is the worst offline status.
        let offlineOK = [
            DoctorCheck(id: "storage", title: "Storage", status: "ok", detail: "", repair: nil),
            DoctorCheck(id: "tools", title: "Tools", status: "ok", detail: "", repair: nil),
            DoctorCheck(id: "llm", title: "LLM", status: "ok", detail: "", repair: nil),
        ]
        // The live.* checks are dropped even when they are the worst status.
        let withLive = offlineOK + [
            DoctorCheck(id: "live.providers", title: "Providers", status: "fail", detail: "", repair: nil),
            DoctorCheck(id: "live.telegram", title: "Telegram", status: "warn", detail: "", repair: nil),
        ]
        #expect(NativeClient.supportSnapshotOfflineRollup(withLive) == "ok")

        // The kept `llm` check drives the offline rollup exactly as a cold run.
        let llmFail = withLive + [DoctorCheck(id: "llm", title: "LLM2", status: "fail", detail: "", repair: nil)]
        #expect(NativeClient.supportSnapshotOfflineRollup(llmFail) == "fail")

        // Offline warn preserved; offline fail dominates.
        let warn = offlineOK + [DoctorCheck(id: "backups", title: "Backups", status: "warn", detail: "", repair: nil)]
        #expect(NativeClient.supportSnapshotOfflineRollup(warn) == "warn")
        let fail = warn + [DoctorCheck(id: "write_test", title: "Write", status: "fail", detail: "", repair: nil)]
        #expect(NativeClient.supportSnapshotOfflineRollup(fail) == "fail")
    }

    @Test func supportSnapshotRollupMatchesFailWarnOkPrecedence() {
        #expect(NativeClient.supportSnapshotRollup(["ok", "ok"]) == "ok")
        #expect(NativeClient.supportSnapshotRollup(["ok", "warn"]) == "warn")
        #expect(NativeClient.supportSnapshotRollup(["warn", "fail"]) == "fail")
        #expect(NativeClient.supportSnapshotRollup([]) == "ok")
    }

    @Test @MainActor
    func loadSupportDiagnosticsReusesOnlyAFreshDoctorRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-diagnostics-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.doctorReport = DoctorReport(status: "fail", repaired: false, checks: [
            DoctorCheck(id: "storage", title: "Storage", status: "ok", detail: "ready", repair: nil),
            DoctorCheck(id: "backups", title: "Backups", status: "warn", detail: "stale", repair: nil),
            DoctorCheck(id: "live.telegram", title: "Telegram", status: "fail", detail: "offline", repair: nil),
        ])
        app.doctorReportCompletedAt = Date()

        let fresh = await app.loadSupportDiagnostics()
        guard case let .loaded(diagnostics, reusedDoctorReport: true) = fresh else {
            Issue.record("a completed Doctor report inside the reuse window was not reused: \(fresh)")
            return
        }
        #expect(diagnostics.doctorStatus == "warn")

        app.doctorReportCompletedAt = Date().addingTimeInterval(-AppModel.supportSnapshotDoctorReuseTTL - 1)
        let stale = await app.loadSupportDiagnostics()
        guard case .loaded(_, reusedDoctorReport: false) = stale else {
            Issue.record("a Doctor report outside the reuse window was incorrectly reused: \(stale)")
            return
        }
    }
}
