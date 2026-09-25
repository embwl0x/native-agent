// PATCH-2026-05-29: dreams-tab DreamsView — surfaces + controls the dream diary
// and REM consolidation cycle. Backend: Swift-native DreamREMCycle runtime.
//   GET  /v1/dream/diary?limit=N -> {entries:[DreamEntry], enabled:Bool}
//   GET  /v1/dream/<YYYY-MM-DD>  -> DreamEntry (404 if missing)
//   POST /v1/dream/run           -> run a dream pass now
//   POST /v1/rem/run             -> run a REM consolidation pass now
// Kill switches (via deep-merged /v1/trust patch):
//   personalityPolicy.dream_cycle_enabled (deep dream gate)
//   trainingPolicy.rem_cycle_enabled       (REM gate)
import SwiftUI
import PersistenceCore

/// The manual Dream action must distinguish a verified disabled policy from an
/// unavailable diary/gate read. Both prevent a run, but only the former may be
/// described as disabled to the person using the Dreams surface.
enum DreamRunAvailability: Equatable {
    case checking
    case enabled
    case disabled
    case unavailable

    static func resolve(
        hasReadDiaryGate: Bool,
        diaryLoadFailed: Bool,
        dreamEnabledFromDiary: Bool
    ) -> Self {
        if diaryLoadFailed { return .unavailable }
        guard hasReadDiaryGate else { return .checking }
        return dreamEnabledFromDiary ? .enabled : .disabled
    }

    var canRun: Bool { self == .enabled }

    var help: String {
        switch self {
        case .checking:
            return "Checking dream-cycle availability."
        case .enabled:
            return "Run a dream reflection pass against recent sessions."
        case .disabled:
            return "Dream cycle is disabled. Enable the dream cycle toggle and the Trust 'dream scheduler' gate."
        case .unavailable:
            return "Dream-cycle availability could not be read. Refresh the diary and retry."
        }
    }
}

/// The Dreams surface owns several independent operations (diary reads,
/// manual Dream/REM runs, and gate writes).  A non-nil operation error is
/// evidence of failure even when a producer supplied no usable diagnostic;
/// never erase that state into an empty red strip or a success-shaped surface.
enum DreamErrorBannerPresentation {
    struct Banner: Equatable, Sendable {
        let text: String
        let isTruncated: Bool
    }

    static let maximumDetailCharacters = 280
    static let missingDetailText = "Dreams operation failed, but no diagnostic detail was returned."

    static func banner(for error: String?) -> Banner? {
        guard let error else { return nil }
        let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return .init(text: missingDetailText, isTruncated: false)
        }
        let isTruncated = detail.count > maximumDetailCharacters
        let bounded = String(detail.prefix(maximumDetailCharacters))
        return .init(text: isTruncated ? "\(bounded)…" : bounded, isTruncated: isTruncated)
    }
}

/// The diary refresh outcome is distinct from the diary's content. An empty
/// array after a successful read is an honest empty diary; a failed read over
/// retained entries is stale data, and a failed first read is unavailable.
enum DreamDiaryRefreshPresentation: Equatable {
    case current
    case retainedStale(entryCount: Int)
    case unavailable

    static func resolve(entries: [DreamEntry], didFail: Bool) -> Self {
        guard didFail else { return .current }
        return entries.isEmpty ? .unavailable : .retainedStale(entryCount: entries.count)
    }

    var banner: String? {
        switch self {
        case .current: return nil
        case .retainedStale:
            return "Couldn't refresh the diary — showing previously loaded entries."
        case .unavailable:
            return "Dream cycle availability couldn't be checked. Retry the diary refresh before running a dream pass."
        }
    }

    var unavailableEmptyState: Bool { self == .unavailable }
}

/// A successful diary read can still omit individual damaged files. Keep that
/// third state distinct from both an empty diary and a total reader failure.
enum DreamDiaryListPresentation: Equatable {
    case readable
    case incomplete(unreadableEntries: Int)

