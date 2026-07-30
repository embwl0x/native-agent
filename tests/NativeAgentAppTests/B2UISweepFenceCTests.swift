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
        #expect(macIntegration.contains("live in the Trust tab under Mac Control."))
        #expect(trust.contains("live in the Mac Integration tab."))
    }

    // MARK: - B2.6c Settings demotion

    @Test func settingsAdvancedBlocksAreDemotedBehindABadgedDisclosure() throws {
        let source = try AppSourceScraping.appSource("SlimSettingsView.swift")

        // Persisted, collapsed-by-default Advanced disclosure.
        #expect(source.contains("@AppStorage(\"nativeagent.settingsShowAdvanced\") private var showAdvancedSettings = false"))
        // The two power-user blocks render ONLY when expanded.
        #expect(source.contains("if showAdvancedSettings {"))
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

    @Test func loadSupportDiagnosticsReusesOnlyAFreshDoctorRun() throws {
        let source = try AppSourceScraping.appSource("AppModel+PersonalitySelfImprovement.swift")

        #expect(source.contains("supportSnapshotDoctorReuseTTL"))
        #expect(source.contains("getSupportDiagnostics(reusing: reuse)"))
        // Reuse is gated on a completed run within the TTL.
        #expect(source.contains("Date().timeIntervalSince(completedAt) < Self.supportSnapshotDoctorReuseTTL"))
    }
}
