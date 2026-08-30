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

struct MemoryView: View {
    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var memoryProposalMessage: String?
    @State private var selectedTab: MemoryViewTab

    // PATCH-2026-06-06: activity-flatten — when ActivityView drills into the
    // "Memory Proposals" section, the user wants to land on the pending
    // proposal queue, not the active-memory list. Default stays `.active` so
    // existing call sites are unchanged.
    init(
        initialTab: MemoryViewTab = .active,
        menuActionController: MemoryMenuActionController = .init()
    ) {
        _selectedTab = State(initialValue: initialTab)
        _menuActionController = State(initialValue: menuActionController)
    }
    @State private var spotlightStatus: String?
    @State private var cloudKitStatus: String = "checking…"
    @State private var isReindexing = false
    @State private var nativeStack: MemoryV2NativeStackSnapshot = .empty
    @State private var semanticSearchTask: Task<Void, Never>?
    @State private var isRefreshing = false
    @State private var refreshNotice: MemoryToolbarRefreshPresentation?
    @State private var menuActionController: MemoryMenuActionController

    private var filteredMemories: [MemoryRecord] {
        MemorySearchPresentation.displayedRecords(
            appModel.memories,
            query: query,
            semanticResults: appModel.memorySearchResults,
            resultQuery: appModel.memorySearchResultQuery
        ) { memory, lower in
            memory.text.lowercased().contains(lower) || memory.layer.lowercased().contains(lower)
        }
    }

    private var pendingMemoryProposals: [MemoryProposalRecord] {
        appModel.memoryProposals.filter { $0.status == "pending" }
    }

    private var memorySearchPresentation: MemorySearchPresentation {
        MemorySearchPresentation.resolve(
            query: query,
            resultCount: filteredMemories.count,
            isLoading: appModel.memorySearchIsLoading
                && MemorySearchPresentation.matchesCurrentQuery(
                    query,
                    resultQuery: appModel.memorySearchResultQuery
                ),
            error: MemorySearchPresentation.matchesCurrentQuery(
                query,
                resultQuery: appModel.memorySearchResultQuery
            )
                ? appModel.memorySearchError
                : nil
        )
    }

    private var currentMemorySearchError: String? {
        guard MemorySearchPresentation.matchesCurrentQuery(
            query,
            resultQuery: appModel.memorySearchResultQuery
        ) else {
            return nil
        }
        return appModel.memorySearchError
    }