    static func resolve(entryCount: Int, unreadableEntries: Int) -> Self {
        entryCount == 0 && unreadableEntries > 0
            ? .incomplete(unreadableEntries: unreadableEntries)
            : .readable
    }

    static func unreadableLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 diary file in this window couldn't be read and is not shown."
            : "\(count) diary files in this window couldn't be read and are not shown."
    }
}

/// Serializes diary-read visibility. The newest request owns the spinner and
/// is the only request whose response may reach the diary reconciliation code.
/// Older reads can still finish, but their result is explicitly superseded.
struct DreamDiaryLoadGeneration: Equatable {
    enum Settlement: Equatable {
        case superseded
        case current(DreamDiaryResponse?)
    }

    private(set) var latestRequest = 0
    private(set) var isLoading = false

    mutating func begin() -> Int {
        latestRequest &+= 1
        isLoading = true
        return latestRequest
    }

    mutating func settle(request: Int, response: DreamDiaryResponse?) -> Settlement {
        guard request == latestRequest else { return .superseded }
        isLoading = false
        return .current(response)
    }
}

/// The detail pane has a separate request stream from the diary list. A newer
/// date selection owns both the result and the loading indicator; a cancelled
/// older request must not make the newer selection look idle or overwrite its
/// failure state.
struct DreamEntryLoadGeneration: Equatable {
    enum Settlement: Equatable {
        case superseded
        case current(DreamEntry?)
    }

    private(set) var latestRequest = 0
    private(set) var isLoading = false

    mutating func begin() -> Int {
        latestRequest &+= 1
        isLoading = true
        return latestRequest
    }

    mutating func settle(request: Int, entry: DreamEntry?) -> Settlement {
        guard request == latestRequest else { return .superseded }
        isLoading = false
        return .current(entry)
    }

    mutating func cancelPending() {
        latestRequest &+= 1
        isLoading = false
    }
}

/// The detail pane must distinguish an unselected diary from a selected date
/// whose fetch did not yield an entry. The latter is an unavailable read, never
/// an instruction to select a dream again.
enum DreamEntryDetailPresentation: Equatable {
    case loading
    case entry
    case failed(String)
    case unselected

    static let missingEntryDetail = "The selected diary entry could not be read."

    static func resolve(
        selectedDate: String?,
        hasSelectedEntry: Bool,
        isLoading: Bool,
        error: String?
    ) -> Self {
        if isLoading && !hasSelectedEntry { return .loading }
        if hasSelectedEntry { return .entry }
        guard selectedDate != nil else { return .unselected }
        return .failed(error ?? missingEntryDetail)
    }
}

struct DreamsView: View {
    @Environment(AppModel.self) private var appModel

    // ── Diary state (owned by the view; the diary is fetched here, not in AppModel) ──
    @State private var entries: [DreamEntry] = []
    @State private var dreamEnabledFromDiary = false   // composite gate from /v1/dream/diary
    @State private var selectedDate: String?
    @State private var selectedEntry: DreamEntry?

    @State private var diaryLoadGeneration = DreamDiaryLoadGeneration()
    @State private var entryLoadGeneration = DreamEntryLoadGeneration()
    @State private var isRunningDream = false
    @State private var isRunningRem = false
    @State private var remPolicyLoadFailed = false
    @State private var remRunFeedback: DreamsREMActionFeedback?
    @State private var didInitialLoad = false

    // Optimistic local mirrors of the two kill switches so the toggles don't snap
    // back during the async save round-trip; reconciled from the source of truth
    // after each load. dreamCycleOn tracks the composite gate (the "Dream cycle"
    // toggle moves dream_cycle_enabled + dream_scheduler together).
    @State private var dreamCycleOn = false
    @State private var remCycleOn = true
    @State private var savingDream = false
    @State private var savingRem = false
    // Cancellable task for diary refresh so it doesn't outlive the view.
    @State private var refreshTask: Task<Void, Never>?
    @State private var entryTask: Task<Void, Never>?
    // A failed read is neither an empty diary nor proof the scheduler is off.
    // Keep that distinction in the mounted surface, including when a refresh
    // fails after entries were already rendered.
    @State private var diaryLoadFailed = false
    // Set only by a successful diary read. `didInitialLoad` merely means a
    // task was started, which is not evidence that the composite gate was read.
    @State private var hasReadDiaryGate = false
    @State private var entryLoadError: String?
    @State private var diaryTotalEntries: Int?
    @State private var diaryUnreadableEntries = 0

