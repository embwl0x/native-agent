import SwiftUI
import Observation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
import DeviceSync
#endif

@MainActor
@Observable
final class MemoryMenuActionController {
    enum Action: Equatable {
        case consolidate
        case hygiene
    }

    var runningAction: Action?
    var feedback: MemoryMenuActionFeedback?

    func run(_ action: Action, appModel: AppModel) async {
        guard runningAction == nil else { return }
        feedback = nil
        runningAction = action
        defer { runningAction = nil }
        switch action {
        case .consolidate:
            feedback = await appModel.consolidateMemory()
        case .hygiene:
            feedback = await appModel.runMemoryHygiene()
        }
    }
}

/// The memory store's upkeep and its status, as one fold at the foot of the
/// Memories page: consolidate, tidy (hygiene), rebuild the Spotlight index,
/// check again, and the status block with its Advanced diagnostics. The same
/// calls, the same operations and the same status panel the classic Memory
/// page carried in its Actions menu and header.
struct MemoryUpkeepPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var menuActionController = MemoryMenuActionController()
    @State private var spotlightStatus: String?
    @State private var cloudKitStatus: String = "checking…"
    @State private var isReindexing = false
    @State private var nativeStack: MemoryV2NativeStackSnapshot = .empty
    @State private var isRefreshing = false
    @State private var refreshNotice: MemoryToolbarRefreshPresentation?

    private var busy: Bool { menuActionController.runningAction != nil || isReindexing || isRefreshing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmbeddingModelDownloadRow()

            HStack(spacing: 8) {
                Button(menuActionController.runningAction == .consolidate ? "Consolidating…" : "Consolidate now") {
                    Task { await menuActionController.run(.consolidate, appModel: appModel) }
                }
                .accessibilityIdentifier("memories.upkeep.consolidate")
                Button(menuActionController.runningAction == .hygiene ? "Tidying…" : "Run hygiene") {
                    Task { await menuActionController.run(.hygiene, appModel: appModel) }
                }
                .accessibilityIdentifier("memories.upkeep.hygiene")
                Button(isReindexing ? "Reindexing Spotlight…" : "Reindex Spotlight") {
                    Task { await reindexSpotlight() }
                }
                .accessibilityIdentifier("memories.upkeep.reindex")
                Button(isRefreshing ? "Checking…" : "Check again") {
                    Task { await refreshMemorySurface() }
                }
                .accessibilityIdentifier("memories.upkeep.refresh")
            }
            .buttonStyle(.bordered)
            .tint(NativeAgentShell.text)
            .controlSize(.small)
            .disabled(busy)

            ForEach(notices, id: \.text) { notice in
                Text(notice.text)
                    .font(.system(size: 13))
                    .foregroundStyle(notice.adverse ? NativeAgentShell.trouble : NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // One memory status block; its Advanced diagnostics fold keeps
            // every backend row, the data root and the Spotlight reindex.
            MemoryV2NativeStackPanel(
                snapshot: nativeStack,
                cloudKitStatus: cloudKitStatus,
                summaryStatus: appModel.memoryV2Status,
                latestHygiene: appModel.latestMemoryHygiene,
                isReindexing: isReindexing,
                onReindex: { Task { await reindexSpotlight() } }
            )
        }
        .task { await refreshCloudKitStatus() }
        // Fast mode warms MiniLM at process launch. Follow that one startup
        // attempt for at most ten seconds and read only runtime state; the
        // full memory/Spotlight snapshot is intentionally not rescanned.
        .task {
            await refreshNativeStack()
            for _ in 0..<10 where nativeStack.shouldPollEmbeddingStartup {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                var snapshot = nativeStack
                await snapshot.refreshEmbeddingRuntime()
                nativeStack = snapshot
            }
        }
    }

    /// Every result line the upkeep has to say, in the order it happened.
    private var notices: [(text: String, adverse: Bool)] {
        var lines: [(text: String, adverse: Bool)] = []
        if let feedback = menuActionController.feedback {
            lines.append((feedback.message, feedback.isAdverse))
        }
        if let spotlightStatus, !spotlightStatus.isEmpty {
            lines.append((spotlightStatus, false))
        }
        if let refreshNotice {
            lines.append((refreshNotice.text, refreshNotice.isAdverse))
        }
        // F2: a disabled hygiene / consolidate says so instead of a fake success.
        if let disabled = appModel.memoryFeatureDisabledMessage, !disabled.isEmpty {
            lines.append((disabled, true))
        }
        return lines
    }

    @MainActor
    private func refreshNativeStack() async {
        nativeStack = await MemoryV2NativeStackSnapshot.load(
            dataRoot: appModel.dataRootOverride ?? NativeAgentPaths.dataRoot
        )
    }

    /// The list/proposal/status reader, the native status snapshot, and the
    /// CloudKit account status, in one user-triggered transaction.
    @MainActor
    private func refreshMemorySurface() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let refreshed = await MemoryToolbarRefreshOperation.run(
            appModel: appModel,
            dataRoot: appModel.dataRootOverride ?? NativeAgentPaths.dataRoot
        )
        nativeStack = refreshed.nativeStack
        await refreshCloudKitStatus()
        refreshNotice = refreshed.presentation
    }

    @MainActor
    private func reindexSpotlight() async {
        isReindexing = true
        defer { isReindexing = false }
        let dataRoot = appModel.dataRootOverride ?? NativeAgentPaths.dataRoot
        let outcome = await MemorySpotlightReindexOperation.run(dataRoot: dataRoot)
        spotlightStatus = outcome.userMessage
        // The status line and count must be read after the durable result, not
        // retained from before a delete-and-rebuild attempt.
        await refreshNativeStack()
    }

    @MainActor
    private func refreshCloudKitStatus() async {
        // CloudKit memory sync is not part of the active launch runtime. Even
        // the account probe is opt-in because CKContainer init can trap when
        // the installed profile lacks the CloudKit service grant.
        if !nativeAgentCloudKitAccountProbeEnabled() {
            cloudKitStatus = nativeAgentCloudKitDisabledStatus
            return
        }
        #if canImport(CloudKit)
        let statusText = await withCKTimeout("MemoryUpkeepPanel.refreshCloudKitStatus") {
            let status = try await CKContainer.default().accountStatus()
            switch status {
            case .available: return "available"
            case .noAccount: return "noAccount"
            case .restricted: return "restricted"
            case .temporarilyUnavailable: return "temporarilyUnavailable"
            case .couldNotDetermine: return "unknown"
            @unknown default: return "unknown"
            }
        }
        cloudKitStatus = statusText ?? "timeout"
        #else
        cloudKitStatus = "unsupported"
        #endif
    }

    static func localTimestamp(_ iso: String) -> String {
        UserDisplayFormatters.mediumDateTime(iso)
    }
}