    private var rejectedMemoryProposals: [MemoryProposalRecord] {
        appModel.memoryProposals.filter { $0.status == "rejected" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // UI-5: "semantic recall" is a backend word. The search box is
                // the first thing on the page, so it says what it does.
                TextField("Search your memories", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button(
                        menuActionController.runningAction == .consolidate ? "Consolidating memory…" : "Consolidate memory",
                        systemImage: "arrow.triangle.merge"
                    ) {
                        Task { await menuActionController.run(.consolidate, appModel: appModel) }
                    }
                    .disabled(menuActionController.runningAction != nil || isReindexing)
                    Button(
                        menuActionController.runningAction == .hygiene ? "Running hygiene…" : "Run hygiene",
                        systemImage: "sparkles"
                    ) {
                        Task { await menuActionController.run(.hygiene, appModel: appModel) }
                    }
                    .disabled(menuActionController.runningAction != nil || isReindexing)
                    Button(isReindexing ? "Reindexing Spotlight…" : "Reindex Spotlight", systemImage: "magnifyingglass") {
                        Task { await reindexSpotlight() }
                    }
                    .disabled(isReindexing || menuActionController.runningAction != nil)
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

            if let searchError = currentMemorySearchError, !searchError.isEmpty {
                Label(searchError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let memoryProposalMessage, !memoryProposalMessage.isEmpty {
                Label(memoryProposalMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let refreshNotice {
                Label(refreshNotice.text, systemImage: refreshNotice.systemImage)
                    .font(.caption)
                    .foregroundStyle(refreshNotice.isAdverse ? .orange : .secondary)
            }

            if let menuActionFeedback = menuActionController.feedback {
                Label(menuActionFeedback.message, systemImage: menuActionFeedback.isAdverse
                    ? "exclamationmark.triangle"
                    : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(menuActionFeedback.isAdverse ? .orange : .secondary)
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
                Task { await refreshMemorySurface() }
            }
            .disabled(isRefreshing)
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
        // The owner starts its generation gate before its debounce. That makes
        // a new keystroke immediately invalidate old results instead of showing
        // a previous query beneath the current search text.
        .onChange(of: query) { _, newValue in
            semanticSearchTask?.cancel()
            semanticSearchTask = Task {
                await appModel.runMemorySemanticSearch(query: newValue)
            }
        }
        .onDisappear {
            semanticSearchTask?.cancel()
        }
    }

    @MainActor
    private func refreshNativeStack() async {
        nativeStack = await MemoryV2NativeStackSnapshot.load(
            dataRoot: appModel.dataRootOverride ?? NativeAgentPaths.dataRoot
        )
    }

    /// The toolbar claims to refresh the Memory page, not merely its list.
    /// Keep the list/proposal/status reader, the native status snapshot, and
    /// the CloudKit account status in one user-triggered transaction.
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
        switch memorySearchPresentation {
        case .searching:
            ProgressView("Searching memories…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let detail):
            NativeEmptyState(
                title: "Memory search unavailable",
                detail: "\(detail) No text matches were found either.",
                systemImage: "exclamationmark.triangle"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .allMemories, .empty:
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
        case .results:
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
                // UI-5: "USER.md" and "the graph" are file and backend names.
                // The filename still ships, inside Advanced Diagnostics on the
                // memory status panel.
                Text("Review the lasting facts the agent wants to keep in your long-term memory profile. Short-lived project details are stored automatically without asking.")
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

/// A read-only path to the complete saved text. The list preview stays compact;
/// opening this sheet does not pin, delete, or otherwise mutate the memory.
struct MemoryFullTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved memory")
                    .font(.headline)
                Spacer()
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

private struct MemoryRowEditor: View {
    let memory: MemoryRecord
    @Environment(AppModel.self) private var appModel
    @State private var showingDeleteConfirmation = false
    @State private var showingFullText = false
    @State private var isDeleting = false
    @State private var isPinning = false
    @State private var pinFeedback: MemoryRowEditorPinOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if let pinFeedback {
                Label(
                    pinFeedback.message,
                    systemImage: pinFeedback.systemImage
                )
                .font(.caption)
                .foregroundStyle(
                    pinFeedback.isAdverse || pinFeedback.isPendingApproval ? .orange : .secondary
                )
                .accessibilityLabel(pinFeedback.message)
            }
            Text(memory.text)
                .textSelection(.enabled)
                .lineLimit(2)
            if let tags = memory.tags, !tags.isEmpty {
                tagChipsRow(tags)
            }
            provenanceLine
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingFullText) {
            MemoryFullTextView(text: memory.text)
        }
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
            Button("Read", systemImage: "doc.text.magnifyingglass") {
                showingFullText = true
            }
            .help("Read the full saved memory")
            .accessibilityLabel("Read full memory")
            Button(
                isPinning ? "Updating…" : (memory.pinned == true ? "Unpin" : "Pin"),
                systemImage: isPinning ? "hourglass" : (memory.pinned == true ? "pin.slash" : "pin")
            ) {
                Task { await togglePin() }
            }
            .disabled(isPinning)
            Button(isDeleting ? "Deleting\u{2026}" : "Delete", systemImage: isDeleting ? "hourglass" : "trash") {
                showingDeleteConfirmation = true
            }
            .foregroundStyle(.red)
            .disabled(isDeleting)
        }
        .buttonStyle(.borderless)
    }

    @MainActor
    private func togglePin() async {
        guard !isPinning else { return }
        isPinning = true
        defer { isPinning = false }
        pinFeedback = await appModel.pinMemory(memory, pinned: !(memory.pinned ?? false))
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
        // The record exposes saved/updated time, not last retrieval or usage.
        let source = memory.sourceRunId ?? "manual"
        let conf = String(format: "%.0f%%", memory.confidence * 100)
        let when = MemoryRowTimestampPresentation.label(createdAt: memory.createdAt, updatedAt: memory.updatedAt)
        Text("\(source) · conf \(conf) · \(when)")
            .font(.caption2)
            .foregroundStyle(.secondary)
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

enum MemoryRowTimestampPresentation {
    static func label(createdAt: String, updatedAt: String?) -> String {
        let updated = updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasUpdate = !updated.isEmpty
        let timestamp = hasUpdate ? updated : createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserDisplayFormatters.parseISOTimestamp(timestamp) != nil else {
            return hasUpdate ? "update time unavailable" : "save time unavailable"
        }
        let relative = UserDisplayFormatters.relativeISOTimestamp(
            timestamp,
            unitsStyle: .abbreviated,
            fallback: "time unavailable"
        )
        return "\(hasUpdate ? "updated" : "saved") \(relative)"
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

/// The state-bearing core of MemoryView's explicit toolbar action. Keeping it
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
