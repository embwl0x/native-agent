import SwiftUI
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
#endif

struct MemoryView: View {
    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var memoryProposalMessage: String?
    @State private var selectedTab: MemoryViewTab

    // PATCH-2026-06-06: activity-flatten — when ActivityView drills into the
    // "Memory Proposals" section, the user wants to land on the pending
    // proposal queue, not the active-memory list. Default stays `.active` so
    // existing call sites are unchanged.
    init(initialTab: MemoryViewTab = .active) {
        _selectedTab = State(initialValue: initialTab)
    }
    @State private var spotlightStatus: String?
    @State private var cloudKitStatus: String = "checking…"
    @State private var isReindexing = false
    @State private var nativeStack: MemoryV2NativeStackSnapshot = .empty
    @State private var semanticSearchTask: Task<Void, Never>?

    private var filteredMemories: [MemoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // F2: when the search box has non-trivial input, prefer the
        // semantic-recall results AppModel populated via SwiftNativeMemoryV2.
        // Empty/very-short queries → full list. The previous code did a plain
        // substring scan on text/layer regardless of length.
        if trimmed.isEmpty { return appModel.memories }
        if let results = appModel.memorySearchResults { return results }
        // Substring fallback for the moment between keystroke and async recall.
        let lower = trimmed.lowercased()
        return appModel.memories.filter {
            $0.text.lowercased().contains(lower) || $0.layer.lowercased().contains(lower)
        }
    }

    private var pendingMemoryProposals: [MemoryProposalRecord] {
        appModel.memoryProposals.filter { $0.status == "pending" }
    }