/// A read-only path to the complete saved text. The list preview stays compact;
/// opening this sheet does not pin, delete, or otherwise mutate the memory.
struct MemoryFullTextView: View {
    let text: String
    /// Present only where a correction has somewhere to land (a kept memory
    /// row). Nil leaves the sheet exactly as it was.
    var onCorrect: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved memory")
                    .font(.headline)
                Spacer()
                if let onCorrect {
                    Button("Correct this") {
                        dismiss()
                        onCorrect()
                    }
                    .accessibilityIdentifier("memory.full-text.correct")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("memory.full-text.content")
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .accessibilityIdentifier("memory.full-text.sheet")
    }
}

/// The explicit toolbar refresh has three independently-read boundaries:
/// app-model content, the native store snapshot, and the optional CloudKit
/// account state. A failed store probe wins over a generic successful refresh
/// receipt because zero is meaningful only after the store was actually read.
struct MemoryToolbarRefreshPresentation: Equatable {
    let text: String
    let systemImage: String
    let isAdverse: Bool

    static func resolve(staleNotice: String?, storageReadable: Bool?) -> Self {
        if storageReadable == false {
            return Self(
                text: "Saved memories could not be read. Existing memory data is shown only where it was already loaded.",
                systemImage: "exclamationmark.triangle",
                isAdverse: true
            )
        }
        if let staleNotice, !staleNotice.isEmpty {
            return Self(
                text: staleNotice,
                systemImage: "exclamationmark.triangle",
                isAdverse: true
            )
        }
        return Self(
            text: "Memory refreshed.",
            systemImage: "arrow.clockwise",
            isAdverse: false
        )
    }
}

/// The state-bearing core of the memory upkeep's Check again action. Keeping it
/// separate from the SwiftUI closure makes the mounted control's real reads
/// executable with an injected data root, without inventing an in-memory
/// substitute for the MemoryV2 store.
@MainActor
struct MemoryToolbarRefreshOperation {
    let nativeStack: MemoryV2NativeStackSnapshot
    let presentation: MemoryToolbarRefreshPresentation