    /// One page of the diary; "Show older dreams" adds another page, so every
    /// entry, archived ones included, is reachable from the list.
    private static let diaryPage = 60
    @State private var diaryLimit = DreamsView.diaryPage

    private var isLoadingDiary: Bool { diaryLoadGeneration.isLoading }
    private var isLoadingEntry: Bool { entryLoadGeneration.isLoading }

    private var entryDetailPresentation: DreamEntryDetailPresentation {
        DreamEntryDetailPresentation.resolve(
            selectedDate: selectedDate,
            hasSelectedEntry: selectedEntry != nil,
            isLoading: isLoadingEntry,
            error: entryLoadError
        )
    }

    private var diaryListPresentation: DreamDiaryListPresentation {
        DreamDiaryListPresentation.resolve(
            entryCount: entries.count,
            unreadableEntries: diaryUnreadableEntries
        )
    }

    // REM enabled state is owned by the trust policy. A policy that has not
    // loaded yet is NOT an off switch: `== true` on the optional rendered the
    // toggle OFF on a fresh root, because the diary load below reconciles the
    // mirrors and wins the race against `loadREMPolicy()`. Fall back to the
    // shipped default instead.
    @MainActor
    private var remEnabled: Bool {
        appModel.trustPolicy?.trainingPolicy?.rem_cycle_enabled ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            controlBar

            if let banner = DreamErrorBannerPresentation.banner(for: appModel.dreamError) {
                Text(banner.text)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Dreams error: \(banner.text)")
            }

            content
        }
        .alivePageLine(headerLine, id: "dreams.line")
        // ui-taste-sweep 2026-06-07: was falling back to the bundle name
        // ("NativeAgent") because no title was set on the body root.
        .navigationTitle("Dreams")
        .task {
            // One-shot initial load. .task is cancelled automatically on disappear.
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await loadREMPolicy()
            await loadDiary(selectLatest: true)
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            entryTask?.cancel()
            entryTask = nil
        }
    }

    /// The header's one sentence in my own voice (alive glass, 2026-09-23).
    /// Nil until the diary has been read; the tab row's page keeps its line.
    private var headerLine: String? {
        if diaryLoadFailed && entries.isEmpty { return "I couldn't read my dream diary just now." }
        guard hasReadDiaryGate else { return nil }
        let count = diaryTotalEntries ?? entries.count
        let kept = count == 0
            ? "I haven't written a dream yet"
            : "I've written \(count) \(count == 1 ? "dream" : "dreams") in my diary"
        return kept + (dreamCycleOn ? "." : "; my dream cycle is off.")
    }

    // ── Controls ──────────────────────────────────────────────────────────────
    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Alive glass (2026-09-23): one group card, the runs on one row
            // and the two cycle switches on the next.
            AliveGroupCard {
                HStack(spacing: 8) {
                    Button {
                        runDream()
                    } label: {
                        Text(isRunningDream ? "Dreaming…" : "Run a dream pass")
                    }
                    .disabled(isRunningDream || !canRunDream)
                    .help(dreamRunHelp)

                    Button {
                        runRem()
                    } label: {
                        Text(isRunningRem ? "Consolidating…" : "Run a REM pass")
                    }
                    .disabled(isRunningRem || !remRunAvailability.canRun)
                    .help(remRunAvailability.help)

                    Spacer()

                    Button {
                        refresh()
                    } label: {
                        if isLoadingDiary {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Refresh")
                        }
                    }
                    .help("Refresh the dream diary")
                    .disabled(isLoadingDiary)
                }

                HStack(spacing: 24) {
                    Toggle("Dream cycle", isOn: Binding(
                        get: { dreamCycleOn },
                        set: { newValue in
                            guard !savingDream else { return }
                            dreamCycleOn = newValue          // optimistic — no snap-back
                            savingDream = true
                            Task {
                                let ok = await appModel.setDreamCycleEnabled(newValue)
                                if ok {
                                    // Both gates moved together; re-read the composite.
                                    await loadDiary(selectLatest: false)
                                } else {
                                    // Save failed — revert the optimistic flip and keep
                                    // the error visible (don't reload, which clears it).
                                    dreamCycleOn = !newValue
                                }
                                savingDream = false
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .hazeTinted()
                    .controlSize(.small)
                    .disabled(savingDream)

                    Toggle("REM cycle", isOn: Binding(
                        get: { remCycleOn },
                        set: { newValue in
                            guard !savingRem else { return }
                            remCycleOn = newValue            // optimistic — no snap-back
                            savingRem = true
                            Task {
                                let ok = await appModel.setRemCycleEnabled(newValue)
                                // On success reconcile from the saved policy; on failure
                                // revert the optimistic flip (error stays visible).
                                remCycleOn = ok ? remEnabled : !newValue
                                savingRem = false
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .hazeTinted()
                    .controlSize(.small)
                    .disabled(savingRem)

                    Spacer()
                }
                .font(ShellType.label)
            }

            if let banner = diaryRefreshPresentation.banner {
                Text(banner)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
            }
            if let remRunFeedback {
                Text(remRunFeedback.message)
                    .font(ShellType.label)
                    .foregroundStyle(remRunFeedback.isSuccess ? NativeAgentShell.secondary : NativeAgentShell.trouble)
            }
            if let label = DreamDiaryListPresentation.unreadableLabel(diaryUnreadableEntries) {
                Text(label)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
            }
        }
    }

    // ── Content (master/detail, with empty + loading states) ────────────────────
    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            if isLoadingDiary {
                AdvancedWaitingLine("Reading the dream diary…")
            } else if diaryRefreshPresentation.unavailableEmptyState {
                AdvancedEmptyState(
                    title: "Dream diary unavailable",
                    detail: "The diary could not be read, so this is not evidence that no dreams have been recorded.",
                    actionTitle: "Retry",
                    action: { refresh() }
                )
            } else if case .incomplete(let unreadableEntries) = diaryListPresentation {
                AdvancedEmptyState(
                    title: "Dream diary incomplete",
                    detail: "\(unreadableEntries) diary file\(unreadableEntries == 1 ? "" : "s") could not be read, so this is not evidence that no dreams have been recorded.",
                    actionTitle: "Retry",
                    action: { refresh() }
                )
            } else {
                AdvancedEmptyState(
                    title: "No dreams yet",
                    detail: emptyDiaryDetail
                )
            }
        } else {
            VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("My diary")
            HSplitView {
                // Left: diary dates, newest first.
                List(selection: Binding(
                    get: { selectedDate },
                    set: { newValue in
                        selectedDate = newValue
                        if let date = newValue {
                            loadEntry(date: date)
                        } else {
                            entryTask?.cancel()
                            entryLoadGeneration.cancelPending()
                            selectedEntry = nil
                            entryLoadError = nil
                        }
                    }
                )) {
                    // Week titles are plain rows: a plain List pins section
                    // headers, and over the clear background they stacked.
                    ForEach(DreamDiaryWeeks.weeks(entries)) { week in
                        Text(week.title)
                            .font(ShellType.captionMedium)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .padding(.top, 6)
                            .selectionDisabled()
                        ForEach(week.entries, id: \.date) { entry in
                            DreamDateRow(entry: entry)
                                .tag(entry.date)
                        }
                    }
                    if let diaryTotalEntries, diaryTotalEntries > entries.count {
                        Button {
                            diaryLimit += Self.diaryPage
                            refreshTask?.cancel()
                            refreshTask = Task { await loadDiary(selectLatest: false) }
                        } label: {
                            Text(isLoadingDiary
                                 ? "Reading older dreams…"
                                 : "Show older dreams (\(diaryTotalEntries - entries.count) more)")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingDiary)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minWidth: 200, idealWidth: 240)

                // Right: selected entry, rendered readably.
                detailPanel
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.vertical, 8)
            .aliveCard()
            }
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if case .loading = entryDetailPresentation {
            AdvancedWaitingLine("Reading this dream…")
        } else if case .entry = entryDetailPresentation, let entry = selectedEntry {
            let reading = DreamReaderText.reading(entry.content)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Lead with the dream's own title; the date is a caption.
                    VStack(alignment: .leading, spacing: 2) {
                        // The file's date is the day the dream is about; its
                        // time is when I wrote it (the 03:30 run lands the next
                        // morning), so the two are named apart.
                        let night = "Night of " + DreamReaderText.friendlyDate(entry.date)
                        Text(reading.title ?? night)
                            .font(ShellType.bodySemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        let written = entry.modified_at.map { "written " + shortTimestamp($0) }
                        if let caption = reading.title != nil
                            ? [night, written].compactMap { $0 }.joined(separator: " · ")
                            : written.map({ "W" + $0.dropFirst() }) {
                            Text(caption)
                                .font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    }

                    if entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This entry is empty.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    } else {
                        ForEach(Array(reading.body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            dreamLine(line)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if case let .failed(entryLoadError) = entryDetailPresentation {
            AdvancedEmptyState(
                title: "Couldn't load this dream",
                detail: entryLoadError,
                actionTitle: "Retry",
                action: {
                    if let selectedDate { loadEntry(date: selectedDate) }
                }
            )
            .padding(.horizontal, 16)
        } else {
            AdvancedEmptyState(
                title: "Select a dream",
                detail: "Pick a date on the left to read that night's entry."
            )
            .padding(.horizontal, 16)
        }
    }

    // Light markdown line renderer, mirroring ContentView.receiptLine().
    @ViewBuilder
    private func dreamLine(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 8)
        } else if trimmed.hasPrefix("# ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("## ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(3))))
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.text)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("### ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(4))))
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.secondary)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(LocalizedStringKey(raw))
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ── Actions ─────────────────────────────────────────────────────────────────
    @MainActor
    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            await loadREMPolicy()
            await loadDiary(selectLatest: false)
        }
    }

    @MainActor
    private func runDream() {
        guard !isRunningDream else { return }   // synchronous guard — no double-fire
        isRunningDream = true
        Task {
            let ok = await appModel.runDreamPassForDreams()
            isRunningDream = false
            // Reload ONLY on success — loadDiary clears dreamError, which would
            // otherwise erase the failure message before the user reads it.
            if ok { await loadDiary(selectLatest: true) }
        }
    }

    @MainActor
    private func runRem() {
        guard !isRunningRem, remRunAvailability.canRun else { return }
        isRunningRem = true
        remRunFeedback = nil
        Task {
            let feedback = await appModel.runRemPass()
            isRunningRem = false
            remRunFeedback = feedback
            if feedback.isSuccess { await loadDiary(selectLatest: false) }
        }
    }

    // ── Loaders ───────────────────────────────────────────────────────────────
    @MainActor
    private func loadDiary(selectLatest: Bool) async {
        let request = diaryLoadGeneration.begin()
        let result = await appModel.fetchDreamDiary(limit: diaryLimit)
        guard case let .current(response) = diaryLoadGeneration.settle(
            request: request,
            response: result
        ) else {
            return
        }
        // A current cancellation clears its spinner but must not repaint the
        // visible diary as a reader failure or a fresh response.
        guard !Task.isCancelled else { return }
        guard let response else {
            diaryLoadFailed = true
            return
        }
        diaryLoadFailed = false
        hasReadDiaryGate = true
        entries = response.entries
        diaryTotalEntries = response.totalEntries
        diaryUnreadableEntries = response.unreadableEntries ?? 0
        dreamEnabledFromDiary = response.enabled
        // Reconcile the optimistic toggle mirrors from the source of truth (skip
        // while a save is in flight so we don't clobber the user's pending intent).
        if !savingDream { dreamCycleOn = response.enabled }
        // Only reconcile REM once the policy it comes from has actually been
        // read — the diary response says nothing about the REM gate.
        if !savingRem, appModel.trustPolicy != nil { remCycleOn = remEnabled }

        // Re-derive the selection against the freshly loaded entries.
        if entries.isEmpty {
            selectedDate = nil
            selectedEntry = nil
            return
        }
        let currentStillValid = selectedDate.map { d in entries.contains { $0.date == d } } ?? false
        if selectLatest || !currentStillValid {
            // Jump to the newest entry (initial load / after a dream run / prior
            // selection no longer exists). Diary entries carry full content.
            let first = entries[0]
            selectedDate = first.date
            selectedEntry = first
        } else if let current = selectedDate, selectedEntry?.date != current {
            // Current selection still valid but its detail is stale — refresh it.
            loadEntry(date: current)
        }
    }

    @MainActor
    private func loadREMPolicy() async {
        guard appModel.trustPolicy == nil || remPolicyLoadFailed else { return }
        do {
            appModel.trustPolicy = try await appModel.getTrustPolicy()
            remPolicyLoadFailed = false
        } catch {
            remPolicyLoadFailed = true
        }
    }

    @MainActor
    private func loadEntry(date: String) {
        // Register the replacement request before cancelling the older task so
        // its deferred completion cannot clear the newer request's spinner.
        let request = entryLoadGeneration.begin()
        entryTask?.cancel()
        entryLoadError = nil
        // Prefer the already-fetched diary entry (it carries full content).
        if let cached = entries.first(where: { $0.date == date }),
           !cached.content.isEmpty {
            selectedEntry = cached
            _ = entryLoadGeneration.settle(request: request, entry: cached)
            return
        }
        // Switching to an uncached date — clear stale detail so the previous entry
        // isn't shown under the new selection while the fetch is in flight.
        selectedEntry = nil
        entryTask = Task {
            let fetched = await appModel.fetchDreamEntry(date: date)
            guard case let .current(currentEntry) = entryLoadGeneration.settle(
                request: request,
                entry: fetched
            ) else { return }
            // Apply only if this is still the selected date and we weren't cancelled.
            if Task.isCancelled || selectedDate != date { return }
            if let currentEntry {
                selectedEntry = currentEntry
            } else {
                entryLoadError = appModel.dreamError ?? DreamEntryDetailPresentation.missingEntryDetail
            }
        }
    }

    private var canRunDream: Bool {
        dreamRunAvailability.canRun
    }

    private var dreamRunHelp: String {
        dreamRunAvailability.help
    }

    private var dreamRunAvailability: DreamRunAvailability {
        DreamRunAvailability.resolve(
            hasReadDiaryGate: hasReadDiaryGate,
            diaryLoadFailed: diaryLoadFailed,
            dreamEnabledFromDiary: dreamEnabledFromDiary
        )
    }

    private var remRunAvailability: DreamsREMRunAvailability {
        DreamsREMRunAvailability.resolve(
            policy: appModel.trustPolicy,
            policyLoadFailed: remPolicyLoadFailed
        )
    }

    private var diaryRefreshPresentation: DreamDiaryRefreshPresentation {
        DreamDiaryRefreshPresentation.resolve(entries: entries, didFail: diaryLoadFailed)
    }

    private var emptyDiaryDetail: String {
        switch dreamRunAvailability {
        case .checking:
            return "Checking whether the dream cycle is available."
        case .enabled:
            return "I haven't written an entry yet. Run a dream pass and I'll write the first one."
        case .disabled:
            return "My dream cycle is off. Turn it on above and I dream each night, or when you run a pass."
        case .unavailable:
            return "The dream diary could not be read, so cycle availability is unavailable."
        }
    }

    private func shortTimestamp(_ iso: String) -> String {
        UserDisplayFormatters.shortTime(iso)
    }
}

// ── Reader text ────────────────────────────────────────────────────────────────

/// How a stored entry reads on screen. `DreamCycleRunner` writes
/// `# Dream — <date>` then `**<title>**`; the date is already in the list and
/// the caption, so that heading is dropped (only an exact match of the
/// pattern) and the title leads the reader.
enum DreamReaderText {
    static func reading(_ content: String) -> (title: String?, body: String) {
        var lines = content.components(separatedBy: "\n")[...]
        func dropBlank() {
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines = lines.dropFirst()
            }
        }
        dropBlank()
        guard let heading = lines.first?.trimmingCharacters(in: .whitespaces),
              heading.range(of: #"^# Dream — \d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return (nil, content) }
        lines = lines.dropFirst()
        dropBlank()
        var title: String?
        if let line = lines.first?.trimmingCharacters(in: .whitespaces),
           line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") {
            let inner = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !inner.contains("**") {
                title = inner
                lines = lines.dropFirst()
                dropBlank()
            }
        }
        return (title, lines.joined(separator: "\n"))
    }

    /// `2026-09-22` → "Tue, Sep 22" (with the year only when it isn't this
    /// one). Anything that isn't a plain date stays as written.
    static func friendlyDate(_ key: String, now: Date = Date(),
                             calendar: Calendar = DisplayTimeZone.calendar) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = calendar.timeZone
        guard key.count == 10, let date = parser.date(from: key) else { return key }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

// ── Weeks ──────────────────────────────────────────────────────────────────────

/// The diary read as history: this week, last week, then the weeks behind them.
/// Archived dreams arrive in the same list (the reader merges `archive/<year>`),
/// so an older week recedes into its own group rather than off the page.
enum DreamDiaryWeeks {
    struct Week: Identifiable {
        let id: String
        let title: String
        let entries: [DreamEntry]
    }

    static func weeks(_ entries: [DreamEntry], now: Date = Date(),
                      calendar: Calendar = DisplayTimeZone.calendar) -> [Week] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = calendar.timeZone
        var order: [String] = []
        var grouped: [String: [DreamEntry]] = [:]
        var titles: [String: String] = [:]
        for entry in entries {
            let start = parser.date(from: String(entry.date.prefix(10))).map {
                calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0
            }
            let key = start.map { parser.string(from: $0) } ?? "undated"
            if grouped[key] == nil {
                order.append(key)
                titles[key] = start.map { title(weekStart: $0, now: now, calendar: calendar) } ?? "Undated"
            }
            grouped[key, default: []].append(entry)
        }
        return order.map { Week(id: $0, title: titles[$0] ?? "", entries: grouped[$0] ?? []) }
    }

    private static func title(weekStart: Date, now: Date, calendar: Calendar) -> String {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        if let thisWeek {
            if calendar.isDate(weekStart, inSameDayAs: thisWeek) { return "This week" }
            if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek),
               calendar.isDate(weekStart, inSameDayAs: lastWeek) { return "Last week" }
        }
        return "Week of " + weekStart.formatted(.dateTime.day().month(.abbreviated))
    }
}

// ── Date row ───────────────────────────────────────────────────────────────────
private struct DreamDateRow: View {
    let entry: DreamEntry

    /// The first real line of the dream. A byte count tells a reader nothing
    /// about which night this was; my own opening words do.
    private var excerpt: String {
        let lines = (entry.content ?? "").split(whereSeparator: \.isNewline)
        let first = lines.lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && !line.hasPrefix("#") && line != "---"
            } ?? ""
        return TodayWords.line(first, limit: 90)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DreamReaderText.friendlyDate(entry.date))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NativeAgentShell.text)
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