    private var rejectedMemoryProposals: [MemoryProposalRecord] {
        appModel.memoryProposals.filter { $0.status == "rejected" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search memory (semantic recall)", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("Consolidate memory", systemImage: "arrow.triangle.merge") {
                        Task { await appModel.consolidateMemory() }
                    }
                    Button("Run hygiene", systemImage: "sparkles") {
                        Task { await appModel.runMemoryHygiene() }
                    }
                    Button(isReindexing ? "Reindexing Spotlight…" : "Reindex Spotlight", systemImage: "magnifyingglass") {
                        Task { await reindexSpotlight() }
                    }
                    .disabled(isReindexing)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // 2026-07-23 B2.5b: the triple status readout (Apple-Native Stack
            // panel + MemoryV2SummaryBar + standalone cloudKitBadge) collapses
            // into ONE status block. The summary counts/backend/hygiene fold
            // into the top of the stack panel; the standalone iCloud badge is
            // dropped because CloudKit already renders as a stack row. No datum
            // shown before disappears.
            MemoryV2NativeStackPanel(
                snapshot: nativeStack,
                cloudKitStatus: cloudKitStatus,
                summaryStatus: appModel.memoryV2Status,
                latestHygiene: appModel.latestMemoryHygiene,
                isReindexing: isReindexing,
                onReindex: { Task { await reindexSpotlight() } }
            )

            Picker("Tab", selection: $selectedTab) {
                ForEach(MemoryViewTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let spotlightStatus, !spotlightStatus.isEmpty {
                Label(spotlightStatus, systemImage: "magnifyingglass.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let searchError = appModel.memorySearchError, !searchError.isEmpty {
                Label(searchError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let memoryProposalMessage, !memoryProposalMessage.isEmpty {
                Label(memoryProposalMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // F2: surface the "panel disabled / not implemented" envelope so
            // the user sees a feature-disabled badge instead of a fake success
            // toast for hygiene / consolidate.
            if let disabled = appModel.memoryFeatureDisabledMessage, !disabled.isEmpty {
                Label(disabled, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.orange)
            }

            // Taste pass 2026-07-24: the hygiene last-run/next-run line moved
            // into MemoryV2NativeStackPanel's status line (B2.5b: one memory
            // status block); a second copy here read as duplicate chrome.

            switch selectedTab {
            case .active: activeTab
            case .pending: pendingTab
            case .tombstones: tombstonesTab
            }
        }
        .padding()
        .navigationTitle("Memory")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshForSidebarItem(.memories) }
            }
        }
        .task { await refreshCloudKitStatus() }
        // 2026-06-07: the user caught Memory page showing "ready, not loaded"
        // even with Fast mode on — the snapshot loads once on .task and
        // never refreshes. If the page opened before the launch-time
        // detached warmup finished (~100-900ms), the cached snapshot
        // never updates. Poll only during that transient ready/not-loaded
        // state, then stop so an idle Memory page does not wake the app on a
        // forever cadence.
        .task {
            await refreshNativeStack()
            // Fast mode warms MiniLM at process launch. Follow that one startup
            // attempt for at most ten seconds and read only runtime state; the
            // full memory/Spotlight snapshot is intentionally not rescanned.
            for _ in 0..<10 where shouldContinueNativeStackStartupPoll() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await refreshNativeEmbeddingRuntime()
            }
        }
        // F2: kick semantic recall whenever the search query changes. The
        // AppModel method clears `memorySearchResults` for trivial inputs so
        // the full list comes back automatically.
        .onChange(of: query) { _, newValue in
            semanticSearchTask?.cancel()
            semanticSearchTask = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                await appModel.runMemorySemanticSearch(query: newValue)
            }
        }
        .onDisappear {
            semanticSearchTask?.cancel()
        }
    }

    @MainActor
    private func refreshNativeStack() async {
        nativeStack = await MemoryV2NativeStackSnapshot.load()
    }

    @MainActor
    private func refreshNativeEmbeddingRuntime() async {
        var snapshot = nativeStack
        await snapshot.refreshEmbeddingRuntime()
        nativeStack = snapshot
    }

    @MainActor
    private func shouldContinueNativeStackStartupPoll() -> Bool {
        nativeStack.shouldPollEmbeddingStartup
    }

    // Dead-weight sweep 2026-07-03: the bulk Pin/Archive/Delete bar (v2
    // stubs since 2026-06-10), the JSON-export toast stub, and the row
    // selection checkboxes that existed only to feed them are removed.
    // Per-row Pin/Delete cover the live operations; bulk ops return with
    // real wiring if v2 ever lands them.

    @ViewBuilder
    private var activeTab: some View {
        if filteredMemories.isEmpty {
            NativeEmptyState(
                title: query.isEmpty ? "No Memories Yet" : "No Matches",
                detail: query.isEmpty
                    ? "Memories appear here as the agent learns from your conversations. Start chatting and useful facts will show up."
                    : "Nothing in memory matches \(query.isEmpty ? "" : "“\(query)”"). Clear the search box to see all memories.",
                systemImage: query.isEmpty ? "brain" : "magnifyingglass"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredMemories) { memory in
                MemoryRowEditor(memory: memory)
            }
        }
    }

    @ViewBuilder
    private var pendingTab: some View {
        if pendingMemoryProposals.isEmpty {
            NativeEmptyState(
                title: "No Pending Proposals",
                detail: "When the agent wants to keep a new durable fact, it shows up here for your approval.",
                systemImage: "tray"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MemoryProposalReviewPanel(
                proposals: pendingMemoryProposals,
                statusMessage: $memoryProposalMessage
            )
        }
    }

    @ViewBuilder
    private var tombstonesTab: some View {
        if rejectedMemoryProposals.isEmpty {
            NativeEmptyState(
                title: "Nothing Deleted",
                detail: "Rejected memory proposals are kept here so the same fact can't sneak back in. Nothing rejected yet.",
                systemImage: "xmark.bin"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(rejectedMemoryProposals) { proposal in
                VStack(alignment: .leading, spacing: 4) {
                    Label("rejected", systemImage: "xmark.bin")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(proposal.display_text ?? proposal.fact_text)
                        .textSelection(.enabled)
                    Text("seen \(proposal.recurrence_count)x")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @MainActor
    private func reindexSpotlight() async {
        isReindexing = true
        defer { isReindexing = false }
        #if canImport(CoreSpotlight)
        let domain = "memory.nativeagent"
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            let items: [CSSearchableItem] = appModel.memories.map { rec in
                let attrs = CSSearchableItemAttributeSet(contentType: .text)
                attrs.title = String(rec.text.prefix(80))
                attrs.contentDescription = rec.text
                attrs.keywords = [rec.layer]
                return CSSearchableItem(
                    uniqueIdentifier: rec.id,
                    domainIdentifier: domain,
                    attributeSet: attrs
                )
            }
            if !items.isEmpty {
                try await index.indexSearchableItems(items)
            }
            spotlightStatus = "Spotlight reindexed \(items.count) memories"
        } catch {
            spotlightStatus = "Spotlight reindex failed: \(error.localizedDescription)"
        }
        #else
        spotlightStatus = "Spotlight unavailable on this platform"
        #endif
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
        let statusText = await withCKTimeout("MemoryView.refreshCloudKitStatus") {
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

private struct MemoryProposalReviewPanel: View {
    @Environment(AppModel.self) private var appModel
    let proposals: [MemoryProposalRecord]
    @Binding var statusMessage: String?

    var body: some View {
        NativePanel(title: "Memory Proposals", systemImage: "brain.head.profile") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review durable user facts the agent wants to keep in USER.md. One-off project state is compressed into the graph instead of asking for approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(proposals) { proposal in
                            MemoryProposalReviewRow(
                                proposal: proposal,
                                onApprove: { decide(proposal, approve: true) },
                                onReject: { decide(proposal, approve: false) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private func decide(_ proposal: MemoryProposalRecord, approve: Bool) {
        Task {
            do {
                let result: [String: Any]
                if approve {
                    result = try await appModel.approveMemoryProposal(id: proposal.proposal_id)
                } else {
                    result = try await appModel.rejectMemoryProposal(id: proposal.proposal_id)
                }
                statusMessage = (result["status"] as? String) == "pending_approval"
                    ? "Memory decision queued"
                    : (approve ? "Memory proposal approved" : "Memory proposal rejected")
            } catch {
                statusMessage = "Memory proposal failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct MemoryProposalReviewRow: View {
    let proposal: MemoryProposalRecord
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("memory", systemImage: "brain.head.profile")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.12), in: Capsule())
                Text(proposal.evidenceSummary)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(proposal.display_text ?? proposal.fact_text)
                .font(NativeAgentFont.body)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Deny", systemImage: "xmark", action: onReject)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Approve", systemImage: "checkmark", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(NativeAgentSpacing.sm)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MemoryRowEditor: View {
    let memory: MemoryRecord
    @Environment(AppModel.self) private var appModel
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            Text(memory.text)
                .textSelection(.enabled)
                .lineLimit(2)
            if let tags = memory.tags, !tags.isEmpty {
                tagChipsRow(tags)
            }
            provenanceLine
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Delete this memory?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Memory", role: .destructive) {
                Task { await deleteConfirmedMemory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201c}\(MemoryDeletionPresentation.preview(for: memory.text))\u{201d}\n\nThis cannot be undone.")
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack {
            Label(memory.layer.capitalized, systemImage: memory.pinned == true ? "pin.fill" : "brain")
                .font(.caption)
                .foregroundStyle(memory.pinned == true ? .orange : .secondary)
            Spacer()
            Button(memory.pinned == true ? "Unpin" : "Pin", systemImage: memory.pinned == true ? "pin.slash" : "pin") {
                Task { await appModel.pinMemory(memory, pinned: !(memory.pinned ?? false)) }
            }
            Button(isDeleting ? "Deleting\u{2026}" : "Delete", systemImage: isDeleting ? "hourglass" : "trash") {
                showingDeleteConfirmation = true
            }
            .foregroundStyle(.red)
            .disabled(isDeleting)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func tagChipsRow(_ tags: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var provenanceLine: some View {
        // Read-only: source · confidence · last-used relative time. ALWAYS shown.
        let source = memory.sourceRunId ?? "manual"
        let conf = String(format: "%.0f%%", memory.confidence * 100)
        let when = relativeTimeString(memory.updatedAt ?? memory.createdAt)
        Text("\(source) · conf \(conf) · used \(when)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func relativeTimeString(_ iso: String) -> String {
        UserDisplayFormatters.relativeISOTimestamp(iso, unitsStyle: .abbreviated, fallback: iso)
    }

    @MainActor
    private func deleteConfirmedMemory() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        await appModel.deleteMemory(memory)
        if appModel.statusText.hasPrefix("Memory delete failed:") {
            appModel.systemToasts.push(error: appModel.statusText)
        }
    }
}

enum MemoryDeletionPresentation {
    static let previewCharacterLimit = 96

    static func preview(for text: String, maxCharacters: Int = previewCharacterLimit) -> String {
        guard maxCharacters > 0 else { return "" }
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let candidate = normalized.isEmpty ? "Empty memory" : normalized
        guard candidate.count > maxCharacters else { return candidate }
        guard maxCharacters > 1 else { return "\u{2026}" }
        return String(candidate.prefix(maxCharacters - 1)) + "\u{2026}"
    }
}

// MARK: - MemoryV2 Apple-Native Stack panel
//
// Surfaces the four indicators that prove the daemon-era memory backend has
// been replaced with the Apple-native stack:
//   * SQLite record count read directly from `<dataRoot>/memory/memory.sqlite`
//     via `MemoryStorage(dataRoot:).listMemories(...)`.
//   * Core ML MiniLM (Neural Engine) embedder availability — keyed off the
//     migration marker + the Core ML model URL probe.
//   * CoreSpotlight indexed count — the `.spotlight_reindexed` sentinel under
//     `<dataRoot>/memory/` plus the SQLite-row count as an upper bound.
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

    static func load() async -> MemoryV2NativeStackSnapshot {
        let dataRoot = NativeAgentPaths.dataRoot
        var snap = MemoryV2NativeStackSnapshot.empty
        snap.dataRootPath = dataRoot.path

        // SQLite probe — open the same store MemoryV2+Storage.swift uses and
        // list active rows. `try?` so a fresh install with no sqlite yet stays
        // at 0 rather than vanishing the panel.
        if let store = try? MemoryStorage(dataRoot: dataRoot) {
            if let memories = try? await store.listMemories(persona: nil, status: nil, limit: nil) {
                snap.sqliteRecordCount = memories.count
            }
            if let proposals = try? await store.listProposals(status: "pending") {
                snap.sqliteProposalCount = proposals.count
            }
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
        // installedAppFallbackBundle paths covered. Falls back to the
        // <dataRoot>/extras/coreml legacy path for users who staged the
        // model manually.
        if CoreMLEmbeddingProvider.bundledResourcesAvailable() {
            snap.coreMLReady = true
            snap.coreMLModelLabel = "all-MiniLM-L6-v2 (bundled)"
        } else {
            let extrasURL = dataRoot
                .appendingPathComponent("extras", isDirectory: true)
                .appendingPathComponent("coreml", isDirectory: true)
                .appendingPathComponent("MiniLM_L6_v2.mlpackage", isDirectory: true)
            if FileManager.default.fileExists(atPath: extrasURL.path) {
                snap.coreMLReady = true
                snap.coreMLModelLabel = "all-MiniLM-L6-v2 (extras)"
            }
        }

        // Runtime truth fields — the disk probe above tells us if
        // resources are reachable, but only the runtime knows whether
        // the model actually loaded and inference works. Pull
        // coreMLLoaded / lastLoadError / loadCount from
        // SwiftNativeMemoryV2's snapshot.
        await snap.refreshEmbeddingRuntime()

        // Spotlight — the `.spotlight_reindexed` sentinel is written by
        // MemorySpotlightBootstrap on first launch after the
        // cutover. When present, every active SQLite row should be in the
        // CoreSpotlight index, so we report it as the upper-bound count.
        let spotMarker = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".spotlight_reindexed", isDirectory: false)
        if FileManager.default.fileExists(atPath: spotMarker.path) {
            snap.spotlightReindexed = true
            snap.spotlightIndexedCount = snap.sqliteRecordCount
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

    var body: some View {
        NativePanel(title: "Apple-Native Memory Stack", systemImage: "memorychip", tint: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                MemoryV2SummaryBar(status: summaryStatus, latest: latestHygiene)
                HStack(spacing: 12) {
                    stackRow(
                        icon: "cylinder.split.1x2",
                        title: "SQLite",
                        value: "\(snapshot.sqliteRecordCount) records",
                        detail: snapshot.migrated ? "migrated" : "fresh",
                        tint: snapshot.sqliteRecordCount > 0 ? .green : .secondary
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
                        value: snapshot.spotlightReindexed
                            ? "\(snapshot.spotlightIndexedCount) indexed"
                            : "not indexed",
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
                if !snapshot.dataRootPath.isEmpty {
                    Text("data root: \(snapshot.dataRootPath)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
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
        let runLabel = report.createdAt.map { "last hygiene \(MemoryView.localTimestamp($0))" } ?? "last hygiene"
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
        report.nextScheduled.map { " · next \(MemoryView.localTimestamp($0))" } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