    static func run(appModel: AppModel, dataRoot: URL) async -> Self {
        await appModel.refreshForSidebarItem(.memories)
        let nativeStack = await MemoryV2NativeStackSnapshot.load(dataRoot: dataRoot)
        return Self(
            nativeStack: nativeStack,
            presentation: MemoryToolbarRefreshPresentation.resolve(
                staleNotice: appModel.panelStaleNotice(for: .memories),
                storageReadable: nativeStack.storageReadable
            )
        )
    }
}

/// Diagnostics can identify a storage location without putting an account path
/// into a support screenshot. This follows the Living Status privacy boundary:
/// a value containing the home directory is evidence of a private location,
/// not displayable path text.
enum MemoryAdvancedDiagnosticsIdentifiers: Equatable {
    case unavailable
    case privateLocation
    case visiblePath(String)

    static func dataRoot(path: String, homeDirectory: String = NSHomeDirectory()) -> Self {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return .unavailable }

        let normalizedHome = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedHome.isEmpty,
           normalizedPath.lowercased().contains(normalizedHome.lowercased()) {
            return .privateLocation
        }
        return .visiblePath(normalizedPath)
    }

    var dataRootLabel: String {
        switch self {
        case .unavailable:
            return "data root: unavailable"
        case .privateLocation:
            return "data root: private location hidden"
        case let .visiblePath(path):
            return "data root: \(path)"
        }
    }
}

/// Durable owner for the mounted "Reindex Spotlight" control. Its marker is
/// proof for one exact MemoryV2 projection generation, not a sticky claim that
/// an index rebuild happened at some unknown point in the past.
struct MemorySpotlightReindexOperation {
    enum Outcome: Equatable, Sendable {
        case indexed(count: Int)
        case changedDuringReindex
        case failed(message: String)

        var userMessage: String {
            switch self {
            case .indexed(let count):
                return "Spotlight reindexed \(count) memories"
            case .changedDuringReindex:
                return "Memories changed while indexing. Reindex again from the latest saved state."
            case .failed(let message):
                return "Spotlight reindex failed: \(message)"
            }
        }
    }

    static func run(dataRoot: URL) async -> Outcome {
        await run(dataRoot: dataRoot, client: liveClient(dataRoot: dataRoot))
    }

    static func run(
        dataRoot: URL,
        client: any SpotlightIndexClient
    ) async -> Outcome {
        let marker = markerURL(dataRoot: dataRoot)
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let generation = try await storage.projectionGenerationFingerprint()
            let memories = try await storage.listMemories(
                persona: nil,
                status: "active",
                limit: nil
            )
            let batch = memories
                .filter { !$0.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) }
                .map { (id: $0.id, text: $0.content, kind: $0.status as String?) }

            // Delete the old proof BEFORE clearing the derived index. A crash
            // or failure after `removeAll()` must read as unconfirmed rather
            // than reporting the old SQLite count over an empty Spotlight
            // domain.
            try clearMarker(at: marker)

            let indexer = SwiftNativeMemoryIndexer(client: client)
            try await indexer.removeAll()
            try await indexer.indexBatch(batch)

            let completedGeneration = try await storage.projectionGenerationFingerprint()
            guard completedGeneration == generation else {
                // A concurrent canonical write makes this batch stale. There
                // is intentionally no marker: the next reindex must start
                // from the new source generation.
                return .changedDuringReindex
            }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(
                Data((generation + "\n").utf8),
                to: marker
            )
            return .indexed(count: batch.count)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    static func markerURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".spotlight_reindexed", isDirectory: false)
    }

    private static func clearMarker(at marker: URL) throws {
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try FileManager.default.removeItem(at: marker)
    }

    private static func liveClient(dataRoot: URL) -> any SpotlightIndexClient {
        #if canImport(CoreSpotlight) && !os(Linux)
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            return SystemSpotlightIndexClient()
        }
        #endif
        // An injected/test root must not replace the user's system Spotlight
        // domain merely because the UI is hosted in this app process.
        return MockSpotlightIndexClient()
    }
}

// MARK: - MemoryV2 Apple-Native Stack panel
//
// Surfaces the four indicators that prove the daemon-era memory backend has
// been replaced with the Apple-native stack:
//   * SQLite record count read directly from `<dataRoot>/memory/memory.sqlite`
//     through MemoryV2's canonical resolved storage owner.
//   * Core ML MiniLM (Neural Engine) embedder availability — keyed off the
//     migration marker + the Core ML model URL probe.
//   * CoreSpotlight indexed count — a current-generation confirmation under
//     `<dataRoot>/memory/`, never a bare sentinel or inferred SQLite count.
//   * CloudKit account status when explicitly enabled. CKContainer probes are
//     skipped by default because this dev profile lacks the CloudKit service
//     grant and CKContainer can trap synchronously instead of throwing.
//
// Designed to be cheap-to-render and safe-when-empty: if any probe fails the
// row falls back to "unknown" / "0" rather than vanishing — UI presence is the
// signal the panel is wired even on a fresh install.
struct MemoryV2NativeStackSnapshot: Sendable, Equatable {
    var sqliteRecordCount: Int
    var sqliteProposalCount: Int
    /// `nil` before the direct store probe, `false` when it could not read.
    var storageReadable: Bool?
    var migrated: Bool
    var coreMLReady: Bool
    var coreMLModelLabel: String
    var embedderDimensions: Int
    // 2026-06-07: runtime truth fields so the UI can distinguish
    // "file exists" from "actually working." the user asked for a clear
    // "tell me if it's not working" signal. These come from
    // SwiftNativeMemoryV2.embeddingRuntimeSnapshot() — the runtime's
    // own state, not a disk probe.
    var coreMLLoaded: Bool
    var coreMLLastLoadError: String?
    var coreMLLoadCount: Int
    var embeddingMode: String
    var spotlightReindexed: Bool
    var spotlightIndexedCount: Int
    var cloudKitAccountStatus: String
    var dataRootPath: String

    /// Visual + textual status derived from the runtime fields above.
    /// One of: working / loaded / ready / broken / missing.
    enum EmbedderHealth {
        case working(loadCount: Int)   // green
        case ready                      // orange — resources present, never loaded
        case broken(reason: String)     // red — lastLoadError set
        case missing                    // red — bundled resources not reachable

        var label: String {
            switch self {
            case .working(let n): return "working (\(n) load\(n == 1 ? "" : "s"))"
            case .ready: return "ready, not yet loaded"
            case .broken(let r): return "BROKEN: \(r)"
            case .missing: return "MODEL MISSING"
            }
        }
        var isHealthy: Bool {
            if case .working = self { return true }
            return false
        }
        var needsAttention: Bool {
            switch self {
            case .broken, .missing: return true
            default: return false
            }
        }
    }

    /// Derive the at-a-glance health state. Caller decides how to
    /// render — typical: green for working, orange for ready, red for
    /// broken/missing.
    var embedderHealth: EmbedderHealth {
        if let err = coreMLLastLoadError {
            return .broken(reason: err)
        }
        if coreMLLoaded {
            return .working(loadCount: coreMLLoadCount)
        }
        if coreMLReady {
            return .ready
        }
        return .missing
    }

    var shouldPollEmbeddingStartup: Bool {
        embeddingMode == ManagedEmbeddingProvider.performanceMode
            && coreMLReady
            && !coreMLLoaded
            && coreMLLastLoadError == nil
    }

    static let empty = MemoryV2NativeStackSnapshot(
        sqliteRecordCount: 0,
        sqliteProposalCount: 0,
        storageReadable: nil,
        migrated: false,
        coreMLReady: false,
        coreMLModelLabel: "MiniLM-L6-v2 (pending .mlpackage)",
        embedderDimensions: 384,
        coreMLLoaded: false,
        coreMLLastLoadError: nil,
        coreMLLoadCount: 0,
        embeddingMode: "unknown",
        spotlightReindexed: false,
        spotlightIndexedCount: 0,
        cloudKitAccountStatus: "checking…",
        dataRootPath: ""
    )

    static func load(
        dataRoot: URL = NativeAgentPaths.dataRoot
    ) async -> MemoryV2NativeStackSnapshot {
        var snap = MemoryV2NativeStackSnapshot.empty
        snap.dataRootPath = dataRoot.path
        var spotlightEligibleCount = 0
        var storageGeneration: String?

        // SQLite probe — open the same store MemoryV2+Storage.swift uses and
        // list active rows. A clean empty store is 0; a failed read remains
        // explicit so the panel cannot present it as an empty memory profile.
        do {
            let store = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let memories = try await store.listMemories(persona: nil, status: nil, limit: nil)
            snap.storageReadable = true
            snap.sqliteRecordCount = memories.count
            let activeMemories = try await store.listMemories(persona: nil, status: "active", limit: nil)
            spotlightEligibleCount = activeMemories.filter {
                !$0.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix)
            }.count
            storageGeneration = try await store.projectionGenerationFingerprint()
            if let proposals = try? await store.listProposals(status: "pending") {
                snap.sqliteProposalCount = proposals.count
            }
        } catch {
            snap.storageReadable = false
        }

        // Migration marker — written by MemoryV2Migrator on a successful
        // JSON → SQLite import. Presence proves the new store is the
        // canonical backend on this data root.
        let marker = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".migrated_to_sqlite_v1", isDirectory: false)
        snap.migrated = FileManager.default.fileExists(atPath: marker.path)

        // Core ML MiniLM probe. 2026-06-07 task #88: this used to roll its
        // own `Bundle.main.url(forResource: "MiniLM_L6_v2", ...)` check that
        // (a) used the wrong filename (the actual SPM resource is
        // `minilm.mlpackage`) and (b) couldn't traverse into the
        // NativeAgentCore_MemoryV2.bundle sub-bundle where the runtime
        // actually looks. Result: page perpetually said "pending .mlpackage"
        // even with a fully staged model. Now we ask the runtime's own
        // resolver — single source of truth, both `bundled` and
        // installedAppFallbackBundle paths covered. An installed model whose
        // manifest is unusable is NOT ready and never reads as the bundled
        // MiniLM (S12, 2026-09-26); refreshEmbeddingRuntime() below carries
        // the reason as the load error.
        do {
            if let installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot) {
                snap.coreMLReady = true
                snap.coreMLModelLabel = installed.modelID + " (installed)"
                snap.embedderDimensions = installed.dimensions
            } else if CoreMLEmbeddingProvider.bundledResourcesAvailable() {
                snap.coreMLReady = true
                snap.coreMLModelLabel = CoreMLEmbeddingProvider.bundledModelID + " (bundled)"
            }
        } catch {
            snap.coreMLModelLabel = "installed model did not load"
        }

        // Runtime truth fields — the disk probe above tells us if
        // resources are reachable, but only the runtime knows whether
        // the model actually loaded and inference works. Pull
        // coreMLLoaded / lastLoadError / loadCount from
        // SwiftNativeMemoryV2's snapshot.
        await snap.refreshEmbeddingRuntime()

        // Spotlight — the `.spotlight_reindexed` sentinel is written by
        // MemorySpotlightBootstrap on first launch after the
        // cutover. Presence alone is not proof: a failed reindex can clear the
        // domain after a previous marker was written. The marker is valid only
        // when it names the current canonical projection generation.
        let spotMarker = MemorySpotlightReindexOperation.markerURL(dataRoot: dataRoot)
        if let storageGeneration,
           let markerData = try? Data(contentsOf: spotMarker),
           String(data: markerData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == storageGeneration {
            snap.spotlightReindexed = true
            snap.spotlightIndexedCount = spotlightEligibleCount
        }

        // CloudKit memory sync is not an active launch owner. Keep even the
        // account probe opt-in because CKContainer can trap synchronously when
        // the installed profile lacks the CloudKit service grant.
        guard nativeAgentCloudKitAccountProbeEnabled() else {
            snap.cloudKitAccountStatus = nativeAgentCloudKitDisabledStatus
            return snap
        }
        #if canImport(CloudKit)
        snap.cloudKitAccountStatus = await withCKTimeout("MemoryV2NativeStackSnapshot.cloudKitAccount") {
            let status = try await CKContainer.default().accountStatus()
            switch status {
            case .available: return "available"
            case .noAccount: return "noAccount"
            case .restricted: return "restricted"
            case .temporarilyUnavailable: return "temporarilyUnavailable"
            case .couldNotDetermine: return "unknown"
            @unknown default: return "unknown"
            }
        } ?? "timeout"
        #else
        snap.cloudKitAccountStatus = "unsupported"
        #endif

        return snap
    }

    mutating func refreshEmbeddingRuntime() async {
        guard let runtime = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() else {
            return
        }
        embeddingMode = runtime.mode
        coreMLLoaded = runtime.coreMLLoaded
        coreMLLastLoadError = runtime.lastLoadError
        coreMLLoadCount = runtime.loadCount
    }
}

// MARK: - Plain-English memory status copy
//
// UI-5 (2026-08-01, public era): pure string helpers so the honesty copy is
// unit-testable without a UI snapshot harness. Values in, Strings out.
enum MemoryStatusPlainCopy {
    enum StorageAvailability: Equatable {
        case checking
        case readable
        case unavailable
        case unknown
    }

    /// Reconcile the status reader with the direct panel probe. A failed probe
    /// always wins over stale success data: zero is meaningful only after a
    /// successful store read.
    static func storageAvailability(
        status: String?,
        snapshotReadable: Bool?
    ) -> StorageAvailability {
        if snapshotReadable == false { return .unavailable }
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ready", "empty": return .readable
        case "unavailable", "failed", "error": return .unavailable
        case nil:
            return snapshotReadable == true ? .readable : .checking
        default:
            return .unknown
        }
    }

    /// Prefer the v2 status counts when the app has them; fall back to the
    /// direct SQLite probe on a fresh install where status has not loaded yet.
    static func savedCount(active: Int?, sqliteRecordCount: Int) -> Int {
        if let active, active > 0 { return active }
        return sqliteRecordCount
    }

    /// Vocabulary understood by NativeAgentTheme.statusColor / StatusBadge.
    static func statusText(
        health: MemoryV2NativeStackSnapshot.EmbedderHealth,
        storage: StorageAvailability = .readable
    ) -> String {
        switch storage {
        case .unavailable: return "failed"
        case .checking, .unknown: return "warn"
        case .readable: break
        }
        switch health {
        case .working: return "ok"
        case .ready: return "warn"
        case .broken, .missing: return "failed"
        }
    }

    static func headline(
        savedCount: Int,
        health: MemoryV2NativeStackSnapshot.EmbedderHealth,
        storage: StorageAvailability = .readable
    ) -> String {
        switch storage {
        case .checking:
            return "Checking saved memories…"
        case .unavailable:
            return "Saved memories could not be read."
        case .unknown:
            return "Saved-memory status is unclear."
        case .readable:
            break
        }
        if health.needsAttention {
            return "Memories are being saved, but smart search is not working."
        }
        if savedCount == 0 {
            return "No memories saved yet."
        }
        return "Memory is working."
    }

    static func countsLine(
        savedCount: Int,
        pinned: Int,
        pendingProposals: Int,
        storage: StorageAvailability = .readable
    ) -> String {
        switch storage {
        case .checking:
            return "Checking whether saved memories are available."
        case .unavailable:
            return "Refresh to try reading saved memories again. This does not mean none are saved."
        case .unknown:
            return "Refresh to confirm the saved-memory state."
        case .readable:
            break
        }
        guard savedCount > 0 || pendingProposals > 0 else {
            return "Memories appear here as the agent learns from your conversations."
        }
        var parts = [savedCount == 1 ? "1 memory saved" : "\(savedCount) memories saved"]
        if pinned > 0 { parts.append("\(pinned) pinned") }
        if pendingProposals > 0 {
            parts.append(pendingProposals == 1
                ? "1 waiting for your approval"
                : "\(pendingProposals) waiting for your approval")
        }
        return parts.joined(separator: ". ") + "."
    }

    /// Non-nil only when the user should know something is off. The technical
    /// reason string stays in Advanced Diagnostics.
    static func attentionDetail(
        health: MemoryV2NativeStackSnapshot.EmbedderHealth,
        storage: StorageAvailability = .readable
    ) -> String? {
        switch storage {
        case .checking:
            return nil
        case .unavailable:
            return "Saved memories could not be read. Refresh to try again; this is not evidence that none are saved."
        case .unknown:
            return "The saved-memory status was not recognized. Refresh to confirm it."
        case .readable:
            break
        }
        switch health {
        case .working:
            return nil
        case .ready:
            return "Smart search starts the first time you search."
        case .broken:
            return "Smart search could not start. Searches fall back to matching words. Open Advanced Diagnostics for the reason."
        case .missing:
            return "The on-device search model is not installed. Searches fall back to matching words."
        }
    }

    static func searchQualityLine(
        realSemanticAvailable: Bool,
        storage: StorageAvailability = .readable
    ) -> String {
        switch storage {
        case .checking:
            return "Checking saved memories before search results are shown."
        case .unavailable:
            return "Saved-memory search is unavailable until the memory store can be read."
        case .unknown:
            return "Search availability is unclear until the saved-memory status is refreshed."
        case .readable:
            break
        }
        return realSemanticAvailable
            ? "Search finds memories by meaning, not just matching words."
            : "Search matches words for now. Meaning-based search turns on once the on-device model is ready."
    }
}

private struct MemoryV2NativeStackPanel: View {
    let snapshot: MemoryV2NativeStackSnapshot
    let cloudKitStatus: String
    // 2026-07-23 B2.5b: summary counts/backend/hygiene folded in from the
    // former standalone MemoryV2SummaryBar so this panel is the ONE Memory
    // status block. Optional so the panel still renders on a fresh install.
    var summaryStatus: MemoryV2Status? = nil
    var latestHygiene: MemoryHygieneReport? = nil
    let isReindexing: Bool
    let onReindex: () -> Void
    // Collapsed by default; mirrors the Advanced disclosures in TrustCenterView
    // and MacControlPermissionsView.
    @State private var showAdvancedDiagnostics = false

    // UI-5 (public-user honesty, 2026-08-01): the panel used to open on SQLite,
    // Core ML, CoreSpotlight, CloudKit and a data-root path. A person who did
    // not build this app has no way to read that. Plain status leads; every
    // backend row still ships inside Advanced Diagnostics.
    private var storageAvailability: MemoryStatusPlainCopy.StorageAvailability {
        MemoryStatusPlainCopy.storageAvailability(
            status: summaryStatus?.status,
            snapshotReadable: snapshot.storageReadable
        )
    }

    private var statusText: String {
        MemoryStatusPlainCopy.statusText(
            health: snapshot.embedderHealth,
            storage: storageAvailability
        )
    }

    private var healthTint: Color {
        switch statusText {
        case "ok": return .green
        case "failed": return .red
        default: return .orange
        }
    }

    var body: some View {
        NativePanel(title: "Memory Status", systemImage: "brain.head.profile", tint: healthTint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    InlineStatusDot(status: statusText)
                    Text(MemoryStatusPlainCopy.headline(
                        savedCount: MemoryStatusPlainCopy.savedCount(
                            active: summaryStatus?.counts?.active,
                            sqliteRecordCount: snapshot.sqliteRecordCount
                        ),
                        health: snapshot.embedderHealth,
                        storage: storageAvailability
                    ))
                    .font(NativeAgentFont.section)
                    Spacer()
                }
                Text(MemoryStatusPlainCopy.countsLine(
                    savedCount: MemoryStatusPlainCopy.savedCount(
                        active: summaryStatus?.counts?.active,
                        sqliteRecordCount: snapshot.sqliteRecordCount
                    ),
                    pinned: summaryStatus?.counts?.pinned ?? 0,
                    pendingProposals: summaryStatus?.counts?.pendingProposals ?? snapshot.sqliteProposalCount,
                    storage: storageAvailability
                ))
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
                if let attention = MemoryStatusPlainCopy.attentionDetail(
                    health: snapshot.embedderHealth,
                    storage: storageAvailability
                ) {
                    Text(attention)
                        .font(.caption)
                        .foregroundStyle(statusText == "failed" ? .red : .orange)
                }
                Text(MemoryStatusPlainCopy.searchQualityLine(
                    realSemanticAvailable: summaryStatus?.embedding?.realSemanticAvailable == true,
                    storage: storageAvailability
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $showAdvancedDiagnostics) {
                    advancedDiagnostics
                        .padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Advanced Diagnostics")
                                .font(NativeAgentFont.section)
                            Text("Storage, on-device search model, Spotlight, iCloud, and file locations.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .togglesDisclosure($showAdvancedDiagnostics)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            MemoryV2SummaryBar(status: summaryStatus, latest: latestHygiene)
            HStack(spacing: 12) {
                stackRow(
                    icon: "cylinder.split.1x2",
                    title: "SQLite",
                    value: storageAvailability == .unavailable
                        ? "unavailable"
                        : "\(snapshot.sqliteRecordCount) records",
                    detail: storageAvailability == .unavailable
                        ? "could not read saved memories"
                        : (snapshot.migrated ? "migrated" : "fresh"),
                    tint: storageAvailability == .unavailable
                        ? .red
                        : (snapshot.sqliteRecordCount > 0 ? .green : .secondary)
                )
                    // 2026-06-07: at-a-glance embedder health. the user asked
                    // for a clear "tell me if it's not working" indicator.
                    //   green  = inference running, N successful loads
                    //   orange = resources reachable but model not loaded yet
                    //   red    = lastLoadError set OR resources missing
                    // detail shows model + dimensions; on broken state the
                    // detail surfaces the actual error message so the user
                    // can see exactly what went wrong.
                    stackRow(
                        icon: snapshot.embedderHealth.needsAttention
                            ? "exclamationmark.triangle.fill"
                            : "cpu",
                        title: "Core ML MiniLM",
                        value: snapshot.embedderHealth.label,
                        detail: "\(snapshot.embedderDimensions)-d · \(snapshot.coreMLModelLabel)",
                        tint: {
                            switch snapshot.embedderHealth {
                            case .working: return .green
                            case .ready: return .orange
                            case .broken, .missing: return .red
                            }
                        }()
                    )
                }
            HStack(spacing: 12) {
                stackRow(
                    icon: "magnifyingglass.circle",
                    title: "CoreSpotlight",
                    value: isReindexing
                        ? "reindexing…"
                        : (snapshot.spotlightReindexed
                            ? "\(snapshot.spotlightIndexedCount) indexed"
                            : "not indexed"),
                    detail: snapshot.spotlightReindexed ? "reindex sentinel present" : "tap Spotlight to index",
                    tint: snapshot.spotlightReindexed ? .green : .secondary
                )
                stackRow(
                    icon: "icloud",
                    title: "CloudKit",
                    value: cloudKitStatus,
                    detail: snapshot.cloudKitAccountStatus == cloudKitStatus
                        ? "account check"
                        : "account: \(snapshot.cloudKitAccountStatus)",
                    tint: cloudKitStatus == "available" ? .green : .secondary
                )
            }
            // UI-5: the long-term memory profile's real filename lives here,
            // inside Advanced Diagnostics, and nowhere else in the UI.
            Text("long-term memory profile file: USER.md")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Text(MemoryAdvancedDiagnosticsIdentifiers.dataRoot(
                path: snapshot.dataRootPath
            ).dataRootLabel)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            Button(isReindexing ? "Reindexing Spotlight…" : "Reindex Spotlight", systemImage: "magnifyingglass") {
                onReindex()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isReindexing)
        }
    }

    @ViewBuilder
    private func stackRow(icon: String, title: String, value: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(value).font(.caption).foregroundStyle(tint)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MemoryV2SummaryBar: View {
    let status: MemoryV2Status?
    let latest: MemoryHygieneReport?

    private var counts: MemoryV2Counts? { status?.counts }
    private var backend: String { status?.embedding?.activeBackend ?? "unknown" }
    private var hygieneText: String {
        if let latest {
            return Self.hygieneText(for: latest)
        }
        if let h = status?.hygiene {
            return Self.hygieneText(for: h)
        }
        return "hygiene scheduled"
    }

    private static func hygieneText(for report: MemoryHygieneReport) -> String {
        let before = report.beforeCount ?? report.afterCount ?? 0
        let processed = report.normalized ?? 0
        let merged = report.archivedDuplicates ?? 0
        let archived = report.archivedReflections ?? 0
        let accepted = report.distilledFactsAdded ?? 0
        let decayed = report.decayedMemories ?? 0
        let changed = merged + archived + accepted + decayed
        let runLabel = report.createdAt.map { "last hygiene \(MemoryUpkeepPanel.localTimestamp($0))" } ?? "last hygiene"
        let scanned = "scanned \(before) \(before == 1 ? "memory" : "memories") / \(processed) \(processed == 1 ? "proposal" : "proposals")"
        var parts: [String] = []
        if merged > 0 { parts.append("merged \(merged)") }
        if archived > 0 { parts.append("archived \(archived)") }
        if accepted > 0 { parts.append("accepted \(accepted)") }
        if decayed > 0 { parts.append("decayed \(decayed)") }
        // Honest-status fix (2026-07-24): a staged run planned work on a
        // candidate; it is not applied until the Activity card is approved.
        if report.status == "staged" {
            let planned = parts.isEmpty ? "changes" : parts.joined(separator: ", ")
            return "\(runLabel): staged \(planned) for approval" + nextSuffix(for: report)
        }
        if report.status == "refused" {
            return "\(runLabel): probe gate refused to stage" + nextSuffix(for: report)
        }
        if changed == 0 {
            return "\(runLabel): \(scanned), no cleanup needed" + nextSuffix(for: report)
        }
        return "\(runLabel): \(scanned), \(parts.joined(separator: ", "))" + nextSuffix(for: report)
    }

    // Taste pass 2026-07-24: the next-scheduled stamp used to live on a second
    // hygiene line below the tab picker; it belongs in this panel's single
    // status line (B2.5b: one memory status block).
    private static func nextSuffix(for report: MemoryHygieneReport) -> String {
        report.nextScheduled.map { " · next \(MemoryUpkeepPanel.localTimestamp($0))" } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if status?.status == "unavailable" {
                Label("Saved memories unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text("The memory reader did not return counts; zero is not an empty-memory result.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if status == nil {
                Label("Memory status still loading", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Label("Memory v\(status?.version ?? "2")", systemImage: "brain.head.profile")
                        .font(.caption.weight(.semibold))
                    Text("\(counts?.active ?? 0) active")
                    Text("\(counts?.pinned ?? 0) pinned")
                    Text("\(counts?.pendingProposals ?? 0) proposals")
                    Spacer()
                    Text(backend)
                        .foregroundStyle(status?.embedding?.realSemanticAvailable == true ? .green : .orange)
                }
                .font(.caption)
                Text(hygieneText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
